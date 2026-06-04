#!/usr/bin/env bash
# 调试 kube-proxy（host 进程 + dlv exec 模式）
#
# kube-proxy 二进制已含 DWARF 符号，直接用 dlv exec 运行
# 使用 /root/.kube/config 连接 apiserver
#
# 触发（另开终端）：
#   kubectl create service clusterip proxy-test --tcp=80:80
#   kubectl delete service proxy-test
set -euo pipefail

DLV_PORT="${1:-2349}"
PROXY_BIN="${PROXY_BIN:-/usr/local/bin/kube-proxy}"
PROXY_CONFIG=/tmp/kube-proxy-debug.yaml
KUBECONFIG="${KUBECONFIG:-/root/.kube/config}"
DLV=/usr/local/bin/dlv
LOG=/tmp/dlv-kube-proxy.log

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[ERR ]\033[0m  $*"; exit 1; }

[[ -f "$PROXY_BIN" ]] || die "$PROXY_BIN 不存在"
[[ -f "$DLV" ]]        || die "dlv 不在 $DLV"
[[ -f "$KUBECONFIG" ]] || die "kubeconfig 不存在: $KUBECONFIG"

has_dwarf=$(readelf -S "$PROXY_BIN" 2>/dev/null | grep -c "\.debug_info" || true)
[[ "$has_dwarf" -gt 0 ]] || warn "$PROXY_BIN 无 DWARF 符号"

# 停旧进程
pkill -f "dlv exec.*kube-proxy" 2>/dev/null || true
pkill -x kube-proxy             2>/dev/null || true
sleep 1

# 生成 KubeProxyConfiguration
cat > "$PROXY_CONFIG" << EOF
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
clientConnection:
  kubeconfig: ${KUBECONFIG}
clusterCIDR: "10.244.0.0/16"
mode: "iptables"
healthzBindAddress: "0.0.0.0:10256"
metricsBindAddress: "127.0.0.1:10249"
EOF

echo ""
echo "断点建议 (kube-proxy):"
echo ""
echo "  # iptables 规则同步核心 —— Service/Endpoint 变化时触发"
echo "  b k8s.io/kubernetes/pkg/proxy/iptables.(*Proxier).syncProxyRules"
echo ""
echo "  # 同步循环调度"
echo "  b k8s.io/kubernetes/pkg/proxy.(*BaseServicePortCache).apply"
echo ""
echo "触发:"
echo "  kubectl create service clusterip proxy-bp-test --tcp=80:80"
echo "  kubectl delete service proxy-bp-test"
echo ""
echo "连接: dlv connect localhost:${DLV_PORT}"
echo ""

info "启动 kube-proxy (dlv exec, port ${DLV_PORT})..."

nohup "$DLV" exec "$PROXY_BIN" \
    --headless \
    --listen="0.0.0.0:${DLV_PORT}" \
    --api-version=2 \
    --accept-multiclient \
    --continue \
    --check-go-version=false \
    -- \
    --config="$PROXY_CONFIG" \
    --hostname-override="$(hostname)" \
    --v=5 \
    > "$LOG" 2>&1 &
disown

sleep 3
if ss -tlnp 2>/dev/null | grep -q ":${DLV_PORT}"; then
    ok "dlv 已在 localhost:${DLV_PORT} 监听"
    ok "kube-proxy 配置: $PROXY_CONFIG"
    ok "日志: $LOG"
else
    warn "dlv 未启动，查看日志:"
    tail -20 "$LOG" 2>/dev/null || true
    exit 1
fi
