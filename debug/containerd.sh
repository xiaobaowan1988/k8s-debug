#!/usr/bin/env bash
# 调试 containerd（CRI 层，直接在本机 attach）
set -euo pipefail

DLV_PORT="${1:-2350}"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[ERR ]\033[0m  $*"; exit 1; }

CTD_PID=$(pgrep -x containerd | head -1)
[[ -n "$CTD_PID" ]] || die "未找到 containerd 进程"

info "containerd PID: $CTD_PID"

echo ""
echo "断点建议 (containerd CRI 层):"
echo ""
echo "  b github.com/containerd/containerd/v2/internal/cri/server.(*criService).RunPodSandbox"
echo "  b github.com/containerd/containerd/v2/internal/cri/server.(*criService).CreateContainer"
echo "  b github.com/containerd/containerd/v2/internal/cri/server.(*criService).StartContainer"
echo "  b github.com/containerd/containerd/v2/internal/cri/instrument.(*instrumentedService).RunPodSandbox"
echo ""
echo "辅助工具:"
echo "  ctr -n k8s.io containers list"
echo "  ctr -n k8s.io tasks list"
echo ""
echo "触发调试:"
echo "  kubectl run ctd-test --image=busybox:latest -- sleep 3600"
echo ""
echo "连接: dlv connect localhost:${DLV_PORT}"
echo ""

dlv attach "${CTD_PID}" \
    --headless \
    --listen="0.0.0.0:${DLV_PORT}" \
    --api-version=2 \
    --accept-multiclient \
    --continue \
    --check-go-version=false \
    > /tmp/dlv-containerd.log 2>&1 &
disown

sleep 2
if ss -tlnp 2>/dev/null | grep -q ":${DLV_PORT}"; then
    ok "dlv 已启动（localhost:${DLV_PORT}）"
else
    echo "dlv 启动失败:"
    cat /tmp/dlv-containerd.log 2>/dev/null || true
fi
