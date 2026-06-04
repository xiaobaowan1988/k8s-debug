#!/usr/bin/env bash
# 调试 CoreDNS（host 进程 + dlv exec 模式）
#
# 与 etcd/apiserver 同样模式：将集群 Deployment 缩至 0，在 host 上接管 :53
# 这样真实的集群 DNS 流量（来自 pod）也会打到断点
#
# 前置：
#   bash scripts/01-clone-coredns.sh
#   bash scripts/02-build-coredns.sh
#
# 触发（另开终端）：
#   python3 -c "import socket; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); ..."
#   # 或等待任意 pod 做 DNS 查询（流量自然触发）
#
# 恢复：
#   bash debug/coredns.sh --restore
set -euo pipefail

DLV_PORT="${1:-2352}"
COREDNS_BIN="${COREDNS_BIN:-/home/user/k8s-debug/build/runtime/coredns}"
[[ -f "$COREDNS_BIN" ]] || COREDNS_BIN=/usr/local/bin/coredns-debug
DLV=/usr/local/bin/dlv
LOG=/tmp/dlv-coredns.log
COREFILE=/tmp/coredns-host-Corefile

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[ERR ]\033[0m  $*"; exit 1; }

# ── restore 模式 ─────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--restore" ]]; then
    info "停止 coredns host 进程..."
    pkill -f "dlv exec.*coredns" 2>/dev/null || true
    pkill -x coredns              2>/dev/null || true
    sleep 1
    info "恢复 coredns Deployment (replicas=2)..."
    kubectl scale deployment coredns -n kube-system --replicas=2 2>/dev/null
    kubectl rollout status deployment/coredns -n kube-system --timeout=60s 2>/dev/null || true
    ok "coredns 已恢复"
    exit 0
fi

[[ -f "$COREDNS_BIN" ]] || die "$COREDNS_BIN 不存在（先运行 bash scripts/02-build-coredns.sh）"
[[ -f "$DLV" ]]          || die "dlv 不在 $DLV"

has_dwarf=$(readelf -S "$COREDNS_BIN" 2>/dev/null | grep -c "\.debug_info" || true)
[[ "$has_dwarf" -gt 0 ]] || warn "$COREDNS_BIN 无 DWARF 符号"

# ── 生成 Corefile（不含 kubernetes 插件，host 进程无 in-cluster auth）──────────
# kubernetes 插件需要 KUBERNETES_SERVICE_HOST/PORT + ServiceAccount token
# host 进程用简化 Corefile：只保留 forward/cache/log，断点在 forward.ServeDNS
cat > "$COREFILE" << 'EOF'
.:53 {
    log
    errors
    forward . /etc/resolv.conf {
        max_concurrent 1000
    }
    cache 30
    loop
    reload
    loadbalance
}
EOF

# ── 缩减现有 coredns Deployment 至 0 ─────────────────────────────────────────
info "缩减 coredns Deployment → 0 (接管 :53)..."
kubectl scale deployment coredns -n kube-system --replicas=0 2>/dev/null || true
# 等待 pod 退出，释放 :53
for i in $(seq 1 15); do
    running=$(kubectl get pods -n kube-system -l k8s-app=kube-dns \
        --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
    [[ "$running" -eq 0 ]] && break
    sleep 1
done

# ── 停旧进程 ──────────────────────────────────────────────────────────────────
pkill -f "dlv exec.*coredns" 2>/dev/null || true
pkill -x coredns              2>/dev/null || true
sleep 1

echo ""
echo "断点建议 (CoreDNS host 进程):"
echo ""
echo "  # forward 插件 ServeDNS —— 每次 DNS 转发请求触发"
echo "  b github.com/coredns/coredns/plugin/forward.(*Forward).ServeDNS"
echo ""
echo "  # 主服务器入口 —— 每次 DNS 查询触发（含本地 kubernetes 插件响应）"
echo "  b github.com/coredns/coredns/core/dnsserver.(*Server).ServeDNS"
echo ""
echo "触发 (DNS 直达 host :53):"
echo "  python3 -c \""
echo "    import socket; sock=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); sock.settimeout(3)"
echo "    q=b'\\x00\\x01\\x01\\x00\\x00\\x01\\x00\\x00\\x00\\x00\\x00\\x00'"
echo "    for p in 'google.com'.split('.'): q+=bytes([len(p)])+p.encode()"
echo "    sock.sendto(q+b'\\x00\\x00\\x01\\x00\\x01',('127.0.0.1',53)); print(sock.recvfrom(512))"
echo "  \""
echo ""
echo "恢复: bash debug/coredns.sh --restore"
echo "连接: dlv connect localhost:${DLV_PORT}"
echo ""

info "启动 CoreDNS host 进程 (dlv exec, dlv:${DLV_PORT}, dns::53)..."

nohup "$DLV" exec "$COREDNS_BIN" \
    --headless \
    --listen="0.0.0.0:${DLV_PORT}" \
    --api-version=2 \
    --accept-multiclient \
    --continue \
    --check-go-version=false \
    -- \
    -conf "$COREFILE" \
    > "$LOG" 2>&1 &
disown

sleep 3
if ss -tlnp 2>/dev/null | grep -q ":${DLV_PORT}"; then
    ok "dlv 已在 localhost:${DLV_PORT} 监听"
    ok "CoreDNS host 进程 DNS 端口: :53"
    ok "日志: $LOG"
    ok "恢复: bash debug/coredns.sh --restore"
else
    warn "dlv 未启动，查看日志:"
    tail -20 "$LOG" 2>/dev/null || true
    info "恢复 coredns Deployment..."
    kubectl scale deployment coredns -n kube-system --replicas=2 2>/dev/null || true
    exit 1
fi
