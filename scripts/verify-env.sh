#!/usr/bin/env bash
# 验证调试环境是否就绪
set -euo pipefail

BUILD_DIR="${1:-$(dirname "$0")/../build}"
CLUSTER_NAME="${2:-k8s-debug}"

ok()    { echo -e "  \033[1;32m✓\033[0m  $*"; }
fail()  { echo -e "  \033[1;31m✗\033[0m  $*"; ERRORS=$((ERRORS+1)); }
info()  { echo -e "  \033[1;34m·\033[0m  $*"; }
ERRORS=0

echo ""
echo "══════════════════════════════════════════════"
echo "  Kubernetes 源码调试环境检查"
echo "══════════════════════════════════════════════"
echo ""

echo "[ 工具链 ]"
command -v go     &>/dev/null && ok "Go: $(go version | awk '{print $3}')"       || fail "Go 未安装"
command -v dlv    &>/dev/null && ok "Delve: $(dlv version 2>/dev/null | head -1)" || fail "Delve 未安装"
command -v docker &>/dev/null && ok "Docker: $(docker version --format '{{.Server.Version}}' 2>/dev/null)" || fail "Docker 未安装或未运行"
command -v kind   &>/dev/null && ok "Kind: $(kind version)"                       || fail "Kind 未安装"
command -v kubectl &>/dev/null && ok "kubectl 已安装"                             || fail "kubectl 未安装"
command -v tmux   &>/dev/null && ok "tmux 已安装"                                 || info "tmux 未安装（make debug-all 需要）"
echo ""

echo "[ 编译产物 ]"
K8S_BINS=(kube-apiserver kube-controller-manager kube-scheduler kubelet kube-proxy)
for bin in "${K8S_BINS[@]}"; do
    f="${BUILD_DIR}/kubernetes/${bin}"
    if [[ -f "$f" ]]; then
        size=$(stat -c '%s' "$f")
        if file "$f" | grep -q "not stripped"; then
            ok "$bin ($(numfmt --to=iec $size), 含调试符号)"
        else
            fail "$bin 存在但缺失调试符号（已被 strip）"
        fi
    else
        fail "$bin 未编译（运行 make build-k8s）"
    fi
done

for bin in containerd runc; do
    case "$bin" in
        containerd) f="${BUILD_DIR}/runtime/containerd-bin/containerd" ;;
        runc)       f="${BUILD_DIR}/runtime/runc" ;;
    esac
    if [[ -f "$f" ]]; then
        ok "$bin ($(numfmt --to=iec $(stat -c '%s' "$f")))"
    else
        info "$bin 未编译（可选，运行 make build-${bin}）"
    fi
done
echo ""

echo "[ Kind 集群 ]"
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    ok "集群 $CLUSTER_NAME 存在"
    NODES=$(kubectl get nodes --context "kind-${CLUSTER_NAME}" 2>/dev/null | grep -c Ready || echo 0)
    ok "就绪节点数: $NODES"
else
    fail "集群 $CLUSTER_NAME 不存在（运行 make cluster-create）"
fi
echo ""

echo "══════════════════════════════════════════════"
if [[ $ERRORS -eq 0 ]]; then
    echo -e "  \033[1;32m✓ 所有检查通过，环境就绪\033[0m"
    echo "  运行 'make debug-all' 开启全链路调试"
else
    echo -e "  \033[1;31m✗ $ERRORS 项检查失败\033[0m"
fi
echo "══════════════════════════════════════════════"
echo ""
