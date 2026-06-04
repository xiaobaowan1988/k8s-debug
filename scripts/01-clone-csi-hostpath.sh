#!/usr/bin/env bash
set -euo pipefail

CSI_SRC="${1:-$HOME/k8s-src/csi-driver-host-path}"
CSI_VERSION="${2:-v1.16.1}"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }

if [[ -d "$CSI_SRC/.git" ]]; then
    ok "csi-driver-host-path 源码已存在，跳过"
    exit 0
fi

mkdir -p "$(dirname "$CSI_SRC")"
info "克隆 csi-driver-host-path $CSI_VERSION"
git clone --depth=1 --branch "$CSI_VERSION" \
    https://github.com/kubernetes-csi/csi-driver-host-path.git "$CSI_SRC"
ok "csi-driver-host-path 克隆完成: $CSI_SRC"
