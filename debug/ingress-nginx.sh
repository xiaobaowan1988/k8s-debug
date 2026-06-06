#!/usr/bin/env bash
# 调试 ingress-nginx controller（host 进程 + dlv exec 模式）
#
# 验证调用链:
#   Ingress 资源创建/更新
#   → syncIngress() (controller.go:185)
#   → OnUpdate() (nginx.go:680)
#   → generateTemplate() (nginx.go:459)
#   → os.WriteFile(cfgPath, content) (nginx.go:745)
#   → ExecCommand("-s", "reload") (nginx.go:750)
#   → nginx -c /etc/nginx/nginx.conf -s reload
#
# 触发（另开终端）：
#   kubectl create ingress test-ingress --class=nginx \
#     --rule="test.example.com/=test-svc:80"
#
# 连接: dlv connect localhost:2352
set -uo pipefail

DLV_PORT="${1:-2352}"
INGRESS_BIN="${INGRESS_BIN:-/usr/local/bin/nginx-ingress-controller}"
KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
NGINX_BIN="${NGINX_BINARY:-/usr/local/bin/nginx-wrapper}"
DLV=/usr/local/bin/dlv
LOG=/tmp/dlv-ingress-nginx.log

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[ERR ]\033[0m  $*"; exit 1; }

[[ -f "$INGRESS_BIN" ]] || die "$INGRESS_BIN 不存在"
[[ -f "$DLV" ]]          || die "dlv 不在 $DLV"
[[ -f "$KUBECONFIG" ]]   || die "kubeconfig 不存在: $KUBECONFIG"

has_dwarf=$(readelf -S "$INGRESS_BIN" 2>/dev/null | grep -c "\.debug_info" || true)
[[ "$has_dwarf" -gt 0 ]] || warn "$INGRESS_BIN 无 DWARF 符号"

# 停旧进程（pkill 找不到进程时返回 1，忽略）
pkill -f "dlv exec.*nginx-ingress-controller" 2>/dev/null; true
pkill -f "nginx-ingress-controller"           2>/dev/null; true
pkill -f "nginx-wrapper"                      2>/dev/null; true
pkill -f "fake-lua-server"                    2>/dev/null; true
sleep 1

# 确保必需目录存在
mkdir -p /tmp/nginx /etc/nginx/template /etc/nginx/lua \
         /etc/ingress-controller/ssl /etc/ingress-controller/telemetry

# 确保 nginx.tmpl 存在
if [[ ! -f /etc/nginx/template/nginx.tmpl ]]; then
    TMPL_SRC=/root/k8s-src/ingress-nginx/rootfs/etc/nginx/template/nginx.tmpl
    [[ -f "$TMPL_SRC" ]] || die "nginx.tmpl 不存在: $TMPL_SRC"
    cp "$TMPL_SRC" /etc/nginx/template/nginx.tmpl
    info "已复制 nginx.tmpl"
fi

# 确保 lua 文件存在
if [[ ! -f /etc/nginx/lua/balancer.lua ]]; then
    LUA_SRC=/root/k8s-src/ingress-nginx/rootfs/etc/nginx/lua
    [[ -d "$LUA_SRC" ]] && cp -r "$LUA_SRC/"* /etc/nginx/lua/ && info "已复制 lua 文件"
fi

echo ""
echo "断点建议 (ingress-nginx):"
echo ""
echo "  # 1. Ingress 同步入口 —— kubectl apply/create ingress 触发"
echo "  b k8s.io/ingress-nginx/internal/ingress/controller.(*NGINXController).syncIngress"
echo "  等同于: b /root/k8s-src/ingress-nginx/internal/ingress/controller/controller.go:185"
echo ""
echo "  # 2. 写入 nginx.conf —— 查看生成的配置内容"
echo "  b /root/k8s-src/ingress-nginx/internal/ingress/controller/nginx.go:745"
echo "  p cfgPath; p string(content[:500])"
echo ""
echo "  # 3. 触发 nginx reload —— 验证 ExecCommand(\"-s\", \"reload\")"
echo "  b /root/k8s-src/ingress-nginx/internal/ingress/controller/nginx.go:750"
echo ""
echo "触发:"
echo "  kubectl create ingress test-ingress -n default --class=nginx \\"
echo "    --rule='test.example.com/=test-svc:80' --annotation='nginx.ingress.kubernetes.io/rewrite-target=/'"
echo ""
echo "连接: dlv connect localhost:${DLV_PORT}"
echo ""

info "启动 ingress-nginx controller (dlv exec, port ${DLV_PORT})..."

export POD_NAME=ingress-nginx-controller
export POD_NAMESPACE=ingress-nginx
export NGINX_BINARY="$NGINX_BIN"

setsid "$DLV" exec "$INGRESS_BIN" \
    --headless \
    --listen="0.0.0.0:${DLV_PORT}" \
    --api-version=2 \
    --accept-multiclient \
    --continue \
    --check-go-version=false \
    -- \
    --kubeconfig="$KUBECONFIG" \
    --controller-class=k8s.io/ingress-nginx \
    --ingress-class=nginx \
    --publish-service=ingress-nginx/ingress-nginx \
    --election-id=ingress-nginx-leader \
    --disable-catch-all \
    --v=3 \
    </dev/null > "$LOG" 2>&1

sleep 4
if ss -tlnp 2>/dev/null | grep -q ":${DLV_PORT}"; then
    ok "dlv 已在 localhost:${DLV_PORT} 监听"
    ok "日志: $LOG"
else
    warn "dlv 未启动，查看日志:"
    tail -30 "$LOG" 2>/dev/null || true
    exit 1
fi
