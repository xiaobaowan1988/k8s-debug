#!/usr/bin/env bash
# 从源码编译 runc
# 两种模式：
#   normal  - 标准 debug 编译
#   patched - 注入 sleep 桩点，供 dlv attach 调试极短生命周期进程
set -euo pipefail

RUNC_SRC="${1:-$HOME/k8s-src/runc}"
_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNTIME_BUILD="${2:-$_SCRIPT_DIR/../build/runtime}"
RUNTIME_BUILD="$(mkdir -p "$RUNTIME_BUILD" && cd "$RUNTIME_BUILD" && pwd)"
MODE="${3:-normal}"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[ERR ]\033[0m  $*"; exit 1; }

[[ -d "$RUNC_SRC" ]] || die "runc 源码目录不存在: $RUNC_SRC"

mkdir -p "$RUNTIME_BUILD"
cd "$RUNC_SRC"

build_runc() {
    local outfile="$1"
    # Use direct go build to avoid Make's word-splitting of gcflags
    CGO_ENABLED=1 go build \
        -gcflags=all="-N -l" \
        -buildmode=pie \
        -tags "seccomp" \
        -o "$outfile" . 2>&1 | tail -3
    [[ -f "$outfile" ]] || die "runc 编译失败: $outfile"
}

if [[ "$MODE" == "patched" ]]; then
    info "应用 sleep 调试桩点补丁"
    PATCH_FILE="$(dirname "$0")/../patches/runc-debug-sleep.patch"
    git checkout -- . 2>/dev/null || true
    [[ -f "$PATCH_FILE" ]] && git apply "$PATCH_FILE" && ok "补丁应用成功"

    build_runc "runc"
    cp runc "$RUNTIME_BUILD/runc.patched"
    git checkout -- . 2>/dev/null || true
    ok "patched runc → $RUNTIME_BUILD/runc.patched"
    echo "  使用: RUNC_DEBUG_SLEEP=30 runc ..."
else
    build_runc "runc"
    cp runc "$RUNTIME_BUILD/runc"
    ok "runc → $RUNTIME_BUILD/runc"
fi

file "$RUNTIME_BUILD/runc"* 2>/dev/null | grep -v Binary || true
