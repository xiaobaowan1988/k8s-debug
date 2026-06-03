#!/usr/bin/env bash
# 注入带 sleep 桩点的 runc（用于 dlv attach 调试）
set -euo pipefail

CLUSTER_NAME="${1:-k8s-debug}"
RUNTIME_BUILD="${2:-$(dirname "$0")/../build/runtime}"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[ERR ]\033[0m  $*"; exit 1; }

PATCHED_RUNC="$RUNTIME_BUILD/runc.patched"
[[ -f "$PATCHED_RUNC" ]] || die "patched runc 不存在，请先运行: make build-runc-patched"

CONTROL_PLANE=$(kind get nodes --name "$CLUSTER_NAME" | grep "control-plane" | head -1)

info "注入 patched runc（含 30s sleep 桩点）到 $CONTROL_PLANE"
warn "注意：此 runc 用于调试，每次容器启动会暂停 30 秒！"

docker exec "$CONTROL_PLANE" bash -c "
    cp /usr/local/sbin/runc /usr/local/sbin/runc.normal 2>/dev/null || true
"
docker cp "$PATCHED_RUNC" "${CONTROL_PLANE}:/usr/local/sbin/runc"
docker exec "$CONTROL_PLANE" chmod +x /usr/local/sbin/runc

ok "patched runc 注入完成"
echo ""
echo "调试步骤："
echo "  1. kubectl run test-pod --image=<image> --restart=Never"
echo "  2. (在另一终端) docker exec ${CONTROL_PLANE} pgrep runc"
echo "  3. dlv attach <PID> --headless --listen=:2351 --api-version=2"
echo "     或直接在节点内: docker exec -it ${CONTROL_PLANE} dlv attach <PID>"
echo ""
echo "还原正常 runc："
echo "  docker exec ${CONTROL_PLANE} cp /usr/local/sbin/runc.normal /usr/local/sbin/runc"
