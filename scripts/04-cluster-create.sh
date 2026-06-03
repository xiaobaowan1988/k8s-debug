#!/usr/bin/env bash
# 使用 kubeadm 直接在本机初始化单节点 Kubernetes 集群
# cgroup driver: cgroupfs（systemd 不是 PID 1，不能用 systemd driver）
#
# 网络受限环境注意事项：
#   registry.k8s.io / docker.io CDN 均被封，需预先离线构建镜像：
#   1. 从 dl.k8s.io 下载 k8s 服务端二进制（kube-apiserver 等）
#   2. 从 github releases 下载 etcd / coredns
#   3. 用 FROM scratch 构建本地镜像并导入 containerd
#   以上步骤由 scripts/03-build-offline-images.sh 完成。
set -euo pipefail

KUBEADM_CONFIG="${1:-$(dirname "$0")/../config/kubeadm-config.yaml}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[ERR ]\033[0m  $*"; exit 1; }

command -v kubeadm  || die "kubeadm 未安装，请先运行 scripts/00-install-deps.sh"
command -v kubelet  || die "kubelet 未安装，请先运行 scripts/00-install-deps.sh"
command -v containerd || die "containerd 未安装，请先运行 scripts/00-install-deps.sh"

# ── 重置已有集群 ───────────────────────────────────────────────────────────────
if [[ -f /etc/kubernetes/admin.conf ]]; then
    warn "检测到已有集群配置，重置..."
    kubeadm reset --force 2>/dev/null || true
    pkill -x kubelet 2>/dev/null || true
    rm -rf /etc/kubernetes /var/lib/etcd /var/lib/kubelet
fi

# ── 配置 containerd（启用 CRI + cgroupfs）──────────────────────────────────
info "配置 containerd（CRI 模式 + cgroupfs）"
mkdir -p /etc/containerd

containerd config default > /etc/containerd/config.toml

# cgroupfs: systemd 不是 PID 1
sed -i 's/SystemdCgroup = true/SystemdCgroup = false/g' /etc/containerd/config.toml

# native snapshotter（overlayfs 在此环境不可用）
sed -i 's/snapshotter = "overlayfs"/snapshotter = "native"/' /etc/containerd/config.toml

# restrict_oom_score_adj: 托管环境缺少 CAP_SYS_RESOURCE，防止 runc/nsexec 写 oomScoreAdj 失败
sed -i 's/restrict_oom_score_adj = false/restrict_oom_score_adj = true/' /etc/containerd/config.toml

ok "containerd 配置完成"

# ── 启动 containerd ─────────────────────────────────────────────────────────
info "启动 containerd..."
pkill -x containerd 2>/dev/null || true
sleep 1
nohup containerd > /var/log/containerd.log 2>&1 &

for i in $(seq 1 30); do
    [[ -S /run/containerd/containerd.sock ]] && break
    sleep 1
done
[[ -S /run/containerd/containerd.sock ]] || die "containerd 启动失败，查看日志: /var/log/containerd.log"
ok "containerd 已启动"

# ── 预加载离线镜像 ────────────────────────────────────────────────────────────
info "检查离线镜像..."
OFFLINE_IMGS_SCRIPT="${REPO_ROOT}/scripts/03-build-offline-images.sh"
if [[ -f "$OFFLINE_IMGS_SCRIPT" ]]; then
    bash "$OFFLINE_IMGS_SCRIPT"
else
    warn "离线镜像脚本不存在，假设镜像已预先加载"
fi

# ── 挂载 cpuset cgroup（kubelet 必须）───────────────────────────────────────
if ! mount | grep -q "cpuset"; then
    info "挂载 cpuset cgroup..."
    mkdir -p /sys/fs/cgroup/cpuset
    mount -t cgroup -o cpuset cpuset /sys/fs/cgroup/cpuset 2>/dev/null || \
        warn "cpuset 挂载失败（可能已内置或不需要）"
fi

# ── 关闭 swap ────────────────────────────────────────────────────────────────
swapoff -a 2>/dev/null || true

# ── 加载网络内核模块 ──────────────────────────────────────────────────────────
modprobe br_netfilter 2>/dev/null || true
modprobe overlay 2>/dev/null || true
sysctl -w net.ipv4.ip_forward=1 > /dev/null
sysctl -w net.bridge.bridge-nf-call-iptables=1 > /dev/null 2>&1 || true

# ── kubeadm init（允许 systemd 警告失败，后续手动启动 kubelet）──────────────
info "运行 kubeadm init..."
kubeadm init \
    --config "${KUBEADM_CONFIG}" \
    --ignore-preflight-errors=all \
    --skip-phases=addon/kube-proxy \
    2>&1 | tee /tmp/kubeadm-init.log || true

[[ -f /var/lib/kubelet/config.yaml ]] || \
    die "kubeadm init 未能生成 kubelet 配置，查看日志: /tmp/kubeadm-init.log"

# ── 设置宽松的磁盘驱逐阈值（避免 imagefs 压力）──────────────────────────────
info "调整 kubelet 磁盘驱逐阈值..."
python3 - << 'PYEOF'
import yaml, sys
with open('/var/lib/kubelet/config.yaml') as f:
    cfg = yaml.safe_load(f)
cfg.setdefault('evictionHard', {})
cfg['evictionHard']['imagefs.available'] = '5%'
cfg['evictionHard']['nodefs.available']  = '5%'
cfg['evictionHard']['nodefs.inodesFree'] = '5%'
with open('/var/lib/kubelet/config.yaml', 'w') as f:
    yaml.dump(cfg, f, default_flow_style=False, allow_unicode=True)
print("  eviction thresholds: imagefs/nodefs available=5%")
PYEOF

# ── 手动启动 kubelet（systemd 不可用）────────────────────────────────────────
info "手动启动 kubelet..."
pkill -x kubelet 2>/dev/null || true
sleep 1

nohup kubelet \
    --config=/var/lib/kubelet/config.yaml \
    --kubeconfig=/etc/kubernetes/kubelet.conf \
    --container-runtime-endpoint=unix:///run/containerd/containerd.sock \
    > /var/log/kubelet.log 2>&1 &
echo $! > /var/run/kubelet.pid

info "等待 kubelet 健康检查（最多 60s）..."
for i in $(seq 1 30); do
    curl -sf http://127.0.0.1:10248/healthz &>/dev/null && break
    sleep 2
done
curl -sf http://127.0.0.1:10248/healthz &>/dev/null || \
    die "kubelet 未能就绪，查看日志: /var/log/kubelet.log"
ok "kubelet 健康检查通过"

# ── kubeconfig ────────────────────────────────────────────────────────────────
mkdir -p "$HOME/.kube"
cp /etc/kubernetes/admin.conf "$HOME/.kube/config"
chmod 600 "$HOME/.kube/config"
export KUBECONFIG="$HOME/.kube/config"

# ── 完成剩余 kubeadm 阶段 ─────────────────────────────────────────────────────
info "完成 kubeadm 初始化..."
kubeadm init phase upload-config all --config "${KUBEADM_CONFIG}" 2>&1 | tail -2
kubeadm init phase mark-control-plane 2>&1 | tail -2
kubeadm init phase bootstrap-token 2>&1 | tail -2
kubeadm init phase addon coredns --config "${KUBEADM_CONFIG}" 2>&1 | tail -3

# ── 去掉控制平面 taint（单节点调度）─────────────────────────────────────────
kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || true

# ── CNI（bridge 插件）────────────────────────────────────────────────────────
info "配置 CNI（bridge）..."
mkdir -p /etc/cni/net.d /opt/cni/bin

# 优先使用自定义 CNI 插件（带调试符号）
CNI_BUILD="${REPO_ROOT}/build/runtime/cni-plugins"
if [[ -d "$CNI_BUILD" ]] && ls "$CNI_BUILD"/* &>/dev/null; then
    cp "$CNI_BUILD"/* /opt/cni/bin/
    chmod +x /opt/cni/bin/*
    ok "  自定义 CNI 插件已安装（带调试符号）"
elif ! command -v /opt/cni/bin/bridge &>/dev/null; then
    # 从 GitHub 下载标准插件
    info "  下载标准 CNI 插件..."
    curl -fsSL "https://github.com/containernetworking/plugins/releases/download/v1.6.0/cni-plugins-linux-amd64-v1.6.0.tgz" \
        -o /tmp/cni-plugins.tgz
    tar -xzf /tmp/cni-plugins.tgz -C /opt/cni/bin
fi

cp "${REPO_ROOT}/config/cni-bridge-config.json" /etc/cni/net.d/10-k8s-debug.conflist
ok "CNI 配置已写入"

# ── 等待节点 Ready ────────────────────────────────────────────────────────────
info "等待节点 Ready（最多 120s）..."
for i in $(seq 1 60); do
    STATUS=$(kubectl get nodes --no-headers 2>/dev/null | awk '{print $2}' | head -1)
    [[ "$STATUS" == "Ready" ]] && break
    sleep 2
done

echo ""
ok "单节点集群创建完成"
kubectl get nodes -o wide
echo ""
kubectl get pods -A
echo ""
echo "下一步："
echo "  make inject-binaries   # 注入带调试符号的二进制"
echo "  make debug-all         # 启动全链路调试会话"
