#!/usr/bin/env bash
# 从源码编译 etcd（携带调试符号）
set -euo pipefail

ETCD_SRC="${1:-$HOME/k8s-src/etcd}"
_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNTIME_BUILD="${2:-$_SCRIPT_DIR/../build/runtime}"
RUNTIME_BUILD="$(mkdir -p "$RUNTIME_BUILD" && cd "$RUNTIME_BUILD" && pwd)"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[ERR ]\033[0m  $*"; exit 1; }

[[ -d "$ETCD_SRC" ]] || die "etcd 源码目录不存在: $ETCD_SRC（先运行 scripts/01-clone-etcd.sh）"

info "编译 etcd（携带调试符号）"
export GOTOOLCHAIN=local

# etcd v3.5.x main package is in ./server subdirectory
cd "$ETCD_SRC/server"

CGO_ENABLED=0 go build \
    -gcflags=all="-N -l" \
    -o "$RUNTIME_BUILD/etcd" \
    . 2>&1 | tail -3

[[ -f "$RUNTIME_BUILD/etcd" ]] || die "etcd 编译失败"

local_size=$(stat -c %s "$RUNTIME_BUILD/etcd" 2>/dev/null || echo "?")
ok "etcd → $RUNTIME_BUILD/etcd  (${local_size} bytes)"
file "$RUNTIME_BUILD/etcd"
