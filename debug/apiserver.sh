#!/usr/bin/env bash
# 调试 kube-apiserver
# 策略：kube-apiserver 已通过 dlv exec 启动（由 06-setup-debug-manifests.sh 配置），
#        直接用 dlv connect 连接到端口 2345 的 headless 调试服务。
set -euo pipefail

CLUSTER_NAME="${1:-k8s-debug}"
DLV_PORT="${2:-2345}"

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

info "kube-apiserver dlv 服务已在端口 $DLV_PORT 就绪"
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  kube-apiserver 调试指南"
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
  "name": "kube-apiserver",
  "remotePath": "\${workspaceFolder}",
  "host": "127.0.0.1",
  "port": ${DLV_PORT}
}
EOF
echo ""
echo "关键断点:"
echo "  b k8s.io/apiserver/pkg/registry/generic/registry/store.go:446"
echo "    → (*Store).Create() - 对象写入 etcd 前"
echo ""
echo "  b k8s.io/apiserver/pkg/endpoints/handlers/create.go:184"
echo "    → createHandler - HTTP CREATE 请求处理入口"
echo ""
echo "  b k8s.io/apiserver/pkg/admission/chain.go:55"
echo "    → 准入控制器链式调用"
echo ""
echo "触发方式 (另一终端):"
echo "  kubectl create deployment test --image=nginx:alpine"
echo "    → 触发: createHandler → 准入 → (*Store).Create()"
echo ""
echo "  kubectl create namespace debug-ns"
echo "    → 最简单的 CREATE 触发"
echo ""
echo "调试流程:"
echo "  (dlv) b k8s.io/apiserver/pkg/registry/generic/registry/store.go:446"
echo "  (dlv) c               # 恢复运行（等待断点）"
echo "  # 另一终端: kubectl create deployment ..."
echo "  # 断点触发后:"
echo "  (dlv) stack           # 查看完整调用栈"
echo "  (dlv) locals          # 查看局部变量"
echo "  (dlv) p obj           # 打印 obj 变量"
echo "  (dlv) n               # 单步执行"
echo "  (dlv) c               # 继续运行"
echo ""
