#!/usr/bin/env bash
# 调试 kubelet
# kubelet 以 systemd service 形式运行在 Kind 容器内
set -euo pipefail

CLUSTER_NAME="${1:-k8s-debug}"
DLV_PORT="${2:-2348}"
TARGET_NODE="${3:-control-plane}"  # control-plane 或 worker

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[ERR ]\033[0m  $*"; exit 1; }

if [[ "$TARGET_NODE" == "worker" ]]; then
    NODE=$(kind get nodes --name "$CLUSTER_NAME" | grep worker | head -1)
else
    NODE=$(kind get nodes --name "$CLUSTER_NAME" | grep control-plane | head -1)
fi
[[ -n "$NODE" ]] || die "未找到节点: $TARGET_NODE"

KUBELET_PID=$(docker exec "$NODE" pgrep -x kubelet | head -1)
[[ -n "$KUBELET_PID" ]] || die "未找到 kubelet 进程"

info "调试节点: $NODE"
info "kubelet PID: $KUBELET_PID"

echo ""
echo "断点建议 (kubelet):"
echo ""
echo "  # SyncPod —— kubelet 核心控制循环，每次 Pod 状态同步触发"
echo "  b k8s.io/kubernetes/pkg/kubelet/kuberuntime.(*kubeGenericRuntimeManager).SyncPod"
echo ""
echo "  # startContainer —— 发起容器启动，调用 CRI (containerd)"
echo "  b k8s.io/kubernetes/pkg/kubelet/kuberuntime.(*kubeGenericRuntimeManager).startContainer"
echo ""
echo "  # HandlePodAdditions —— 处理新建 Pod 请求"
echo "  b k8s.io/kubernetes/pkg/kubelet.(*Kubelet).HandlePodAdditions"
echo ""
echo "  # computePodActions —— 计算 Pod 需要执行的动作（创建/删除/更新容器）"
echo "  b k8s.io/kubernetes/pkg/kubelet/kuberuntime.(*kubeGenericRuntimeManager).computePodActions"
echo ""
echo "触发调试:"
echo "  kubectl run kubelet-test --image=busybox:latest --restart=Never -- sleep 3600"
echo ""
echo "连接: dlv connect localhost:${DLV_PORT}"
echo ""

docker exec -d "$NODE" bash -c "
    export PATH=\$PATH:/root/go/bin:/usr/local/go/bin
    dlv attach ${KUBELET_PID} \
        --headless \
        --listen=0.0.0.0:${DLV_PORT} \
        --api-version=2 \
        --accept-multiclient \
        --check-go-version=false \
        2>/tmp/dlv-kubelet.log &
    echo \$! > /tmp/dlv-kubelet.pid
"

sleep 2
if docker exec "$NODE" pgrep -f "dlv attach" &>/dev/null; then
    ok "dlv 已启动（$NODE:${DLV_PORT}）"
    echo ""
    echo "宿主机连接命令:"
    echo "  dlv connect localhost:${DLV_PORT}"
else
    echo "dlv 启动失败:"
    docker exec "$NODE" cat /tmp/dlv-kubelet.log 2>/dev/null || true
fi
