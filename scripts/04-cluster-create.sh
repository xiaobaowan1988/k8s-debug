#!/usr/bin/env bash
# 使用 kubeadm 直接在本机初始化单节点 Kubernetes 集群
# cgroup driver: cgroupfs（systemd 不是 PID 1，不能用 systemd driver）
set -euo pipefail

KUBEADM_CONFIG="${1:-$(dirname "$0")/../config/kubeadm-config.yaml}"
CONTAINERD_K8S_CONFIG="${2:-$(dirname "$0")/../config/containerd-k8s.toml}"
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
    rm -rf /etc/kubernetes /var/lib/etcd
fi

# ── 配置 containerd（启用 CRI + cgroupfs）──────────────────────────────────
info "配置 containerd（CRI 模式 + cgroupfs）"
mkdir -p /etc/containerd

# 生成默认配置再覆盖关键项
containerd config default > /etc/containerd/config.toml

# 使用 cgroupfs：SystemdCgroup 设为 false
sed -i 's/SystemdCgroup = true/SystemdCgroup = false/g' /etc/containerd/config.toml

# 若 snapshotter 用 overlayfs 在当前内核不可用则降级为 native
if ! grep -q "overlayfs" /proc/filesystems 2>/dev/null; then
    warn "overlayfs 不可用，切换为 native snapshotter"
    sed -i 's/snapshotter = "overlayfs"/snapshotter = "native"/' /etc/containerd/config.toml
fi

ok "containerd 配置完成（cgroupfs）"

# ── 启动 containerd ─────────────────────────────────────────────────────────
info "启动 containerd..."
# 先杀掉可能存在的旧实例
pkill -x containerd 2>/dev/null || true
sleep 1
nohup containerd > /var/log/containerd.log 2>&1 &
CONTAINERD_PID=$!

# 等待 socket 就绪
for i in $(seq 1 30); do
    [[ -S /run/containerd/containerd.sock ]] && break
    sleep 1
done
[[ -S /run/containerd/containerd.sock ]] || die "containerd 启动失败，查看日志: /var/log/containerd.log"
ok "containerd 已启动（PID ${CONTAINERD_PID}）"

# ── 关闭 swap（kubeadm 要求）────────────────────────────────────────────────
swapoff -a 2>/dev/null || true

# ── 加载必要内核模块 ──────────────────────────────────────────────────────────
info "加载网络内核模块..."
modprobe br_netfilter 2>/dev/null || warn "br_netfilter 模块加载失败（可能已内置）"
modprobe overlay 2>/dev/null || warn "overlay 模块加载失败"

# 开启 IP 转发
sysctl -w net.ipv4.ip_forward=1 > /dev/null
sysctl -w net.bridge.bridge-nf-call-iptables=1 > /dev/null 2>&1 || true
sysctl -w net.bridge.bridge-nf-call-ip6tables=1 > /dev/null 2>&1 || true

# ── kubeadm init ──────────────────────────────────────────────────────────────
info "运行 kubeadm init..."
kubeadm init \
    --config "${KUBEADM_CONFIG}" \
    --ignore-preflight-errors=all \
    --skip-phases=addon/kube-proxy \
    2>&1 | tee /tmp/kubeadm-init.log

[[ ${PIPESTATUS[0]} -eq 0 ]] || die "kubeadm init 失败，查看日志: /tmp/kubeadm-init.log"

# ── 配置 kubeconfig ───────────────────────────────────────────────────────────
info "配置 kubeconfig..."
mkdir -p "$HOME/.kube"
cp /etc/kubernetes/admin.conf "$HOME/.kube/config"
chmod 600 "$HOME/.kube/config"
export KUBECONFIG="$HOME/.kube/config"
ok "kubeconfig 已配置: $HOME/.kube/config"

# ── 去掉控制平面污点（单节点模式）──────────────────────────────────────────
info "去除控制平面 taint，允许在单节点上调度 Pod..."
kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || true
kubectl taint nodes --all node-role.kubernetes.io/master- 2>/dev/null || true

# ── 安装 CNI（bridge 插件）────────────────────────────────────────────────────
info "配置 CNI（bridge）..."
mkdir -p /etc/cni/net.d /opt/cni/bin

# 如果已构建自定义 CNI 插件，优先使用
CNI_BUILD="${REPO_ROOT}/build/runtime/cni-plugins"
if [[ -d "$CNI_BUILD" ]] && ls "$CNI_BUILD"/* &>/dev/null; then
    cp "$CNI_BUILD"/* /opt/cni/bin/
    chmod +x /opt/cni/bin/*
    ok "已安装自定义 CNI 插件（带调试符号）"
fi

# 安装 cni-bridge-config
cp "${REPO_ROOT}/config/cni-bridge-config.json" /etc/cni/net.d/10-k8s-debug.conflist
ok "CNI 配置已写入 /etc/cni/net.d/10-k8s-debug.conflist"

# ── 等待节点 Ready ────────────────────────────────────────────────────────────
info "等待节点 Ready（最多 120s）..."
for i in $(seq 1 60); do
    STATUS=$(kubectl get nodes --no-headers 2>/dev/null | awk '{print $2}' | head -1)
    [[ "$STATUS" == "Ready" ]] && break
    sleep 2
done

kubectl get nodes -o wide
kubectl get pods -A

echo ""
ok "单节点集群创建完成"
echo ""
echo "下一步："
echo "  make inject-binaries   # 注入带调试符号的二进制"
echo "  make debug-all         # 启动全链路调试会话"
