#!/usr/bin/env bash
set -euo pipefail

CONTAINERD_SRC="${1:-$HOME/k8s-src/containerd}"
CONTAINERD_VERSION="${2:-v2.0.1}"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }

if [[ -d "$CONTAINERD_SRC/.git" ]]; then
    ok "containerd 源码已存在，跳过"
    exit 0
fi

mkdir -p "$(dirname "$CONTAINERD_SRC")"
info "克隆 containerd $CONTAINERD_VERSION"
git clone --depth=1 --branch "$CONTAINERD_VERSION" \
    https://github.com/containerd/containerd.git "$CONTAINERD_SRC"
ok "containerd 克隆完成: $CONTAINERD_SRC"
