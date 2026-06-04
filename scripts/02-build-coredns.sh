#!/usr/bin/env bash
# 编译 CoreDNS（保留 DWARF 调试符号，禁用内联和优化）
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COREDNS_SRC="${COREDNS_SRC:-/root/k8s-src/coredns}"
RUNTIME_BUILD="${2:-$_SCRIPT_DIR/../build/runtime}"
RUNTIME_BUILD="$(mkdir -p "$RUNTIME_BUILD" && cd "$RUNTIME_BUILD" && pwd)"

info() { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()   { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
die()  { echo -e "\033[1;31m[ERR ]\033[0m  $*"; exit 1; }

[[ -d "$COREDNS_SRC" ]] || die "CoreDNS 源码不存在: $COREDNS_SRC（先运行 bash scripts/01-clone-coredns.sh）"

info "编译 CoreDNS (带调试符号) → $RUNTIME_BUILD/coredns"
cd "$COREDNS_SRC"

VER=$(git describe --tags 2>/dev/null || echo "unknown")

CGO_ENABLED=0 go build \
    -gcflags=all="-N -l" \
    -ldflags="-X github.com/coredns/coredns/coremain.GitVersion=${VER}" \
    -o "$RUNTIME_BUILD/coredns" \
    . 2>&1 | tail -3

[[ -f "$RUNTIME_BUILD/coredns" ]] || die "编译失败"

has_dwarf=$(readelf -S "$RUNTIME_BUILD/coredns" 2>/dev/null | grep -c "\.debug_info" || true)
[[ "$has_dwarf" -gt 0 ]] || warn "警告: 未发现 DWARF 符号（调试断点将无法解析函数名）"

ok "CoreDNS 调试二进制: $RUNTIME_BUILD/coredns"
ok "DWARF 段数量: $has_dwarf"
file "$RUNTIME_BUILD/coredns"
