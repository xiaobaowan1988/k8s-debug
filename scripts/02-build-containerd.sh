#!/usr/bin/env bash
# 从源码编译 containerd（携带调试符号）
set -euo pipefail

CONTAINERD_SRC="${1:-$HOME/k8s-src/containerd}"
RUNTIME_BUILD="$(cd "$(dirname "$0")/../build/runtime" 2>/dev/null && pwd || { mkdir -p "$(dirname "$0")/../build/runtime" && cd "$(dirname "$0")/../build/runtime" && pwd; })"
[[ -n "${2:-}" ]] && RUNTIME_BUILD="$(mkdir -p "$2" && cd "$2" && pwd)"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[ERR ]\033[0m  $*"; exit 1; }

[[ -d "$CONTAINERD_SRC" ]] || die "containerd 源码目录不存在: $CONTAINERD_SRC"

mkdir -p "$RUNTIME_BUILD/containerd-bin"
OUTDIR="$RUNTIME_BUILD/containerd-bin"

info "编译 containerd（携带调试符号）"
cd "$CONTAINERD_SRC"

PKG="github.com/containerd/containerd/v2"
VER=$(git describe --tags --always 2>/dev/null || echo "dev")

for bin in containerd ctr; do
    info "  编译 $bin"
    CGO_ENABLED=1 go build \
        -gcflags=all="-N -l" \
        -ldflags="-X ${PKG}/version.Version=${VER}" \
        -o "$OUTDIR/$bin" \
        "./cmd/$bin" 2>&1 | tail -2
    [[ -f "$OUTDIR/$bin" ]] || die "$bin 编译失败"
    ok "  $bin → $OUTDIR/$bin"
done

# shim uses CGO_ENABLED=0
info "  编译 containerd-shim-runc-v2"
CGO_ENABLED=0 go build \
    -gcflags=all="-N -l" \
    -ldflags="-X ${PKG}/version.Version=${VER}" \
    -o "$OUTDIR/containerd-shim-runc-v2" \
    ./cmd/containerd-shim-runc-v2 2>&1 | tail -2
[[ -f "$OUTDIR/containerd-shim-runc-v2" ]] || die "shim 编译失败"
ok "  containerd-shim-runc-v2 → $OUTDIR/containerd-shim-runc-v2"

ok "containerd 编译完成"
ls -lh "$OUTDIR/"
