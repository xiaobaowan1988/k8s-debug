#!/usr/bin/env bash
# 容器相关 Linux 内核函数断点测试（QEMU GDB stub）
#
# 验证容器创建过程中涉及的内核函数（Linux 6.12 vmlinux + QEMU TCG）：
#   copy_process        — fork/clone 进程创建（容器 init 进程）
#   __x64_sys_clone     — clone() 系统调用（namespace 创建）
#   __x64_sys_unshare   — unshare() 系统调用（隔离 namespace）
#   do_mount            — mount() 系统调用（bind mount rootfs）
#   security_bprm_check — execve() LSM 安全检查（容器二进制执行）
#   cgroup_attach_task  — 进程迁移到 cgroup（容器资源隔离）
#
# 测试流程：
#   1. 构建 container-test initrd（包含 unshare/bind-mount/cgroup 操作）
#   2. 启动 QEMU（TCG 模式，-s -S 开启 GDB stub，pause at boot）
#   3. GDB attach :1234，设断点，运行到各断点触发，打印调用栈
#   4. 解析 GDB 输出，汇报哪些内核函数被触发
#
# 用法：
#   bash debug/kernel-container.sh            # 完整测试
#   bash debug/kernel-container.sh --symbols  # 仅验证 vmlinux 符号（不启动 QEMU）
#   bash debug/kernel-container.sh --gdb      # 启动 QEMU 后进入交互式 GDB
#
set -euo pipefail

info() { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()   { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
die()  { echo -e "\033[1;31m[ERR ]\033[0m  $*"; exit 1; }

MODE="${1:-}"

VMLINUX="${VMLINUX:-/tmp/linux-6.12/vmlinux}"
BZIMAGE="${BZIMAGE:-/tmp/linux-6.12/arch/x86/boot/bzImage}"
BASE_INITRD="${BASE_INITRD:-/tmp/initrd.gz}"
CONTAINER_INITRD="/tmp/initrd-container-test.gz"
GDB_PORT="${GDB_PORT:-1234}"
QEMU_PID_FILE="/tmp/qemu-container-test.pid"
GDB_LOG="/tmp/kernel-container-gdb.log"
TEST_TIMEOUT="${TEST_TIMEOUT:-60}"

# 容器相关内核函数（Linux 6.12 验证通过）
declare -A CONTAINER_BPS=(
    [copy_process]="fork/clone 进程创建（容器 init 进程）"
    [__x64_sys_clone]="clone() 系统调用（namespace 创建）"
    [__x64_sys_unshare]="unshare() 系统调用（namespace 隔离）"
    [do_mount]="mount() 系统调用（bind mount rootfs）"
    [security_bprm_check]="execve LSM 安全检查（容器进程启动）"
    [cgroup_attach_task]="进程迁移到 cgroup（容器资源隔离）"
)

[[ -f "$VMLINUX" ]] || die "vmlinux 未找到: $VMLINUX（先运行 scripts/mac/06-build-kernel.sh）"
command -v gdb >/dev/null || die "gdb 未安装（apt-get install gdb）"

# ── 1. 符号验证（无需 QEMU）──────────────────────────────────────────────────
verify_symbols() {
    info "验证 vmlinux 中的容器相关内核符号..."
    echo ""
    printf "  %-30s %-18s %s\n" "函数" "地址" "说明"
    printf "  %-30s %-18s %s\n" "------" "------" "------"

    local found=0 missing=0
    for sym in "${!CONTAINER_BPS[@]}"; do
        local addr
        addr=$(nm "$VMLINUX" 2>/dev/null | grep -E " [Tt] ${sym}$" | awk '{print $1}' | head -1 || true)
        if [[ -n "$addr" ]]; then
            printf "  \033[1;32m✓\033[0m  %-28s 0x%-16s %s\n" "$sym" "$addr" "${CONTAINER_BPS[$sym]}"
            found=$((found + 1))
        else
            printf "  \033[1;33m—\033[0m  %-28s %-18s %s\n" "$sym" "(not found)" "${CONTAINER_BPS[$sym]}"
            missing=$((missing + 1))
        fi
    done

    echo ""
    info "符号结果: ${found} 个已找到，${missing} 个未找到"
    echo ""
}

# ── 2. 构建 container-test initrd ────────────────────────────────────────────
build_container_initrd() {
    if [[ -f "$CONTAINER_INITRD" ]]; then
        info "Container-test initrd 已存在: $CONTAINER_INITRD"
        return
    fi

    [[ -f "$BASE_INITRD" ]] || die "base initrd 未找到: $BASE_INITRD"
    info "构建 container-test initrd..."

    local work_dir
    work_dir=$(mktemp -d /tmp/initrd-container-build-XXXX)
    trap "rm -rf '$work_dir'" EXIT

    # 解包 base initrd
    (cd "$work_dir" && zcat "$BASE_INITRD" | cpio -id --quiet 2>/dev/null)

    # 写入 container-test init 脚本
    # 该脚本依次触发：do_mount → copy_process → security_bprm_check →
    #                 __x64_sys_clone → __x64_sys_unshare → cgroup_attach_task
    cat > "$work_dir/init" << 'INIT_EOF'
#!/bin/sh
# Container-test init: 系统性触发容器相关内核函数

# ── phase 1: 基础 mount（触发 do_mount / path_mount）──────────────────────────
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true

printf "\n=== CTEST:PHASE1:MOUNTS ===\n"
# cgroup2 mount（触发 do_mount 用于 cgroup 子系统）
mkdir -p /sys/fs/cgroup
mount -t cgroup2 none /sys/fs/cgroup 2>/dev/null && \
    printf "CTEST:cgroup2_mounted\n" || printf "CTEST:cgroup2_skipped\n"

# ── phase 2: 进程创建（触发 copy_process + security_bprm_check）──────────────
printf "=== CTEST:PHASE2:PROCESS_CREATE ===\n"
ls /proc >/dev/null 2>&1          # 触发 ls 进程
cat /proc/version >/dev/null 2>&1 # 触发 cat 进程
printf "CTEST:process_create_done\n"

# ── phase 3: namespace 隔离（触发 __x64_sys_clone + __x64_sys_unshare）────────
printf "=== CTEST:PHASE3:NAMESPACES ===\n"
# unshare 内部调用 SYS_unshare（触发 __x64_sys_unshare）
# unshare --fork 内部 fork 子进程（触发 copy_process + __x64_sys_clone）
unshare --mount --pid --net --fork /bin/sh -c '
    printf "CTEST:in_namespace pid=%d\n" "$$"
    # bind mount（在新 mount namespace 内触发 do_mount with MS_BIND）
    mkdir -p /tmp/ns-rootfs
    mount --bind /bin /tmp/ns-rootfs 2>/dev/null && \
        printf "CTEST:bind_mount_done\n" || printf "CTEST:bind_mount_skipped\n"
    # 执行二进制（触发 security_bprm_check）
    ls /tmp/ns-rootfs >/dev/null 2>&1 || true
    printf "CTEST:namespace_exec_done\n"
' 2>/dev/null || printf "CTEST:unshare_not_available\n"

# ── phase 4: cgroup 进程迁移（触发 cgroup_attach_task）────────────────────────
printf "=== CTEST:PHASE4:CGROUP ===\n"
if [ -d /sys/fs/cgroup ]; then
    mkdir -p /sys/fs/cgroup/container-0 2>/dev/null || true
    # 将当前 PID 写入 cgroup.procs → 触发 cgroup_migrate → cgroup_attach_task
    printf "%d" $$ > /sys/fs/cgroup/container-0/cgroup.procs 2>/dev/null && \
        printf "CTEST:cgroup_attach_done\n" || printf "CTEST:cgroup_attach_skipped\n"
fi

printf "=== CTEST:ALL_PHASES_COMPLETE ===\n"

# 保持运行以供 GDB 检查
sleep 999999 &
exec /bin/sh
INIT_EOF

    chmod +x "$work_dir/init"

    # 确保 busybox 软链接（unshare/mount 命令）
    (cd "$work_dir" && ln -sf /bin/busybox bin/unshare 2>/dev/null || true)

    # 重新打包
    (cd "$work_dir" && find . | cpio -o --quiet -H newc | gzip > "$CONTAINER_INITRD")

    ok "Container-test initrd: $CONTAINER_INITRD"
    info "  大小: $(wc -c < "$CONTAINER_INITRD") bytes"
    trap - EXIT
    rm -rf "$work_dir"
}

# ── 3. 启动 QEMU（GDB stub mode）─────────────────────────────────────────────
start_qemu() {
    [[ -f "$BZIMAGE" ]] || die "bzImage 未找到: $BZIMAGE（先运行 scripts/mac/06-build-kernel.sh）"
    [[ -f "$CONTAINER_INITRD" ]] || die "container initrd 未找到: $CONTAINER_INITRD"

    # 清理可能残留的旧 QEMU 进程（占用同一 GDB 端口）
    local old_pid
    old_pid=$(ss -tlnp 2>/dev/null | grep ":$GDB_PORT" | grep -oP 'pid=\K[0-9]+' | head -1 || true)
    if [[ -n "$old_pid" ]]; then
        warn "端口 $GDB_PORT 被 PID $old_pid 占用，尝试清理..."
        kill "$old_pid" 2>/dev/null || true
        sleep 1
    fi

    info "启动 QEMU（TCG，GDB stub :$GDB_PORT）..."
    qemu-system-x86_64 \
        -kernel "$BZIMAGE" \
        -initrd "$CONTAINER_INITRD" \
        -append "console=ttyS0 nokaslr panic=-1 quiet" \
        -m 512M \
        -nographic \
        -no-reboot \
        -s -S \
        > /tmp/qemu-container-test.log 2>&1 &
    local qpid=$!
    echo "$qpid" > "$QEMU_PID_FILE"

    # 等待 GDB stub 就绪（最多 15s）
    local retry=0
    while ! ss -tlnp 2>/dev/null | grep -q ":$GDB_PORT"; do
        retry=$((retry + 1))
        if [[ $retry -ge 30 ]]; then
            kill "$qpid" 2>/dev/null || true
            die "QEMU GDB stub 未在 15s 内就绪（查看 /tmp/qemu-container-test.log）"
        fi
        # 检查 QEMU 是否提前退出
        kill -0 "$qpid" 2>/dev/null || {
            warn "QEMU (PID $qpid) 意外退出"
            cat /tmp/qemu-container-test.log | tail -5 | sed 's/^/  /' || true
            die "QEMU 启动失败"
        }
        sleep 0.5
    done
    ok "QEMU 就绪（PID $qpid，GDB stub :$GDB_PORT）"
}

# ── 4. 停止 QEMU ──────────────────────────────────────────────────────────────
stop_qemu() {
    if [[ -f "$QEMU_PID_FILE" ]]; then
        local pid
        pid=$(cat "$QEMU_PID_FILE" 2>/dev/null || true)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            info "QEMU 已停止 (PID $pid)"
        fi
        rm -f "$QEMU_PID_FILE"
    fi
}

# ── 5. GDB 断点测试 ──────────────────────────────────────────────────────────
run_gdb_test() {
    info "运行 GDB 容器断点测试（超时 ${TEST_TIMEOUT}s）..."

    local bp_idx=1
    local gdb_script
    gdb_script=$(mktemp /tmp/kernel-container-gdb-XXXX.gdb)

    {
        echo "set pagination off"
        echo "set confirm off"
        echo "file $VMLINUX"
        echo "target remote :$GDB_PORT"
        echo ""
        echo "# 设置容器相关断点（带自动继续命令）"

        for sym in "${!CONTAINER_BPS[@]}"; do
            echo "b $sym"
            echo "commands $bp_idx"
            echo "  silent"
            echo "  printf \"KERNEL_BP_HIT:${sym}\\n\""
            echo "  bt 4"
            echo "  disable $bp_idx"
            echo "  c"
            echo "end"
            bp_idx=$((bp_idx + 1))
        done

        echo ""
        echo "printf \"GDB: all breakpoints set, booting kernel...\\n\""
        echo "info breakpoints"
        echo "c"
        # GDB stays here until timeout kills it
    } > "$gdb_script"

    info "GDB 脚本: $gdb_script"
    echo ""

    # 运行 GDB，超时后强制退出
    timeout "$TEST_TIMEOUT" gdb -batch -x "$gdb_script" 2>&1 | tee "$GDB_LOG" || true

    rm -f "$gdb_script"
}

# ── 6. 解析结果 ───────────────────────────────────────────────────────────────
parse_results() {
    echo ""
    echo "══ 容器内核函数断点测试结果 ═══════════════════════════════════"
    echo ""
    printf "  %-30s %-8s %s\n" "内核函数" "结果" "说明"
    printf "  %-30s %-8s %s\n" "------" "------" "------"

    local pass=0 fail=0
    for sym in "${!CONTAINER_BPS[@]}"; do
        if grep -q "KERNEL_BP_HIT:${sym}" "$GDB_LOG" 2>/dev/null; then
            printf "  \033[1;32m✓ PASS\033[0m  %-28s %s\n" "$sym" "${CONTAINER_BPS[$sym]}"
            pass=$((pass + 1))
        else
            # 检查断点是否至少设置成功（即使未触发）
            if grep -q "Breakpoint.*${sym}" "$GDB_LOG" 2>/dev/null; then
                printf "  \033[1;33m⚠ SET \033[0m  %-28s %s\n" "$sym" "(set but not triggered in timeout)"
            else
                printf "  \033[1;31m✗ FAIL\033[0m  %-28s %s\n" "$sym" "(symbol not found or error)"
                fail=$((fail + 1))
            fi
        fi
    done

    echo ""
    info "结果: ${pass} 个触发，$((${#CONTAINER_BPS[@]} - pass - fail)) 个已设置未触发，${fail} 个失败"
    echo ""
    echo "  调用栈示例（首次触发）："
    grep -A 5 "KERNEL_BP_HIT:" "$GDB_LOG" 2>/dev/null | head -40 | sed 's/^/    /' || true
    echo ""
    info "完整 GDB 日志: $GDB_LOG"
    echo "══════════════════════════════════════════════════════════════"
}

# ── 交互式 GDB 模式 ──────────────────────────────────────────────────────────
run_interactive_gdb() {
    info "启动交互式 GDB（attach :$GDB_PORT）..."
    echo ""
    echo "  已准备好的断点命令（粘贴到 GDB）："
    for sym in "${!CONTAINER_BPS[@]}"; do
        echo "    b $sym"
    done
    echo "    c"
    echo ""
    exec gdb "$VMLINUX" -ex "target remote :$GDB_PORT"
}

# ── 主流程 ────────────────────────────────────────────────────────────────────
echo ""
echo "══ Linux 内核容器函数断点测试 ════════════════════════════════"
echo "  vmlinux: $VMLINUX"
echo "  bzImage: $BZIMAGE"
echo "  模式:    ${MODE:-full}"
echo "══════════════════════════════════════════════════════════════"
echo ""

case "$MODE" in
    --symbols)
        verify_symbols
        exit 0
        ;;
    --gdb)
        verify_symbols
        build_container_initrd
        trap stop_qemu EXIT
        start_qemu
        run_interactive_gdb
        ;;
    *)
        verify_symbols
        build_container_initrd
        trap stop_qemu EXIT
        start_qemu
        run_gdb_test
        parse_results
        stop_qemu
        trap - EXIT
        ;;
esac
