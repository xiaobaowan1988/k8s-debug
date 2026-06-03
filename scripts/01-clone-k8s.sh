#!/usr/bin/env bash
# 克隆 Kubernetes 源码（优先使用国内镜像）
set -euo pipefail

K8S_SRC="${1:-$HOME/k8s-src/kubernetes}"
K8S_VERSION="${2:-v1.32.0}"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }

# GitHub 镜像列表（Docker Hub 被封但 GitHub 一般可访问，提供备选）
GH_MIRRORS=(
    "https://github.com"
    "https://ghproxy.com/https://github.com"
    "https://mirror.ghproxy.com/https://github.com"
)

clone_with_mirror() {
    local repo="$1"
    local dest="$2"
    local tag="$3"

    for mirror in "${GH_MIRRORS[@]}"; do
        url="${mirror}/${repo}.git"
        info "尝试克隆 $url"
        if git clone --depth=1 --branch "$tag" "$url" "$dest" 2>/dev/null; then
            return 0
        fi
        warn "$mirror 不可用，尝试下一个"
    done
    echo "所有镜像均失败，无法克隆 $repo"
    return 1
}

if [[ -d "$K8S_SRC/.git" ]]; then
    info "kubernetes 源码已存在于 $K8S_SRC，检查版本..."
    cd "$K8S_SRC"
    CURRENT_TAG=$(git describe --tags --exact-match 2>/dev/null || git rev-parse --short HEAD)
    if [[ "$CURRENT_TAG" == "$K8S_VERSION" ]]; then
        ok "已是目标版本 $K8S_VERSION，跳过克隆"
        exit 0
    fi
    warn "当前版本 $CURRENT_TAG 与目标 $K8S_VERSION 不符，重新克隆"
    rm -rf "$K8S_SRC"
fi

mkdir -p "$(dirname "$K8S_SRC")"
clone_with_mirror "kubernetes/kubernetes" "$K8S_SRC" "$K8S_VERSION"

ok "kubernetes $K8S_VERSION 克隆完成: $K8S_SRC"
echo "  提交: $(git -C "$K8S_SRC" rev-parse --short HEAD)"
echo "  目录大小: $(du -sh "$K8S_SRC" 2>/dev/null | cut -f1)"
