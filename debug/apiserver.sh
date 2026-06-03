#!/usr/bin/env bash
# 调试 kube-apiserver（直接连接本机 dlv 端口）
set -euo pipefail

DLV_PORT="${1:-2345}"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }

if ! ss -tlnp 2>/dev/null | grep -q ":${DLV_PORT}"; then
    warn "端口 ${DLV_PORT} 未在监听，正在配置 dlv exec 模式..."
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    bash "${SCRIPT_DIR}/../scripts/06-setup-debug-manifests.sh"
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
echo "  kubectl create namespace debug-ns"
echo ""
echo "调试流程:"
echo "  (dlv) b k8s.io/apiserver/pkg/registry/generic/registry/store.go:446"
echo "  (dlv) c"
echo "  # 另一终端: kubectl create deployment ..."
echo "  (dlv) stack && locals"
echo ""
