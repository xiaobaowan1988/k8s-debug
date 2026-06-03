#!/usr/bin/env bash
# 调试 containerd（CRI 层）
# 观察 RunPodSandbox / CreateContainer / StartContainer 等 CRI 调用
set -euo pipefail

CLUSTER_NAME="${1:-k8s-debug}"
DLV_PORT="${2:-2350}"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[ERR ]\033[0m  $*"; exit 1; }

CONTROL_PLANE=$(kind get nodes --name "$CLUSTER_NAME" | grep control-plane | head -1)
[[ -n "$CONTROL_PLANE" ]] || die "未找到控制平面节点"

CTD_PID=$(docker exec "$CONTROL_PLANE" pgrep -x containerd | head -1)
[[ -n "$CTD_PID" ]] || die "未找到 containerd 进程"

info "containerd PID: $CTD_PID"

echo ""
echo "断点建议 (containerd CRI 层):"
echo ""
echo "  # RunPodSandbox —— Pause 容器（infra container）诞生"
echo "  b github.com/containerd/containerd/pkg/cri/server.(*criService).RunPodSandbox"
echo ""
echo "  # CreateContainer —— 业务容器 OCI Spec 组装"
echo "  b github.com/containerd/containerd/pkg/cri/server.(*criService).CreateContainer"
echo ""
echo "  # StartContainer —— 容器启动（调用 shim → runc）"
echo "  b github.com/containerd/containerd/pkg/cri/server.(*criService).StartContainer"
echo ""
echo "  # StopContainer —— 容器停止"
echo "  b github.com/containerd/containerd/pkg/cri/server.(*criService).StopContainer"
echo ""
echo "  # containerd-shim 交互层"
echo "  b github.com/containerd/containerd/runtime/v2.(*TaskManager).Create"
echo ""
echo "辅助工具 —— 查看 containerd 当前状态:"
echo "  docker exec $CONTROL_PLANE ctr -n k8s.io containers list"
echo "  docker exec $CONTROL_PLANE ctr -n k8s.io tasks list"
echo "  docker exec $CONTROL_PLANE ctr -n k8s.io images list"
echo ""
echo "触发调试:"
echo "  kubectl run ctd-test --image=busybox:latest -- sleep 3600"
echo ""
echo "连接: dlv connect localhost:${DLV_PORT}"
echo ""

docker exec -d "$CONTROL_PLANE" bash -c "
    export PATH=\$PATH:/root/go/bin:/usr/local/go/bin
    dlv attach ${CTD_PID} \
        --headless \
        --listen=0.0.0.0:${DLV_PORT} \
        --api-version=2 \
        --accept-multiclient \
        2>/tmp/dlv-containerd.log &
"

sleep 2
if docker exec "$CONTROL_PLANE" pgrep -f "dlv attach" &>/dev/null; then
    ok "dlv 已启动，监听端口 $DLV_PORT"
else
    docker exec "$CONTROL_PLANE" cat /tmp/dlv-containerd.log 2>/dev/null || true
fi
