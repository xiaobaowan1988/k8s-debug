#!/usr/bin/env bash
set -euo pipefail

CNI_SRC="${1:-$HOME/k8s-src/cni-plugins}"
CNI_VERSION="${2:-v1.6.0}"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }

if [[ -d "$CNI_SRC/.git" ]]; then
    ok "cni-plugins 源码已存在，跳过"
    exit 0
fi

mkdir -p "$(dirname "$CNI_SRC")"
info "克隆 cni-plugins $CNI_VERSION"
git clone --depth=1 --branch "$CNI_VERSION" \
    https://github.com/containernetworking/plugins.git "$CNI_SRC"
ok "cni-plugins 克隆完成: $CNI_SRC"
