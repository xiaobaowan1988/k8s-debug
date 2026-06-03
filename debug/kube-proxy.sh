#!/usr/bin/env bash
# 调试 kube-proxy（直接在本机 attach）
set -euo pipefail

DLV_PORT="${1:-2349}"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[ERR ]\033[0m  $*"; exit 1; }

PROXY_PID=$(pgrep -f "kube-proxy" | head -1)
[[ -n "$PROXY_PID" ]] || die "未找到 kube-proxy 进程"

info "kube-proxy PID: $PROXY_PID"

echo ""
echo "断点建议 (kube-proxy):"
echo ""
echo "  b k8s.io/kubernetes/pkg/proxy/iptables.(*Proxier).syncProxyRules"
echo "    → iptables 规则同步核心"
echo ""
echo "  b k8s.io/kubernetes/pkg/proxy/ipvs.(*Proxier).syncProxyRules"
echo "    → IPVS 规则同步（如果启用了 IPVS）"
echo ""
echo "触发调试:"
echo "  kubectl create deployment proxy-test --image=nginx:alpine"
echo "  kubectl expose deployment proxy-test --port=80 --type=ClusterIP"
echo ""
echo "观察 iptables 规则变化:"
echo "  iptables -t nat -L KUBE-SERVICES -n --line-numbers"
echo ""
echo "连接: dlv connect localhost:${DLV_PORT}"
echo ""

dlv attach "${PROXY_PID}" \
    --headless \
    --listen="0.0.0.0:${DLV_PORT}" \
    --api-version=2 \
    --accept-multiclient \
    --check-go-version=false \
    > /tmp/dlv-proxy.log 2>&1 &

sleep 2
if pgrep -f "dlv attach" &>/dev/null; then
    ok "dlv 已启动（localhost:${DLV_PORT}）"
else
    cat /tmp/dlv-proxy.log 2>/dev/null || true
fi
