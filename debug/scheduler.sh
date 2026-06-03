#!/usr/bin/env bash
# 调试 kube-scheduler
# 特殊策略：停止静态 Pod 中的 scheduler，改为在宿主机直接运行 dlv exec
# 这样可以直接在宿主机 IDE 连接，无需进入容器
set -euo pipefail

CLUSTER_NAME="${1:-k8s-debug}"
DLV_PORT="${2:-2347}"
MODE="${3:-attach}"   # attach: 附加现有进程; exec: 停止静态Pod后手动启动

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[ERR ]\033[0m  $*"; exit 1; }

CONTROL_PLANE=$(kind get nodes --name "$CLUSTER_NAME" | grep control-plane | head -1)
[[ -n "$CONTROL_PLANE" ]] || die "未找到控制平面节点"

echo ""
echo "断点建议 (kube-scheduler):"
echo ""
echo "  # 调度主循环入口 —— 每次调度一个 Pod 时触发"
echo "  b k8s.io/kubernetes/pkg/scheduler.(*Scheduler).scheduleOne"
echo ""
echo "  # 过滤插件 —— 观察节点筛选逻辑"
echo "  b k8s.io/kubernetes/pkg/scheduler/framework/runtime.(*frameworkImpl).RunFilterPlugins"
echo ""
echo "  # 打分插件 —— 观察节点优先级打分"
echo "  b k8s.io/kubernetes/pkg/scheduler/framework/runtime.(*frameworkImpl).RunScorePlugins"
echo ""
echo "  # 绑定 Pod 到节点"
echo "  b k8s.io/kubernetes/pkg/scheduler/framework/runtime.(*frameworkImpl).RunBindPlugins"
echo ""
echo "触发调试:"
echo "  kubectl create deployment sched-test --image=nginx:alpine"
echo "  （确保 Pod 处于 Pending 状态时断点会触发）"
echo ""

if [[ "$MODE" == "exec" ]]; then
    info "模式: exec — 停止静态 Pod，宿主机直接运行 dlv exec"
    warn "此模式会暂时停止集群的调度功能！"

    # 获取集群 kubeconfig
    KUBECONFIG_PATH=$(kind get kubeconfig --name "$CLUSTER_NAME" 2>/dev/null | head -1)

    # 停止静态 Pod 中的 scheduler（移除 manifest）
    docker exec "$CONTROL_PLANE" bash -c '
        mv /etc/kubernetes/manifests/kube-scheduler.yaml \
           /etc/kubernetes/kube-scheduler.yaml.bak 2>/dev/null || true
        echo "scheduler 静态 Pod manifest 已移除"
    '

    sleep 5

    SCHEDULER_BIN="$(dirname "$0")/../build/kubernetes/kube-scheduler"
    [[ -f "$SCHEDULER_BIN" ]] || die "kube-scheduler 二进制不存在: $SCHEDULER_BIN"

    info "在宿主机启动 dlv exec kube-scheduler"
    info "kubeconfig: ~/.kube/config (context: kind-${CLUSTER_NAME})"
    echo ""
    echo "执行以下命令（在宿主机）:"
    echo ""
    echo "  dlv exec ${SCHEDULER_BIN} \\"
    echo "    --headless \\"
    echo "    --listen=:${DLV_PORT} \\"
    echo "    --api-version=2 \\"
    echo "    -- \\"
    echo "    --kubeconfig=\$HOME/.kube/config \\"
    echo "    --leader-elect=false \\"
    echo "    --config=/dev/null"
    echo ""
    echo "连接: dlv connect localhost:${DLV_PORT}"
    echo ""
    echo "恢复 scheduler 静态 Pod:"
    echo "  docker exec $CONTROL_PLANE mv /etc/kubernetes/kube-scheduler.yaml.bak \\"
    echo "    /etc/kubernetes/manifests/kube-scheduler.yaml"

else
    # attach 模式：附加到现有进程
    SCHED_PID=$(docker exec "$CONTROL_PLANE" pgrep -f "kube-scheduler" | head -1)
    [[ -n "$SCHED_PID" ]] || die "未找到 kube-scheduler 进程"
    info "kube-scheduler PID: $SCHED_PID"

    docker exec -d "$CONTROL_PLANE" bash -c "
        export PATH=\$PATH:/root/go/bin:/usr/local/go/bin
        dlv attach ${SCHED_PID} \
            --headless \
            --listen=0.0.0.0:${DLV_PORT} \
            --api-version=2 \
            --accept-multiclient \
            2>/tmp/dlv-scheduler.log &
    "

    sleep 2
    if docker exec "$CONTROL_PLANE" pgrep -f "dlv attach" &>/dev/null; then
        ok "dlv 已启动，监听端口 $DLV_PORT"
        echo "连接: dlv connect localhost:${DLV_PORT}"
    fi
fi
