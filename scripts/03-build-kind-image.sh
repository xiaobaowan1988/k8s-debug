#!/usr/bin/env bash
# 从 Kubernetes 源码构建 Kind 节点镜像（不依赖 Docker Hub）
# Kind 的 node-image 构建使用 registry.k8s.io/kindest/base 作为基础，不需要 Docker Hub
set -euo pipefail

K8S_SRC="${1:-$HOME/k8s-src/kubernetes}"
KIND_NODE_IMG="${2:-kindest/node:local-debug}"
BASE_IMAGE="${3:-registry.k8s.io/kindest/base:v20241210}"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[ERR ]\033[0m  $*"; exit 1; }

command -v kind   || die "Kind 未安装，请先运行 make setup"
command -v docker || die "Docker 未安装"

# 检查是否已有本地镜像
if docker image inspect "$KIND_NODE_IMG" &>/dev/null; then
    ok "本地已有镜像 $KIND_NODE_IMG，跳过构建"
    exit 0
fi

[[ -d "$K8S_SRC" ]] || die "kubernetes 源码不存在: $K8S_SRC"

info "从 k8s 源码构建 Kind 节点镜像"
info "  源码: $K8S_SRC"
info "  目标镜像: $KIND_NODE_IMG"
info "  基础镜像: $BASE_IMAGE（来自 registry.k8s.io，无需 Docker Hub）"

# Kind base 镜像来自 registry.k8s.io，不需要 Docker Hub
# 如果 registry.k8s.io 也不可达，尝试国内镜像
pull_base_image() {
    local img="$1"
    if docker pull "$img" 2>/dev/null; then
        ok "拉取基础镜像成功: $img"
        return 0
    fi

    # 尝试通过阿里云镜像
    local ali_img="registry.aliyuncs.com/google_containers/kindest/base:v20241210"
    warn "$img 拉取失败，尝试阿里云镜像"
    if docker pull "$ali_img" 2>/dev/null; then
        docker tag "$ali_img" "$img"
        ok "基础镜像就绪（来自阿里云）"
        return 0
    fi

    warn "无法拉取基础镜像，Kind 将自动选择可用版本"
    return 1
}

pull_base_image "$BASE_IMAGE" || true

info "运行 kind build node-image（这需要 20-40 分钟）..."
kind build node-image \
    --image "$KIND_NODE_IMG" \
    --base-image "$BASE_IMAGE" \
    "$K8S_SRC" \
    2>&1

ok "Kind 节点镜像构建完成: $KIND_NODE_IMG"
docker image inspect "$KIND_NODE_IMG" --format '  大小: {{.Size}} bytes  ID: {{.Id}}'
