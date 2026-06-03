#!/usr/bin/env bash
set -euo pipefail

RUNC_SRC="${1:-$HOME/k8s-src/runc}"
RUNC_VERSION="${2:-v1.2.3}"

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

if [[ -d "$RUNC_SRC/.git" ]]; then
    ok "runc 源码已存在，跳过"
    exit 0
fi

mkdir -p "$(dirname "$RUNC_SRC")"
info "克隆 runc $RUNC_VERSION"
clone_with_mirror "opencontainers/runc" "$RUNC_SRC" "$RUNC_VERSION"
ok "runc 克隆完成: $RUNC_SRC"
