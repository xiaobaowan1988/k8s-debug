#!/usr/bin/env bash
# 克隆 CoreDNS 源码（与集群运行版本一致）
set -euo pipefail

COREDNS_VER="${COREDNS_VER:-v1.11.3}"
SRC_ROOT="${SRC_ROOT:-/root/k8s-src}"
COREDNS_SRC="$SRC_ROOT/coredns"

info() { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()   { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
die()  { echo -e "\033[1;31m[ERR ]\033[0m  $*"; exit 1; }

mkdir -p "$SRC_ROOT"

if [[ -d "$COREDNS_SRC/.git" ]]; then
    info "CoreDNS 源码已存在: $COREDNS_SRC"
    git -C "$COREDNS_SRC" describe --tags 2>/dev/null || true
    exit 0
fi

info "克隆 CoreDNS ${COREDNS_VER} ..."
git clone --depth=1 --branch "$COREDNS_VER" \
    https://github.com/coredns/coredns.git \
    "$COREDNS_SRC"

ok "CoreDNS 源码已克隆: $COREDNS_SRC"
ok "版本: $(git -C "$COREDNS_SRC" describe --tags 2>/dev/null || echo "$COREDNS_VER")"
