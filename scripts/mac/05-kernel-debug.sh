#!/usr/bin/env bash
# Linux 内核 GDB 调试会话
#
# 前置：
#   Terminal A: bash scripts/mac/04-launch-qemu.sh --gdb [--gdbs]
#   Terminal B: bash scripts/mac/05-kernel-debug.sh  ← 本脚本
#
# 连接方式：macOS host 的 gdb 通过 QEMU GDB stub (:1234) 调试内核
# 无需任何代码签名，不需要进入 VM
#
# 与 KGDB 的区别：
#   QEMU GDB stub → QEMU 作为 GDB server，暂停整个虚拟 CPU
#                    无需内核 CONFIG_KGDB，调试粒度到 CPU 指令级
#   KGDB          → 内核本身作为 GDB server（通过串口/网络），
#                    仅在 kgdb 断点处暂停，其余 CPU 继续运行
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$_SCRIPT_DIR/../.." && pwd)"
VMLINUX="$REPO_ROOT/build/mac-debug/kernel/vmlinux"
GDB_PORT="${GDB_PORT:-1234}"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[ERR ]\033[0m  $*"; exit 1; }

[[ -f "$VMLINUX" ]] || die "vmlinux 不存在: $VMLINUX（先运行 bash scripts/mac/01-build-kernel.sh）"

# ── 等待 QEMU GDB stub 就绪 ───────────────────────────────────────────────────
info "等待 QEMU GDB stub (:$GDB_PORT)..."
for i in $(seq 1 30); do
    nc -z localhost "$GDB_PORT" 2>/dev/null && break || sleep 1
done
nc -z localhost "$GDB_PORT" 2>/dev/null || die "QEMU GDB stub 未在 :$GDB_PORT 监听（先启动 QEMU --gdb 模式）"
ok "QEMU GDB stub 已就绪"

# ── 生成 GDB 初始化脚本 ────────────────────────────────────────────────────────
GDB_INIT=$(mktemp /tmp/kernel-gdb-XXXX.gdb)
cat > "$GDB_INIT" << EOF
# ARM64 Linux 内核调试配置
set architecture aarch64
set print pretty on
set pagination off

# 加载内核符号
file ${VMLINUX}

# 连接 QEMU GDB stub
target remote :${GDB_PORT}

# 加载内核 GDB 脚本（lx-ps / lx-dmesg / lx-symbols 等命令）
add-auto-load-safe-path ${REPO_ROOT}/build/mac-debug/linux-src/
python
import sys
sys.path.append("${REPO_ROOT}/build/mac-debug/linux-src/scripts/gdb")
try:
    import linux
    print("内核 GDB 脚本已加载（lx-ps / lx-dmesg 等命令可用）")
except ImportError:
    print("提示: 内核 GDB 脚本未找到，lx-* 命令不可用")
end

echo \\n
echo === 内核 GDB 调试就绪 ===\\n
echo 常用命令:\\n
echo   lx-ps              # 列出所有进程（类似 ps aux）\\n
echo   lx-dmesg           # 打印内核日志\\n
echo   lx-lsmod           # 列出内核模块\\n
echo   lx-symbols         # 加载模块符号\\n
echo \\n
echo 断点示例（输入后按回车）:\\n
echo   b do_sys_openat2        # 文件 open 系统调用\\n
echo   b tcp_connect           # TCP 连接发起\\n
echo   b copy_process          # fork/clone 进程创建\\n
echo   b __do_execve           # exec 执行新程序\\n
echo   b cgroup_attach_task    # 进程加入 cgroup（容器相关）\\n
echo   b security_bprm_check   # 安全检查（exec 前）\\n
echo   b ksys_mount            # mount 系统调用\\n
echo \\n
EOF

# ── 打印调试建议 ──────────────────────────────────────────────────────────────
echo ""
info "══ 内核断点调试指南 ══"
echo ""
echo "  ─── 系统调用层（内核入口）─────────────────────────────────"
echo "  b do_sys_openat2              # open/openat 系统调用"
echo "  b __x64_sys_read              # read 系统调用（x86_64 版函数名）"
echo "  b __arm64_sys_openat          # open  系统调用（ARM64 版函数名）"
echo "  b __arm64_sys_execve          # execve 系统调用（ARM64）"
echo ""
echo "  ─── 进程/调度 ──────────────────────────────────────────────"
echo "  b copy_process                # fork/clone → 创建进程（容器启动触发）"
echo "  b wake_up_new_task            # 新任务被唤醒进入调度队列"
echo "  b schedule                    # 调度器主函数"
echo "  b do_exit                     # 进程退出"
echo ""
echo "  ─── 内存 ───────────────────────────────────────────────────"
echo "  b do_mmap                     # mmap 内存映射"
echo "  b handle_mm_fault             # 缺页中断处理"
echo "  b __alloc_pages               # 物理页分配"
echo ""
echo "  ─── 网络 ───────────────────────────────────────────────────"
echo "  b tcp_connect                 # TCP 主动连接"
echo "  b tcp_v4_rcv                  # TCP 数据包接收"
echo "  b inet_listen                 # socket listen"
echo ""
echo "  ─── 文件系统 ──────────────────────────────────────────────"
echo "  b do_mount                    # mount 文件系统"
echo "  b vfs_open                    # VFS open"
echo "  b vfs_write                   # VFS write"
echo ""
echo "  ─── 容器/cgroup（K8s 相关）─────────────────────────────────"
echo "  b unshare_nsproxy_namespaces  # namespace 隔离（容器创建）"
echo "  b cgroup_attach_task          # 进程加入 cgroup"
echo "  b security_bprm_check         # 安全检查（exec 前，seccomp/AppArmor）"
echo "  b proc_cgroup_show            # 读取 /proc/<pid>/cgroup"
echo ""
echo "  ─── 触发方式（SSH 进 VM 执行）────────────────────────────────"
echo "  # 触发 open/read：  cat /etc/hostname"
echo "  # 触发 fork：       bash -c 'echo hi'"
echo "  # 触发 TCP：        curl http://example.com"
echo "  # 触发 cgroup：     systemctl start any.service"
echo ""

# ── 启动 GDB ──────────────────────────────────────────────────────────────────
GDB_BIN=""
for g in gdb gdb-multiarch aarch64-linux-gnu-gdb; do
    command -v "$g" &>/dev/null && { GDB_BIN="$g"; break; }
done

if [[ -n "$GDB_BIN" ]]; then
    info "启动 $GDB_BIN..."
    exec "$GDB_BIN" -x "$GDB_INIT"
else
    warn "未找到 gdb（brew install gdb），改用 Docker 运行..."
    docker run --rm -it \
        --network host \
        -v "$REPO_ROOT/build/mac-debug/kernel:/kernel" \
        -v "$REPO_ROOT/build/mac-debug/linux-src:/linux-src" \
        -v "$GDB_INIT:/tmp/kernel.gdb" \
        ubuntu:22.04 bash -c "
            apt-get install -y -qq gdb-multiarch 2>/dev/null | tail -1
            gdb-multiarch -x /tmp/kernel.gdb
        "
fi

rm -f "$GDB_INIT"
