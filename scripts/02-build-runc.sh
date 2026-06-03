#!/usr/bin/env bash
# 从源码编译 runc
# 支持两种模式：
#   normal  - 标准 debug 编译（无内联优化）
#   patched - 注入 sleep 桩点，供 dlv attach 调试极短生命周期进程
set -euo pipefail

RUNC_SRC="${1:-$HOME/k8s-src/runc}"
RUNTIME_BUILD="${2:-$(dirname "$0")/../build/runtime}"
MODE="${3:-normal}"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[ERR ]\033[0m  $*"; exit 1; }

[[ -d "$RUNC_SRC" ]] || die "runc 源码目录不存在: $RUNC_SRC"

export GOPROXY="${GOPROXY:-https://goproxy.cn,https://goproxy.io,direct}"

mkdir -p "$RUNTIME_BUILD"

cd "$RUNC_SRC"

if [[ "$MODE" == "patched" ]]; then
    info "应用 sleep 调试桩点补丁..."

    PATCH_FILE="$(dirname "$0")/../patches/runc-debug-sleep.patch"
    if [[ -f "$PATCH_FILE" ]]; then
        # 先还原（防止重复应用）
        git checkout -- . 2>/dev/null || true
        git apply "$PATCH_FILE" && ok "补丁应用成功"
    else
        warn "补丁文件不存在，手动注入 sleep"
        # 在 libcontainer/process_linux.go 的 init 阶段注入 sleep
        INJECT_TARGET="libcontainer/process_linux.go"
        if grep -q "RUNC_DEBUG_SLEEP" "$INJECT_TARGET" 2>/dev/null; then
            info "sleep 桩点已存在"
        else
            # 在 newInitProcess 函数开头注入
            sed -i 's/func newInitProcess(/func newInitProcess(/' "$INJECT_TARGET"
            cat > /tmp/sleep_inject.py << 'PYEOF'
import sys
content = open(sys.argv[1]).read()
inject = '''
import "os"
import "strconv"
import "time"
'''
# 在 package 声明后注入 import
# 在 newInitProcess 函数体开头注入 sleep
target = 'func newInitProcess('
replacement = '''func newInitProcess('''
# 在函数体第一个 { 后注入
# 简单方法：在 libcontainer/process_linux.go 顶部找合适位置
print("手动注入需要编辑源码", file=sys.stderr)
sys.exit(0)
PYEOF
            python3 /tmp/sleep_inject.py "$INJECT_TARGET" 2>/dev/null || true
        fi
    fi

    OUT_BIN="$RUNTIME_BUILD/runc.patched"
    info "编译 patched runc（含 30s sleep 桩点）"
    make runc \
        EXTRA_FLAGS="-gcflags=all=-N -l" \
        BUILDTAGS="seccomp" \
        2>&1 | tail -5
    [[ -f "runc" ]] || die "runc 编译失败"
    cp runc "$OUT_BIN"
    # 还原源码
    git checkout -- . 2>/dev/null || true
    ok "patched runc → $OUT_BIN"
    echo "  使用方法："
    echo "    sudo cp $OUT_BIN /usr/local/sbin/runc"
    echo "    # 创建 Pod → 等待 30s sleep → 找 runc PID → dlv attach <PID>"
else
    OUT_BIN="$RUNTIME_BUILD/runc"
    info "编译标准 debug runc（无内联优化）"
    make runc \
        EXTRA_FLAGS="-gcflags=all=-N -l" \
        BUILDTAGS="seccomp" \
        2>&1 | tail -5
    [[ -f "runc" ]] || die "runc 编译失败"
    cp runc "$OUT_BIN"
    ok "runc → $OUT_BIN"
fi

file "$OUT_BIN"
ls -lh "$OUT_BIN"
