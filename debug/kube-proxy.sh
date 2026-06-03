#!/usr/bin/env bash
# 调试 kube-proxy（iptables / IPVS 规则生成）
set -euo pipefail

CLUSTER_NAME="${1:-k8s-debug}"
DLV_PORT="${2:-2349}"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[ERR ]\033[0m  $*"; exit 1; }

CONTROL_PLANE=$(kind get nodes --name "$CLUSTER_NAME" | grep control-plane | head -1)
[[ -n "$CONTROL_PLANE" ]] || die "未找到控制平面节点"

PROXY_PID=$(docker exec "$CONTROL_PLANE" pgrep -f "kube-proxy" | head -1)
[[ -n "$PROXY_PID" ]] || die "未找到 kube-proxy 进程"

info "kube-proxy PID: $PROXY_PID"

echo ""
echo "断点建议 (kube-proxy):"
echo ""
echo "  # iptables 模式 —— Service iptables 规则同步核心"
echo "  b k8s.io/kubernetes/pkg/proxy/iptables.(*Proxier).syncProxyRules"
echo ""
echo "  # IPVS 模式 —— IPVS 规则同步（如果启用了 IPVS）"
echo "  b k8s.io/kubernetes/pkg/proxy/ipvs.(*Proxier).syncProxyRules"
echo ""
echo "  # Service 变化处理"
echo "  b k8s.io/kubernetes/pkg/proxy.(*BaseServicePortCache).OnServiceAdd"
echo ""
echo "触发调试:"
echo "  # 创建 Service 时 syncProxyRules 会触发"
echo "  kubectl create deployment proxy-test --image=nginx:alpine"
echo "  kubectl expose deployment proxy-test --port=80 --type=ClusterIP"
echo ""
echo "观察 iptables 规则变化:"
echo "  docker exec $CONTROL_PLANE iptables -t nat -L KUBE-SERVICES -n --line-numbers"
echo ""
echo "连接: dlv connect localhost:${DLV_PORT}"
echo ""

docker exec -d "$CONTROL_PLANE" bash -c "
    export PATH=\$PATH:/root/go/bin:/usr/local/go/bin
    dlv attach ${PROXY_PID} \
        --headless \
        --listen=0.0.0.0:${DLV_PORT} \
        --api-version=2 \
        --accept-multiclient \
        --check-go-version=false \
        2>/tmp/dlv-proxy.log &
"

sleep 2
if docker exec "$CONTROL_PLANE" pgrep -f "dlv attach" &>/dev/null; then
    ok "dlv 已启动，监听端口 $DLV_PORT"
fi
