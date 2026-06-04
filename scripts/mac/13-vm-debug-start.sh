#!/usr/bin/env bash
# 在 VM 内启动所有组件的 dlv 调试服务
#
# 启动后端口分配（与现有 Linux 调试环境完全一致）：
#   2345  kube-apiserver       (dlv exec, via 06-setup-debug-manifests.sh)
#   2346  kube-controller-mgr  (dlv exec)
#   2347  kube-scheduler       (dlv exec)
#   2348  kubelet              (dlv attach)
#   2349  kube-proxy           (dlv exec)
#   2350  containerd/CRI       (dlv attach)
#   2351  etcd                 (dlv exec)
#   2352  coredns              (dlv exec)
#   2353  CSI hostpath         (dlv exec)
#
# macOS 端通过 SSH 隧道访问（见 14-mac-tunnel.sh）：
#   dlv connect localhost:2345   # 从 macOS host 直接连接
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
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
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

# ── 控制平面（2345/2346/2347/2351）已由 06-setup-debug-manifests.sh 管理 ──────
info "检查控制平面 dlv 进程状态..."
for port in 2345 2346 2347 2351; do
    if ss -tlnp 2>/dev/null | grep -q ":$port"; then
        ok "  端口 $port 已在监听"
    else
        warn "  端口 $port 未监听，尝试重启..."
        case $port in
            2345) [[ -f /tmp/dlv-launch-kube-apiserver.sh ]] && \
                nohup bash /tmp/dlv-launch-kube-apiserver.sh > /tmp/dlv-kube-apiserver.log 2>&1 & ;;
            2346) [[ -f /tmp/dlv-launch-kube-controller-manager.sh ]] && \
                nohup bash /tmp/dlv-launch-kube-controller-manager.sh > /tmp/dlv-kube-controller-manager.log 2>&1 & ;;
            2347) [[ -f /tmp/dlv-launch-kube-scheduler.sh ]] && \
                nohup bash /tmp/dlv-launch-kube-scheduler.sh > /tmp/dlv-kube-scheduler.log 2>&1 & ;;
            2351) [[ -f /tmp/dlv-launch-etcd.sh ]] && \
                nohup bash /tmp/dlv-launch-etcd.sh > /tmp/dlv-etcd.log 2>&1 & ;;
        esac
        sleep 5
        ss -tlnp 2>/dev/null | grep -q ":$port" && ok "  端口 $port 已启动" || warn "  端口 $port 启动失败，查看日志"
    fi
done

# ── kubelet dlv attach (2348) ─────────────────────────────────────────────────
if ! ss -tlnp 2>/dev/null | grep -q ":2348"; then
    info "启动 kubelet dlv attach (2348)..."
    bash debug/kubelet.sh 2>&1 | tail -5
else
    ok "  端口 2348 (kubelet) 已在监听"
fi

# ── containerd dlv attach (2350) ─────────────────────────────────────────────
if ! ss -tlnp 2>/dev/null | grep -q ":2350"; then
    info "启动 containerd dlv attach (2350)..."
    bash debug/containerd.sh 2>&1 | tail -5
else
    ok "  端口 2350 (containerd) 已在监听"
fi

# ── kube-proxy (2349) ─────────────────────────────────────────────────────────
if ! ss -tlnp 2>/dev/null | grep -q ":2349"; then
    info "启动 kube-proxy dlv exec (2349)..."
    bash debug/kube-proxy.sh 2>&1 | tail -5
else
    ok "  端口 2349 (kube-proxy) 已在监听"
fi

# ── coredns (2352) ────────────────────────────────────────────────────────────
if ! ss -tlnp 2>/dev/null | grep -q ":2352"; then
    info "启动 coredns dlv exec (2352)..."
    bash debug/coredns.sh 2>&1 | tail -5
else
    ok "  端口 2352 (coredns) 已在监听"
fi

# ── CSI hostpath (2353) ───────────────────────────────────────────────────────
CSI_BIN=/usr/local/bin/csi-hostpathplugin
if [[ -f "$CSI_BIN" ]] && ! ss -tlnp 2>/dev/null | grep -q ":2353"; then
    info "启动 CSI hostpath dlv exec (2353)..."
    bash debug/csi.sh 2>&1 | tail -5
elif [[ ! -f "$CSI_BIN" ]]; then
    warn "  CSI 二进制不存在（bash scripts/02-build-csi-hostpath.sh + bash scripts/05-inject-binaries.sh）"
else
    ok "  端口 2353 (CSI) 已在监听"
fi

# ── 最终端口汇总 ──────────────────────────────────────────────────────────────
echo ""
echo "══ dlv 服务端口汇总 ══════════════════════════════════════"
declare -A COMPONENTS=(
    [2345]="kube-apiserver"
    [2346]="kube-controller-manager"
    [2347]="kube-scheduler"
    [2348]="kubelet"
    [2349]="kube-proxy"
    [2350]="containerd/CRI"
    [2351]="etcd"
    [2352]="coredns"
    [2353]="CSI hostpath"
)
for port in 2345 2346 2347 2348 2349 2350 2351 2352 2353; do
    name="${COMPONENTS[$port]:-unknown}"
    if ss -tlnp 2>/dev/null | grep -q ":$port"; then
        printf "  %-6s %-25s ✓\n" "$port" "$name"
    else
        printf "  %-6s %-25s ✗ (未启动)\n" "$port" "$name"
    fi
done
echo "══════════════════════════════════════════════════════════"
REMOTE

echo ""
ok "VM 内 dlv 服务已启动"
echo ""
echo "下一步: bash scripts/mac/14-mac-tunnel.sh"
echo "        → SSH 隧道建立后，从 macOS 直接 dlv connect localhost:2345"
