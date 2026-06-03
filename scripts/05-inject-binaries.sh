#!/usr/bin/env bash
# 将源码编译的调试版二进制注入到 Kind 节点
# 替换策略：
#   1. 备份原始二进制
#   2. 复制调试版二进制
#   3. 重启对应的静态 Pod（通过 kubelet 自动检测文件变化重启）
set -euo pipefail

CLUSTER_NAME="${1:-k8s-debug}"
K8S_BUILD="${2:-$(dirname "$0")/../build/kubernetes}"
RUNTIME_BUILD="${3:-$(dirname "$0")/../build/runtime}"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[ERR ]\033[0m  $*"; exit 1; }

[[ -d "$K8S_BUILD" ]] || die "k8s 构建产物不存在: $K8S_BUILD（先运行 make build-k8s）"

CONTROL_PLANE_NODE=$(kind get nodes --name "$CLUSTER_NAME" 2>/dev/null | grep "control-plane" | head -1)
WORKER_NODE=$(kind get nodes --name "$CLUSTER_NAME" 2>/dev/null | grep "worker" | head -1)

[[ -n "$CONTROL_PLANE_NODE" ]] || die "未找到控制平面节点，集群是否已创建？"

info "注入调试二进制到集群: $CLUSTER_NAME"
info "控制平面节点: $CONTROL_PLANE_NODE"

# ── 注入 k8s 控制平面组件 ────────────────────────────────────────────────────

inject_k8s_binary() {
    local bin_name="$1"
    local remote_path="${2:-/usr/local/bin/${bin_name}}"
    local node="${3:-$CONTROL_PLANE_NODE}"
    local local_bin="$K8S_BUILD/$bin_name"

    [[ -f "$local_bin" ]] || { warn "  跳过 $bin_name（本地构建产物不存在）"; return; }

    info "  注入 $bin_name → $node:$remote_path"

    # 备份原始二进制
    docker exec "$node" bash -c "
        if [[ -f '${remote_path}' ]] && [[ ! -f '${remote_path}.orig' ]]; then
            cp '${remote_path}' '${remote_path}.orig'
            echo '    ✓ 备份: ${remote_path}.orig'
        fi
    " 2>/dev/null || true

    # 复制调试版二进制
    docker cp "$local_bin" "${node}:${remote_path}"
    docker exec "$node" chmod +x "$remote_path"

    # 验证
    local remote_size
    remote_size=$(docker exec "$node" stat -c %s "$remote_path" 2>/dev/null || echo "?")
    ok "  $bin_name 注入完成（${remote_size} bytes）"
}

# 控制平面静态 Pod 中的组件路径
K8S_BIN_PATH="/usr/local/bin"

info "注入 kube-apiserver"
inject_k8s_binary "kube-apiserver" "$K8S_BIN_PATH/kube-apiserver"

info "注入 kube-controller-manager"
inject_k8s_binary "kube-controller-manager" "$K8S_BIN_PATH/kube-controller-manager"

info "注入 kube-scheduler"
inject_k8s_binary "kube-scheduler" "$K8S_BIN_PATH/kube-scheduler"

info "注入 kubelet（控制平面）"
inject_k8s_binary "kubelet" "$K8S_BIN_PATH/kubelet"

info "注入 kube-proxy（控制平面）"
inject_k8s_binary "kube-proxy" "$K8S_BIN_PATH/kube-proxy"

info "注入 kubectl"
inject_k8s_binary "kubectl" "$K8S_BIN_PATH/kubectl"

# Worker 节点注入
if [[ -n "$WORKER_NODE" ]]; then
    info "注入 kubelet（worker 节点）"
    inject_k8s_binary "kubelet" "$K8S_BIN_PATH/kubelet" "$WORKER_NODE"
    inject_k8s_binary "kube-proxy" "$K8S_BIN_PATH/kube-proxy" "$WORKER_NODE"
fi

# ── 注入 containerd（如果已编译）─────────────────────────────────────────────
if [[ -d "$RUNTIME_BUILD/containerd-bin" ]]; then
    info "注入 containerd 运行时"
    for bin in containerd containerd-shim-runc-v2 ctr; do
        local_bin="$RUNTIME_BUILD/containerd-bin/$bin"
        [[ -f "$local_bin" ]] || continue
        remote_path="/usr/local/bin/$bin"

        # 控制平面
        docker exec "$CONTROL_PLANE_NODE" bash -c "
            [[ -f '${remote_path}' ]] && [[ ! -f '${remote_path}.orig' ]] && cp '${remote_path}' '${remote_path}.orig'
        " 2>/dev/null || true
        docker cp "$local_bin" "${CONTROL_PLANE_NODE}:${remote_path}"
        docker exec "$CONTROL_PLANE_NODE" chmod +x "$remote_path"
        ok "  $bin 注入完成（控制平面）"

        # Worker
        if [[ -n "$WORKER_NODE" ]]; then
            docker cp "$local_bin" "${WORKER_NODE}:${remote_path}"
            docker exec "$WORKER_NODE" chmod +x "$remote_path"
            ok "  $bin 注入完成（worker）"
        fi
    done
fi

# ── 注入 runc（如果已编译）───────────────────────────────────────────────────
RUNC_BIN="$RUNTIME_BUILD/runc"
if [[ -f "$RUNC_BIN" ]]; then
    info "注入 runc"
    for node in "$CONTROL_PLANE_NODE" ${WORKER_NODE:-}; do
        [[ -n "$node" ]] || continue
        docker exec "$node" bash -c "
            [[ -f /usr/local/sbin/runc ]] && [[ ! -f /usr/local/sbin/runc.orig ]] && cp /usr/local/sbin/runc /usr/local/sbin/runc.orig
        " 2>/dev/null || true
        docker cp "$RUNC_BIN" "${node}:/usr/local/sbin/runc"
        docker exec "$node" chmod +x "/usr/local/sbin/runc"
        ok "  runc 注入完成（$node）"
    done
fi

# ── 注入 CNI 插件（如果已编译）────────────────────────────────────────────────
CNI_OUT="$RUNTIME_BUILD/cni-plugins"
if [[ -d "$CNI_OUT" ]] && ls "$CNI_OUT"/* &>/dev/null; then
    info "注入 CNI 插件"
    for node in "$CONTROL_PLANE_NODE" ${WORKER_NODE:-}; do
        [[ -n "$node" ]] || continue
        docker exec "$node" mkdir -p "/opt/cni/bin"
        docker exec "$node" bash -c "
            [[ ! -d /opt/cni/bin.orig ]] && cp -r /opt/cni/bin /opt/cni/bin.orig 2>/dev/null || true
        "
        for plugin in "$CNI_OUT"/*; do
            docker cp "$plugin" "${node}:/opt/cni/bin/"
        done
        docker exec "$node" chmod +x /opt/cni/bin/*
        ok "  CNI 插件注入完成（$node）"
    done
fi

# ── 重启控制平面组件 ──────────────────────────────────────────────────────────
info "重启控制平面静态 Pod（通过 kubelet 检测文件变化）"
docker exec "$CONTROL_PLANE_NODE" bash -c '
    # kubelet 监控 /etc/kubernetes/manifests/ 下的静态 Pod 文件
    # touch 文件触发重新创建
    for manifest in /etc/kubernetes/manifests/*.yaml; do
        touch "$manifest" 2>/dev/null || true
    done
    echo "  静态 Pod manifests 已 touch，等待 kubelet 重建..."
'

# 等待控制平面重新就绪
info "等待控制平面重新就绪（最多 90s）..."
sleep 5
kubectl wait --for=condition=Ready pod \
    -n kube-system \
    -l tier=control-plane \
    --timeout=90s \
    --context="kind-${CLUSTER_NAME}" 2>/dev/null || \
    warn "控制平面 Pod 就绪等待超时，请手动检查: kubectl get pods -n kube-system"

echo ""
ok "调试二进制注入完成"
echo ""
echo "已注入组件:"
echo "  kube-apiserver, kube-controller-manager, kube-scheduler"
echo "  kubelet, kube-proxy"
[[ -d "$RUNTIME_BUILD/containerd-bin" ]] && echo "  containerd, containerd-shim-runc-v2"
[[ -f "$RUNTIME_BUILD/runc" ]] && echo "  runc"
[[ -d "$CNI_OUT" ]] && echo "  CNI plugins: $(ls "$CNI_OUT" 2>/dev/null | tr '\n' ' ')"
echo ""
echo "下一步: make debug-all"
