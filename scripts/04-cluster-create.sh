#!/usr/bin/env bash
# 创建 Kind 调试集群
set -euo pipefail

CLUSTER_NAME="${1:-k8s-debug}"
KIND_NODE_IMG="${2:-kindest/node:local-debug}"
KIND_CONFIG="${3:-$(dirname "$0")/../config/kind-cluster.yaml}"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[ERR ]\033[0m  $*"; exit 1; }

command -v kind   || die "Kind 未安装"
command -v docker || die "Docker 未运行"

# 如果本地 debug 镜像不存在，直接拉取官方镜像
if ! docker image inspect "$KIND_NODE_IMG" &>/dev/null; then
    FALLBACK_IMG="kindest/node:v1.32.0"
    warn "本地镜像 $KIND_NODE_IMG 不存在，拉取 $FALLBACK_IMG"
    docker pull "$FALLBACK_IMG"
    docker tag "$FALLBACK_IMG" "$KIND_NODE_IMG"
fi

# 检查集群是否已存在
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    warn "集群 $CLUSTER_NAME 已存在"
    read -rp "是否重建？[y/N] " yn
    if [[ "$yn" =~ ^[Yy]$ ]]; then
        kind delete cluster --name "$CLUSTER_NAME"
    else
        kubectl cluster-info --context "kind-${CLUSTER_NAME}" 2>/dev/null || true
        exit 0
    fi
fi

mkdir -p /tmp/k8s-debug-bins /tmp/k8s-debug-src

ACTUAL_CONFIG="/tmp/kind-config-${CLUSTER_NAME}.yaml"
sed "s|kindest/node:local-debug|${KIND_NODE_IMG}|g" "$KIND_CONFIG" > "$ACTUAL_CONFIG"

info "创建 Kind 集群: $CLUSTER_NAME (image: $KIND_NODE_IMG)"
kind create cluster \
    --name "$CLUSTER_NAME" \
    --config "$ACTUAL_CONFIG" \
    --wait 120s

ok "集群创建完成"
kubectl cluster-info --context "kind-${CLUSTER_NAME}"
echo ""
kubectl get nodes -o wide --context "kind-${CLUSTER_NAME}"
