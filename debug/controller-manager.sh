#!/usr/bin/env bash
# 调试 kube-controller-manager
# 策略：kube-controller-manager 已通过 dlv exec 启动（由 06-setup-debug-manifests.sh 配置），
#        直接用 dlv connect 连接到端口 2346 的 headless 调试服务。
set -euo pipefail

CLUSTER_NAME="${1:-k8s-debug}"
DLV_PORT="${2:-2346}"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[ERR ]\033[0m  $*"; exit 1; }

CONTROL_PLANE=$(kind get nodes --name "$CLUSTER_NAME" 2>/dev/null | grep control-plane | head -1)
[[ -n "$CONTROL_PLANE" ]] || die "未找到集群 $CLUSTER_NAME 的控制平面节点"

# 检查 dlv 是否正在监听
if ! docker exec "$CONTROL_PLANE" ss -tlnp 2>/dev/null | grep -q ":${DLV_PORT}"; then
    warn "端口 ${DLV_PORT} 未在监听。正在配置 dlv exec 模式..."
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    bash "${SCRIPT_DIR}/../scripts/06-setup-debug-manifests.sh" "$CLUSTER_NAME"
fi

info "kube-controller-manager dlv 服务已在端口 $DLV_PORT 就绪"
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  kube-controller-manager 调试指南"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "连接命令:"
echo "  dlv connect localhost:${DLV_PORT}"
echo ""
echo "VS Code launch.json:"
cat << EOF
{
  "type": "go",
  "request": "attach",
  "mode": "remote",
  "name": "kube-controller-manager",
  "remotePath": "\${workspaceFolder}",
  "host": "127.0.0.1",
  "port": ${DLV_PORT}
}
EOF
echo ""
echo "关键断点:"
echo "  b k8s.io/kubernetes/pkg/controller/deployment.(*DeploymentController).syncDeployment"
echo "    → Deployment 控制器主循环 — 处理 Deployment 变更，生成 ReplicaSet"
echo ""
echo "  b k8s.io/kubernetes/pkg/controller/replicaset.(*ReplicaSetController).syncReplicaSet"
echo "    → ReplicaSet 控制器 — 计算期望 Pod 数量差并创建/删除 Pod"
echo ""
echo "  b k8s.io/kubernetes/pkg/controller/garbagecollector.(*GarbageCollector).runAttemptToDeleteWorker"
echo "    → GC 控制器 — 处理孤儿资源垃圾回收"
echo ""
echo "触发方式 (另一终端):"
echo "  kubectl create deployment cm-test --image=registry.k8s.io/pause:3.9 --replicas=2"
echo "    → 触发: syncDeployment → syncReplicaSet → Pod 创建"
echo ""
echo "调试流程:"
echo "  (dlv) b k8s.io/kubernetes/pkg/controller/deployment.(*DeploymentController).syncDeployment"
echo "  (dlv) c               # 恢复运行（等待断点）"
echo "  # 另一终端: kubectl create deployment ..."
echo "  # 断点触发后:"
echo "  (dlv) stack           # 查看完整调用栈"
echo "  (dlv) locals          # 查看局部变量"
echo "  (dlv) p d             # 打印 Deployment 对象"
echo "  (dlv) n               # 单步执行"
echo "  (dlv) c               # 继续运行"
echo ""
