#!/usr/bin/env bash
# 调试 kube-controller-manager
set -euo pipefail

CLUSTER_NAME="${1:-k8s-debug}"
DLV_PORT="${2:-2346}"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[ERR ]\033[0m  $*"; exit 1; }

CONTROL_PLANE=$(kind get nodes --name "$CLUSTER_NAME" | grep control-plane | head -1)
[[ -n "$CONTROL_PLANE" ]] || die "未找到控制平面节点"

CM_PID=$(docker exec "$CONTROL_PLANE" pgrep -f "kube-controller-manager" | head -1)
[[ -n "$CM_PID" ]] || die "未找到 kube-controller-manager 进程"

info "kube-controller-manager PID: $CM_PID"

echo ""
echo "断点建议 (kube-controller-manager):"
echo ""
echo "  # Deployment 控制器 —— 观察 ReplicaSet 生成"
echo "  b k8s.io/kubernetes/pkg/controller/deployment.(*DeploymentController).syncDeployment"
echo ""
echo "  # ReplicaSet 控制器 —— 观察 Pod 对象生成"
echo "  b k8s.io/kubernetes/pkg/controller/replicaset.(*ReplicaSetController).syncReplicaSet"
echo ""
echo "  # GC 控制器 —— 观察垃圾回收"
echo "  b k8s.io/kubernetes/pkg/controller/garbagecollector.(*GarbageCollector).runAttemptToDeleteWorker"
echo ""
echo "触发调试:"
echo "  kubectl create deployment test-debug --image=nginx:alpine --replicas=2"
echo ""
echo "连接: dlv connect localhost:${DLV_PORT}"
echo ""

docker exec -d "$CONTROL_PLANE" bash -c "
    export PATH=\$PATH:/root/go/bin:/usr/local/go/bin
    dlv attach ${CM_PID} \
        --headless \
        --listen=0.0.0.0:${DLV_PORT} \
        --api-version=2 \
        --accept-multiclient \
        2>/tmp/dlv-cm.log &
    echo \$! > /tmp/dlv-cm.pid
"

sleep 2
if docker exec "$CONTROL_PLANE" pgrep -f "dlv attach" &>/dev/null; then
    ok "dlv 已启动，监听端口 $DLV_PORT"
else
    docker exec "$CONTROL_PLANE" cat /tmp/dlv-cm.log 2>/dev/null || true
fi
