#!/usr/bin/env bash
# 从源码编译 containerd（携带调试符号）
set -euo pipefail

CONTAINERD_SRC="${1:-$HOME/k8s-src/containerd}"
RUNTIME_BUILD="${2:-$(dirname "$0")/../build/runtime}"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[ERR ]\033[0m  $*"; exit 1; }

[[ -d "$CONTAINERD_SRC" ]] || die "containerd 源码目录不存在: $CONTAINERD_SRC"

export GOPROXY="${GOPROXY:-https://goproxy.cn,https://goproxy.io,direct}"
export GONOSUMCHECK="*"

mkdir -p "$RUNTIME_BUILD/containerd-bin"

info "编译 containerd（携带调试符号）"
cd "$CONTAINERD_SRC"

# DEBUG=1 触发 containerd Makefile 的 -gcflags=all="-N -l"
make binaries \
    EXTRA_FLAGS="-gcflags=all=-N -l" \
    DEBUG=1 \
    DESTDIR="" \
    GOFLAGS="" \
    2>&1 | tail -10

# 复制产物
BINS=(containerd containerd-shim-runc-v2 ctr)
for bin in "${BINS[@]}"; do
    src="bin/${bin}"
    [[ -f "$src" ]] || { info "跳过 $bin（不存在）"; continue; }
    cp "$src" "$RUNTIME_BUILD/containerd-bin/"
    ok "  $bin → $RUNTIME_BUILD/containerd-bin/"
done

ok "containerd 编译完成"
ls -lh "$RUNTIME_BUILD/containerd-bin/"
