#!/usr/bin/env bash
set -euo pipefail

RUNC_SRC="${1:-$HOME/k8s-src/runc}"
RUNC_VERSION="${2:-v1.2.3}"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }

if [[ -d "$RUNC_SRC/.git" ]]; then
    ok "runc 源码已存在，跳过"
    exit 0
fi

mkdir -p "$(dirname "$RUNC_SRC")"
info "克隆 runc $RUNC_VERSION"
git clone --depth=1 --branch "$RUNC_VERSION" \
    https://github.com/opencontainers/runc.git "$RUNC_SRC"
ok "runc 克隆完成: $RUNC_SRC"
