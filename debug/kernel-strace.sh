#!/usr/bin/env bash
# Linux 内核路径追踪（基于 strace/ptrace）
#
# 本环境内核限制：
#   CONFIG_KPROBES=n  → 无法使用 kprobe/kretprobe 挂钩内核函数
#   CONFIG_FTRACE=n   → 无 function_graph tracer，无 /sys/kernel/debug/tracing
#   CONFIG_KGDB=n     → 无法串口/网络 KGDB 调试
#
# 可用的内核观测手段：
#   strace（本脚本）  → ptrace 级系统调用追踪，可见内核入口参数和返回值
#   perf stat         → 硬件 PMU 事件计数（CPU 指令、缓存命中、分支预测）
#   /proc/<pid>/...   → 进程视角的内核状态（syscall、maps、status、fdinfo）
#
# 如需完整内核函数 trace 能力，需重编内核加：
#   CONFIG_KPROBES=y CONFIG_FTRACE=y CONFIG_BPF_EVENTS=y
set -euo pipefail

TARGET="${1:-}"           # 目标进程名或 PID（留空则自动选）
DURATION="${2:-5}"         # 追踪时长（秒）
SYSCALL_FILTER="${3:-openat,read,write,connect,accept4,socket,epoll_wait,sendto,recvfrom,futex}"
OUTPUT="/tmp/kernel-strace-$(date +%s).log"

info() { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()   { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
die()  { echo -e "\033[1;31m[ERR ]\033[0m  $*"; exit 1; }

which strace &>/dev/null || die "strace 未安装（apt-get install strace）"

# 自动选目标：优先使用指定进程，但跳过已被 dlv 占用的进程（ptrace 冲突）
find_traceable_pid() {
    local candidates=("$@")
    for pid in "${candidates[@]}"; do
        local tracer
        tracer=$(awk '/TracerPid/{print $2}' /proc/"$pid"/status 2>/dev/null || echo 0)
        if [[ "$tracer" -eq 0 ]]; then
            echo "$pid"
            return 0
        fi
    done
    return 1
}

if [[ -n "$TARGET" ]]; then
    if [[ "$TARGET" =~ ^[0-9]+$ ]]; then
        TARGET_PID="$TARGET"
    else
        TARGET_PID=$(pgrep -x "$TARGET" | head -1 || true)
        [[ -n "$TARGET_PID" ]] || die "进程 $TARGET 未找到"
    fi
    tracer=$(awk '/TracerPid/{print $2}' /proc/"$TARGET_PID"/status 2>/dev/null || echo 0)
    if [[ "$tracer" -ne 0 ]]; then
        warn "进程 $TARGET_PID 已被 PID $tracer（dlv）ptrace，自动切换到集群 coredns"
        TARGET_PID=""
    fi
fi

# 自动备选：集群 coredns pod（/coredns 二进制，非调试实例）
if [[ -z "${TARGET_PID:-}" ]]; then
    mapfile -t COREDNS_PIDS < <(pgrep -f "^/coredns" 2>/dev/null || true)
    TARGET_PID=$(find_traceable_pid "${COREDNS_PIDS[@]}" 2>/dev/null || true)
    [[ -n "$TARGET_PID" ]] || die "未找到可 strace 的目标进程（所有候选都在 dlv 下）"
    TARGET="coredns-pod"
fi

echo ""
echo "══ 内核调试环境 ══════════════════════════════════════"
printf "  CONFIG_KPROBES:   %s\n" "$(grep 'CONFIG_KPROBES=' /boot/config-$(uname -r) 2>/dev/null | head -1 || echo 'n/a')"
printf "  CONFIG_FTRACE:    %s\n" "$(grep '^CONFIG_FTRACE=' /boot/config-$(uname -r) 2>/dev/null | head -1 || echo 'n/a')"
printf "  CONFIG_KGDB:      %s\n" "$(grep 'CONFIG_KGDB=' /boot/config-$(uname -r) 2>/dev/null | head -1 || echo 'n/a')"
printf "  CONFIG_BPF_SYSCALL: %s\n" "$(grep 'CONFIG_BPF_SYSCALL=' /boot/config-$(uname -r) 2>/dev/null | head -1 || echo 'n/a')"
printf "  tracefs:          %s\n" "$(ls /sys/kernel/debug/tracing 2>/dev/null | head -1 || echo 'not mounted (FTRACE disabled)')"
echo "══════════════════════════════════════════════════════"
echo ""

info "目标进程: ${TARGET:-auto} (PID $TARGET_PID)"
info "追踪时长: ${DURATION}s"
info "追踪的 syscall: $SYSCALL_FILTER"
info "输出: $OUTPUT"
echo ""

# 打印实时进程内核状态
echo "── 当前 /proc/$TARGET_PID/syscall ──"
cat /proc/"$TARGET_PID"/syscall 2>/dev/null || echo "(not available)"
echo ""

info "开始 strace 追踪..."
timeout "$DURATION" strace \
    -p "$TARGET_PID" \
    -e trace="$SYSCALL_FILTER" \
    -o "$OUTPUT" \
    -f \
    -ttt \
    2>/dev/null || true

ok "追踪完成（${DURATION}s）"
echo ""

# 系统调用频次统计
echo "── syscall 频次 TOP 20 ──────────────────────────────"
grep -oP '^[^(]+(?=\()' "$OUTPUT" 2>/dev/null | sort | uniq -c | sort -rn | head -20 || true
echo ""

# 最近事件
echo "── 最近 20 条 strace 记录 ──────────────────────────"
tail -20 "$OUTPUT" 2>/dev/null || true
echo ""

ok "完整日志: $OUTPUT"
echo ""
echo "── 内核路径观测说明 ─────────────────────────────────"
echo "  strace 捕获的每一行 = 用户态→内核态的 syscall 边界"
echo "  这是在没有 kprobes/ftrace 时追踪内核交互的主要手段"
echo ""
echo "  其他可用命令（无需 kprobes）："
echo "    perf stat -p $TARGET_PID sleep 3    # 硬件计数器"
echo "    cat /proc/$TARGET_PID/status         # 进程内核状态"
echo "    cat /proc/$TARGET_PID/wchan          # 当前在哪个内核等待点"
echo "    cat /proc/$TARGET_PID/syscall        # 实时 syscall NR+参数"
echo "    ls -la /proc/$TARGET_PID/fd/         # 打开的文件描述符"
