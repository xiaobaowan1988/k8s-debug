#!/usr/bin/env bash
# 调试 CoreDNS（独立调试实例，端口 5353，dlv 端口 2352）
#
# 不干扰集群现有 coredns（仍在 :53 运行），并行运行一个 debug 实例
#
# 前置：
#   bash scripts/01-clone-coredns.sh
#   bash scripts/02-build-coredns.sh
#
# 触发（另开终端）：
#   dig @127.0.0.1 -p 5353 google.com
#   dig @127.0.0.1 -p 5353 kubernetes.default.svc.cluster.local
set -euo pipefail

DLV_PORT="${1:-2352}"
DNS_PORT="${2:-5353}"
COREDNS_BIN="${COREDNS_BIN:-/home/user/k8s-debug/build/runtime/coredns}"
[[ -f "$COREDNS_BIN" ]] || COREDNS_BIN=/usr/local/bin/coredns-debug
DLV=/usr/local/bin/dlv
LOG=/tmp/dlv-coredns.log
COREFILE=/tmp/coredns-debug-Corefile

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[ERR ]\033[0m  $*"; exit 1; }

[[ -f "$COREDNS_BIN" ]] || die "$COREDNS_BIN 不存在（先运行 bash scripts/02-build-coredns.sh）"
[[ -f "$DLV" ]]          || die "dlv 不在 $DLV"

has_dwarf=$(readelf -S "$COREDNS_BIN" 2>/dev/null | grep -c "\.debug_info" || true)
[[ "$has_dwarf" -gt 0 ]] || warn "$COREDNS_BIN 无 DWARF 符号"

# 生成测试用 Corefile（转发 DNS 请求，记录日志）
cat > "$COREFILE" << EOF
.:${DNS_PORT} {
    log
    errors
    forward . /etc/resolv.conf
    cache 30
}
EOF

# 停旧进程
pkill -f "dlv exec.*coredns" 2>/dev/null || true
sleep 1

echo ""
echo "断点建议 (CoreDNS):"
echo ""
echo "  # forward 插件 ServeDNS —— 每次 DNS 转发请求触发"
echo "  b github.com/coredns/coredns/plugin/forward.(*Forward).ServeDNS"
echo ""
echo "  # 主服务器入口 —— 每次 DNS 查询触发（含本地响应）"
echo "  b github.com/coredns/coredns/core/dnsserver.(*Server).ServeDNS"
echo ""
echo "触发:"
echo "  python3 -c \""
echo "    import socket; sock=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); sock.settimeout(3)"
echo "    q=b'\\x00\\x01\\x01\\x00\\x00\\x01\\x00\\x00\\x00\\x00\\x00\\x00'"
echo "    for p in 'google.com'.split('.'): q+=bytes([len(p)])+p.encode()"
echo "    sock.sendto(q+b'\\x00\\x00\\x01\\x00\\x01',('127.0.0.1',${DNS_PORT})); sock.recvfrom(512)"
echo "  \""
echo ""
echo "连接: dlv connect localhost:${DLV_PORT}"
echo ""

info "启动 CoreDNS debug 实例 (dlv exec, dlv:${DLV_PORT}, dns:${DNS_PORT})..."

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
    ok "CoreDNS DNS 端口: 127.0.0.1:${DNS_PORT}"
    ok "日志: $LOG"
else
    warn "dlv 未启动，查看日志:"
    tail -20 "$LOG" 2>/dev/null || true
    exit 1
fi
