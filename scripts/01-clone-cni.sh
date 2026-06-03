#!/usr/bin/env bash
set -euo pipefail

CNI_SRC="${1:-$HOME/k8s-src/cni-plugins}"
CNI_VERSION="${2:-v1.6.0}"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }

GH_MIRRORS=(
    "https://github.com"
    "https://ghproxy.com/https://github.com"
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

if [[ -d "$CNI_SRC/.git" ]]; then
    ok "cni-plugins 源码已存在，跳过"
    exit 0
fi

mkdir -p "$(dirname "$CNI_SRC")"
info "克隆 cni-plugins $CNI_VERSION"
clone_with_mirror "containernetworking/plugins" "$CNI_SRC" "$CNI_VERSION"
ok "cni-plugins 克隆完成: $CNI_SRC"
