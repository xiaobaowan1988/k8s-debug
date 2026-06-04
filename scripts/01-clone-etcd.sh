#!/usr/bin/env bash
set -euo pipefail

ETCD_SRC="${1:-$HOME/k8s-src/etcd}"
ETCD_VERSION="${2:-v3.5.16}"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }

if [[ -d "$ETCD_SRC/.git" ]]; then
    ok "etcd 源码已存在，跳过"
    exit 0
fi

mkdir -p "$(dirname "$ETCD_SRC")"
info "克隆 etcd $ETCD_VERSION"
git clone --depth=1 --branch "$ETCD_VERSION" \
    https://github.com/etcd-io/etcd.git "$ETCD_SRC"
ok "etcd 克隆完成: $ETCD_SRC"
