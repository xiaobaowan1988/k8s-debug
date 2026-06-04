#!/usr/bin/env bash
# macOS 端：建立 SSH 隧道，将 VM 内所有 dlv 端口转发到 localhost
#
# 建立后，可以从 macOS 直接：
#   dlv connect localhost:2345          # kube-apiserver
#   dlv connect localhost:2348          # kubelet
#   kubectl get nodes                   # 通过转发的 6443 访问集群
#   bash scripts/08-test-breakpoints.sh # 在 macOS 端运行全量断点测试
#                                         （kubectl 命令通过隧道发到 VM）
#
# 端口映射：
#   macOS localhost:XXXX  ←→  VM localhost:XXXX
#   2345-2353 (dlv)
#   6443      (kube-apiserver)
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$_SCRIPT_DIR/../.." && pwd)"
SSH_PORT="${SSH_PORT:-2222}"
SSH_KEY="$REPO_ROOT/build/mac-debug/debug-vm-key"
VM="root@localhost"
TUNNEL_PID_FILE="/tmp/k8s-debug-tunnel.pid"
KUBECONFIG_VM="$HOME/.kube/config-vm-debug"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[ERR ]\033[0m  $*"; exit 1; }

SSH_BASE="-p $SSH_PORT -o StrictHostKeyChecking=no -o ConnectTimeout=10"
[[ -f "$SSH_KEY" ]] && SSH_BASE="$SSH_BASE -i $SSH_KEY"

# ── stop 模式 ─────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--stop" ]]; then
    if [[ -f "$TUNNEL_PID_FILE" ]]; then
        PID=$(cat "$TUNNEL_PID_FILE")
        kill "$PID" 2>/dev/null && ok "SSH 隧道已停止 (PID $PID)" || warn "进程已不存在"
        rm -f "$TUNNEL_PID_FILE"
    else
        pkill -f "ssh.*2345:localhost:2345" 2>/dev/null && ok "SSH 隧道已停止" || warn "未找到隧道进程"
    fi
    exit 0
fi

# ── 检查是否已有隧道 ──────────────────────────────────────────────────────────
if [[ -f "$TUNNEL_PID_FILE" ]] && kill -0 "$(cat "$TUNNEL_PID_FILE")" 2>/dev/null; then
    ok "SSH 隧道已在运行 (PID $(cat "$TUNNEL_PID_FILE"))"
    info "停止已有隧道: $0 --stop"
    exit 0
fi

# ── 检查 VM 可达性 ────────────────────────────────────────────────────────────
ssh $SSH_BASE $VM "echo ok" 2>/dev/null || die "VM SSH 不可达（先运行 bash scripts/mac/04-launch-qemu.sh --bg）"

# ── 建立 SSH 隧道 ─────────────────────────────────────────────────────────────
info "建立 SSH 隧道（dlv 端口 2345-2353 + apiserver 6443）..."

ssh $SSH_BASE -N \
    -L 2345:localhost:2345 \
    -L 2346:localhost:2346 \
    -L 2347:localhost:2347 \
    -L 2348:localhost:2348 \
    -L 2349:localhost:2349 \
    -L 2350:localhost:2350 \
    -L 2351:localhost:2351 \
    -L 2352:localhost:2352 \
    -L 2353:localhost:2353 \
    -L 6443:localhost:6443 \
    $VM &

TUNNEL_PID=$!
echo $TUNNEL_PID > "$TUNNEL_PID_FILE"
disown

sleep 2
kill -0 $TUNNEL_PID 2>/dev/null || die "SSH 隧道建立失败"
ok "SSH 隧道已建立 (PID $TUNNEL_PID)"

# ── 配置 macOS 端 kubectl ─────────────────────────────────────────────────────
info "配置 kubectl（指向 localhost:6443）..."
mkdir -p "$(dirname "$KUBECONFIG_VM")"

ssh $SSH_BASE $VM "cat /etc/kubernetes/admin.conf" 2>/dev/null | \
    sed 's|server: https://[^:]*:6443|server: https://localhost:6443|g' \
    > "$KUBECONFIG_VM" || warn "获取 kubeconfig 失败（集群可能未初始化）"

if [[ -s "$KUBECONFIG_VM" ]]; then
    ok "kubectl 配置: $KUBECONFIG_VM"
    echo ""
    echo "  export KUBECONFIG=$KUBECONFIG_VM"
    echo "  kubectl get nodes"
fi

# ── 端口可达性验证 ────────────────────────────────────────────────────────────
echo ""
info "验证端口转发状态..."
declare -A NAMES=(
    [2345]="kube-apiserver"    [2346]="kube-controller-mgr"
    [2347]="kube-scheduler"    [2348]="kubelet"
    [2349]="kube-proxy"        [2350]="containerd/CRI"
    [2351]="etcd"              [2352]="coredns"
    [2353]="CSI hostpath"      [6443]="K8s API (kubectl)"
)
for port in 2345 2346 2347 2348 2349 2350 2351 2352 2353 6443; do
    name="${NAMES[$port]:-}"
    nc -z -w2 localhost "$port" 2>/dev/null && \
        printf "  %-6s %-28s ✓ 可达\n" "$port" "$name" || \
        printf "  %-6s %-28s ✗ 未连接（dlv 服务未启动？）\n" "$port" "$name"
done

echo ""
echo "══ 使用方式 ═════════════════════════════════════════════════════"
echo ""
echo "  # 设置 kubectl"
echo "  export KUBECONFIG=$KUBECONFIG_VM"
echo ""
echo "  # 从 macOS 连接各组件 dlv"
echo "  dlv connect localhost:2345   # kube-apiserver"
echo "  dlv connect localhost:2347   # kube-scheduler"
echo "  dlv connect localhost:2348   # kubelet"
echo "  dlv connect localhost:2351   # etcd"
echo "  dlv connect localhost:2352   # coredns"
echo ""
echo "  # 运行全量断点测试（kubectl 通过隧道访问 VM 集群）"
echo "  export KUBECONFIG=$KUBECONFIG_VM"
echo "  bash scripts/08-test-breakpoints.sh"
echo ""
echo "  # 停止隧道"
echo "  bash scripts/mac/14-mac-tunnel.sh --stop"
echo "═══════════════════════════════════════════════════════════════════"
