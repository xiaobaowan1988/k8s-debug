#!/usr/bin/env bash
# 在 VM 内初始化单节点 K8s 集群并注入调试二进制
#
# 执行流程：
#   1. kubeadm init（ARM64，镜像来自 registry.k8s.io 多架构支持）
#   2. 安装 Flannel CNI
#   3. bash scripts/05-inject-binaries.sh（替换为调试版二进制）
#   4. bash scripts/06-setup-debug-manifests.sh（控制平面改为 host 进程 + dlv）
#   5. bash debug/containerd.sh / debug/kubelet.sh（attach dlv）
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$_SCRIPT_DIR/../.." && pwd)"
SSH_PORT="${SSH_PORT:-2222}"
SSH_KEY="$REPO_ROOT/build/mac-debug/debug-vm-key"
SSH_OPTS="-p $SSH_PORT -o StrictHostKeyChecking=no -o ConnectTimeout=15"
[[ -f "$SSH_KEY" ]] && SSH_OPTS="$SSH_OPTS -i $SSH_KEY"
VM="root@localhost"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[ERR ]\033[0m  $*"; exit 1; }

ssh $SSH_OPTS $VM "echo ok" 2>/dev/null || die "VM SSH 不可达"

ssh $SSH_OPTS $VM bash -s << 'REMOTE'
set -euo pipefail
export PATH=$PATH:/usr/local/go/bin:/root/go/bin
export KUBECONFIG=/etc/kubernetes/admin.conf

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }

cd /home/user/k8s-debug

# ── 检查是否已初始化 ──────────────────────────────────────────────────────────
if [[ -f /etc/kubernetes/admin.conf ]]; then
    warn "K8s 集群已存在，跳过 kubeadm init"
    warn "如需重置: kubeadm reset -f && rm -rf /etc/cni/net.d ~/.kube"
else
    # ── kubeadm init ────────────────────────────────────────────────────────
    info "初始化 K8s 集群（kubeadm init）..."

    # crictl 配置（kubeadm 需要）
    cat > /etc/crictl.yaml << 'EOF'
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 30
EOF

    kubeadm init \
        --pod-network-cidr=10.244.0.0/16 \
        --cri-socket=unix:///run/containerd/containerd.sock \
        --skip-phases=addon/kube-proxy \
        --v=2 2>&1 | tail -20

    # 配置 kubectl
    mkdir -p /root/.kube
    cp /etc/kubernetes/admin.conf /root/.kube/config

    # 去除 control-plane taint（单节点集群允许调度 pod）
    kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || true

    ok "K8s 集群初始化完成"
fi

# ── 安装 Flannel CNI ──────────────────────────────────────────────────────────
if ! kubectl get ds -n kube-flannel kube-flannel-ds 2>/dev/null | grep -q "kube-flannel"; then
    info "安装 Flannel CNI..."
    kubectl apply -f \
        https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
    # 等待 flannel 就绪
    kubectl rollout status ds/kube-flannel-ds -n kube-flannel --timeout=120s 2>/dev/null || true
    ok "Flannel CNI 已安装"
else
    ok "Flannel CNI 已存在"
fi

# ── 等待节点 Ready ────────────────────────────────────────────────────────────
info "等待节点 Ready..."
for i in $(seq 1 30); do
    STATUS=$(kubectl get nodes --no-headers 2>/dev/null | awk '{print $2}' | head -1)
    [[ "$STATUS" == "Ready" ]] && break
    sleep 5
done
kubectl get nodes
ok "节点已 Ready"

# ── 注入调试二进制 ────────────────────────────────────────────────────────────
info "注入调试版二进制（05-inject-binaries.sh）..."
bash scripts/05-inject-binaries.sh \
    build/kubernetes \
    build/runtime 2>&1 | tail -10

# ── 建立控制平面 host 进程（dlv exec 模式）────────────────────────────────────
info "配置控制平面 dlv exec 模式（06-setup-debug-manifests.sh）..."
bash scripts/06-setup-debug-manifests.sh 2>&1 | tail -20

ok "K8s 集群 + 调试配置完成"
REMOTE

echo ""
ok "K8s 集群已在 VM 内初始化"
echo ""
echo "验证集群（需要 SSH 隧道，见 14-mac-tunnel.sh）："
echo "  kubectl get nodes"
echo "  kubectl get pods -A"
echo ""
echo "下一步: bash scripts/mac/13-vm-debug-start.sh"
