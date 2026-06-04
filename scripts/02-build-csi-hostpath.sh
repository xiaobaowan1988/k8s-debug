#!/usr/bin/env bash
# 从源码编译 csi-driver-host-path（携带调试符号）
set -euo pipefail

CSI_SRC="${1:-$HOME/k8s-src/csi-driver-host-path}"
_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNTIME_BUILD="${2:-$_SCRIPT_DIR/../build/runtime}"
RUNTIME_BUILD="$(mkdir -p "$RUNTIME_BUILD" && cd "$RUNTIME_BUILD" && pwd)"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[ERR ]\033[0m  $*"; exit 1; }

[[ -d "$CSI_SRC" ]] || die "csi-driver-host-path 源码不存在: $CSI_SRC（先运行 scripts/01-clone-csi-hostpath.sh）"

info "编译 csi-hostpathplugin（携带调试符号）"
cd "$CSI_SRC"

export GOTOOLCHAIN=local

CGO_ENABLED=0 go build \
    -gcflags=all="-N -l" \
    -o "$RUNTIME_BUILD/csi-hostpathplugin" \
    ./cmd/hostpathplugin/ 2>&1 | tail -3

[[ -f "$RUNTIME_BUILD/csi-hostpathplugin" ]] || die "csi-hostpathplugin 编译失败"

sz=$(stat -c %s "$RUNTIME_BUILD/csi-hostpathplugin" 2>/dev/null || echo "?")
ok "csi-hostpathplugin → $RUNTIME_BUILD/csi-hostpathplugin  (${sz} bytes)"
file "$RUNTIME_BUILD/csi-hostpathplugin"
