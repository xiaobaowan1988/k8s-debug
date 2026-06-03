#!/usr/bin/env bash
# 调试 kube-controller-manager（直接连接本机 dlv 端口）
set -euo pipefail

DLV_PORT="${1:-2346}"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }

if ! ss -tlnp 2>/dev/null | grep -q ":${DLV_PORT}"; then
    warn "端口 ${DLV_PORT} 未在监听，正在配置 dlv exec 模式..."
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    bash "${SCRIPT_DIR}/../scripts/06-setup-debug-manifests.sh"
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
echo "    → Deployment 控制器主循环 — 处理变更，生成 ReplicaSet"
echo ""
echo "  b k8s.io/kubernetes/pkg/controller/replicaset.(*ReplicaSetController).syncReplicaSet"
echo "    → ReplicaSet 控制器 — 计算期望 Pod 数量差并创建/删除 Pod"
echo ""
echo "触发方式 (另一终端):"
echo "  kubectl create deployment cm-test --image=registry.k8s.io/pause:3.9 --replicas=2"
echo ""
echo "调试流程:"
echo "  (dlv) b k8s.io/kubernetes/pkg/controller/deployment.(*DeploymentController).syncDeployment"
echo "  (dlv) c"
echo "  # 另一终端: kubectl create deployment ..."
echo "  (dlv) stack && locals && p d"
echo ""
