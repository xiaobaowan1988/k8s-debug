#!/usr/bin/env bash
set -euo pipefail

CONTAINERD_SRC="${1:-$HOME/k8s-src/containerd}"
CONTAINERD_VERSION="${2:-v2.0.1}"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }

GH_MIRRORS=(
    "https://github.com"
    "https://ghproxy.com/https://github.com"
    "https://mirror.ghproxy.com/https://github.com"
)

clone_with_mirror() {
    local repo="$1" dest="$2" tag="$3"
    for mirror in "${GH_MIRRORS[@]}"; do
        if git clone --depth=1 --branch "$tag" "${mirror}/${repo}.git" "$dest" 2>/dev/null; then
            return 0
        fi
        warn "$mirror 不可用"
    done
    return 1
}

if [[ -d "$CONTAINERD_SRC/.git" ]]; then
    ok "containerd 源码已存在，跳过"
    exit 0
fi

mkdir -p "$(dirname "$CONTAINERD_SRC")"
info "克隆 containerd $CONTAINERD_VERSION"
clone_with_mirror "containerd/containerd" "$CONTAINERD_SRC" "$CONTAINERD_VERSION"
ok "containerd 克隆完成: $CONTAINERD_SRC"
