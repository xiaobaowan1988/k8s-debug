#!/usr/bin/env bash
# 调试 kubelet（直接在本机 attach）
set -euo pipefail

DLV_PORT="${1:-2348}"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[ERR ]\033[0m  $*"; exit 1; }

KUBELET_PID=$(pgrep -x kubelet | head -1)
[[ -n "$KUBELET_PID" ]] || die "未找到 kubelet 进程"

info "kubelet PID: $KUBELET_PID"

echo ""
echo "断点建议 (kubelet):"
echo ""
echo "  b k8s.io/kubernetes/pkg/kubelet/kuberuntime.(*kubeGenericRuntimeManager).SyncPod"
echo "  b k8s.io/kubernetes/pkg/kubelet/kuberuntime.(*kubeGenericRuntimeManager).startContainer"
echo "  b k8s.io/kubernetes/pkg/kubelet.(*Kubelet).HandlePodAdditions"
echo "  b k8s.io/kubernetes/pkg/kubelet/kuberuntime.(*kubeGenericRuntimeManager).computePodActions"
echo ""
echo "触发调试:"
echo "  kubectl run kubelet-test --image=busybox:latest --restart=Never -- sleep 3600"
echo ""
echo "连接: dlv connect localhost:${DLV_PORT}"
echo ""

dlv attach "${KUBELET_PID}" \
    --headless \
    --listen="0.0.0.0:${DLV_PORT}" \
    --api-version=2 \
    --accept-multiclient \
    --check-go-version=false \
    > /tmp/dlv-kubelet.log 2>&1 &

sleep 2
if pgrep -f "dlv attach" &>/dev/null; then
    ok "dlv 已启动（localhost:${DLV_PORT}）"
else
    echo "dlv 启动失败:"
    cat /tmp/dlv-kubelet.log 2>/dev/null || true
fi
