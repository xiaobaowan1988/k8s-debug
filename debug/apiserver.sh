#!/usr/bin/env bash
# 调试 kube-apiserver
# 策略：在 Kind 节点内找到 apiserver 进程 PID，通过 dlv attach + headless 模式
#        暴露端口到宿主机，使用 dlv connect 连接
set -euo pipefail

CLUSTER_NAME="${1:-k8s-debug}"
DLV_PORT="${2:-2345}"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[ERR ]\033[0m  $*"; exit 1; }

CONTROL_PLANE=$(kind get nodes --name "$CLUSTER_NAME" | grep control-plane | head -1)
[[ -n "$CONTROL_PLANE" ]] || die "未找到控制平面节点"

info "查找 kube-apiserver 进程..."
APISERVER_PID=$(docker exec "$CONTROL_PLANE" pgrep -f "kube-apiserver" | head -1)
[[ -n "$APISERVER_PID" ]] || die "未找到 kube-apiserver 进程"
info "kube-apiserver PID: $APISERVER_PID"

# 检查 dlv 是否在节点内
if ! docker exec "$CONTROL_PLANE" which dlv &>/dev/null; then
    info "在节点内安装 dlv..."
    docker exec "$CONTROL_PLANE" bash -c '
        export GOPATH=/root/go
        export PATH=$PATH:/usr/local/go/bin:$GOPATH/bin
        GOFLAGS="" go install github.com/go-delve/delve/cmd/dlv@latest 2>/dev/null || \
        (apt-get install -y -qq golang-go 2>/dev/null; GOFLAGS="" go install github.com/go-delve/delve/cmd/dlv@latest)
    ' || die "dlv 安装失败，请手动安装到节点"
fi

info "在节点内启动 dlv headless 服务（端口 $DLV_PORT）"
echo ""
echo "断点建议 (kube-apiserver):"
echo "  b k8s.io/apiserver/pkg/admission/chain.go:55"
echo "    → 准入控制器链式调用入口"
echo ""
echo "  b k8s.io/apiserver/pkg/registry/generic/registry/store.go:370"
echo "    → Create() 方法：对象写入 etcd 的瞬间"
echo ""
echo "  b k8s.io/apiserver/pkg/server/genericapiserver.go:400"
echo "    → API Server 请求处理路由分发"
echo ""
echo "连接命令（在另一终端执行）:"
echo "  dlv connect localhost:${DLV_PORT}"
echo ""
echo "等效 IDE 配置 (VS Code launch.json):"
cat << EOF
{
  "type": "go",
  "request": "attach",
  "mode": "remote",
  "remotePath": "\${workspaceFolder}",
  "host": "127.0.0.1",
  "port": ${DLV_PORT}
}
EOF
echo ""

# 启动 dlv headless（在节点内后台运行）
docker exec -d "$CONTROL_PLANE" bash -c "
    export PATH=\$PATH:/root/go/bin:/usr/local/go/bin
    dlv attach ${APISERVER_PID} \
        --headless \
        --listen=0.0.0.0:${DLV_PORT} \
        --api-version=2 \
        --accept-multiclient \
        --log \
        2>/tmp/dlv-apiserver.log &
    echo \$! > /tmp/dlv-apiserver.pid
"

sleep 2

# 验证 dlv 是否启动成功
if docker exec "$CONTROL_PLANE" pgrep -f "dlv attach" &>/dev/null; then
    ok "dlv 已在节点内启动，监听端口 $DLV_PORT"
    echo ""
    echo "现在运行: dlv connect localhost:${DLV_PORT}"
    echo "日志: docker exec $CONTROL_PLANE cat /tmp/dlv-apiserver.log"
else
    echo "dlv 启动失败，查看日志:"
    docker exec "$CONTROL_PLANE" cat /tmp/dlv-apiserver.log 2>/dev/null || true
fi
