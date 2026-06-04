#!/usr/bin/env bash
# 编译 Linux v6.12 ARM64 内核（含完整调试符号）
#
# 使用 Docker（Ubuntu 22.04 ARM64）进行交叉编译，输出：
#   build/mac-debug/kernel/Image    ← QEMU 启动用（压缩内核镜像）
#   build/mac-debug/kernel/vmlinux  ← GDB 调试用（含 DWARF 符号，~1GB）
#
# 关键调试配置：
#   CONFIG_DEBUG_INFO + CONFIG_GDB_SCRIPTS → gdb 可加载内核符号和 lx-* 命令
#   CONFIG_KPROBES + CONFIG_FTRACE         → 允许动态插桩和函数追踪
#   CONFIG_KGDB                            → 内核 GDB stub（可选，本方案用 QEMU stub）
#   nokaslr（启动参数）                    → 禁用地址随机化，GDB 断点地址固定
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$_SCRIPT_DIR/../.." && pwd)"
OUT_DIR="$REPO_ROOT/build/mac-debug/kernel"
SRC_DIR="$REPO_ROOT/build/mac-debug/linux-src"

KERNEL_VER="${KERNEL_VER:-v6.12}"
JOBS="${JOBS:-$(sysctl -n hw.logicalcpu 2>/dev/null || echo 4)}"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[ERR ]\033[0m  $*"; exit 1; }

command -v docker &>/dev/null || die "需要 Docker（用于 ARM64 编译环境）"
mkdir -p "$OUT_DIR" "$SRC_DIR"

# ── 1. 克隆内核源码 ───────────────────────────────────────────────────────────
if [[ ! -d "$SRC_DIR/.git" ]]; then
    info "克隆 Linux $KERNEL_VER（--depth=1，约 200MB）..."
    git clone --depth=1 \
        --branch "$KERNEL_VER" \
        https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git \
        "$SRC_DIR"
    ok "内核源码: $SRC_DIR"
else
    info "内核源码已存在: $SRC_DIR ($(git -C "$SRC_DIR" describe --tags 2>/dev/null || echo $KERNEL_VER))"
fi

# ── 2. 生成调试内核配置 ────────────────────────────────────────────────────────
info "生成 ARM64 调试内核配置..."

# 用 Docker 运行 make defconfig + 应用调试选项
docker run --rm \
    --platform linux/arm64 \
    -v "$SRC_DIR:/linux" \
    ubuntu:22.04 bash -c "
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
    build-essential bc bison flex libssl-dev libelf-dev \
    libncurses-dev gcc make binutils cpio 2>&1 | tail -3

cd /linux
# 从 virt（虚拟机优化）配置开始
make ARCH=arm64 defconfig

# ── 调试必选项 ──────────────────────────────────────────────────────────────
# GDB 调试符号
./scripts/config --enable  DEBUG_INFO
./scripts/config --enable  DEBUG_INFO_DWARF5
./scripts/config --enable  DEBUG_KERNEL
./scripts/config --enable  GDB_SCRIPTS          # 启用 lx-ps / lx-dmesg 等内核 GDB 命令
./scripts/config --enable  FRAME_POINTER         # 准确的调用栈回溯

# kprobes / ftrace（动态插桩，eBPF 依赖）
./scripts/config --enable  KPROBES
./scripts/config --enable  KPROBES_ON_FTRACE
./scripts/config --enable  FTRACE
./scripts/config --enable  FUNCTION_TRACER
./scripts/config --enable  FUNCTION_GRAPH_TRACER
./scripts/config --enable  DYNAMIC_FTRACE
./scripts/config --enable  FTRACE_SYSCALLS       # 追踪所有系统调用
./scripts/config --enable  UPROBE_EVENTS         # 用户态 uprobe
./scripts/config --enable  FPROBE

# KGDB（内核 GDB stub，本方案用 QEMU -s 替代，但编译进去以备用）
./scripts/config --enable  KGDB
./scripts/config --enable  KGDB_SERIAL_CONSOLE
./scripts/config --enable  KGDB_KDB

# BPF（现代内核观测依赖）
./scripts/config --enable  BPF_SYSCALL
./scripts/config --enable  BPF_EVENTS
./scripts/config --enable  DEBUG_BPF_ENABLE_EXTABLE

# tracefs / debugfs
./scripts/config --enable  DEBUG_FS
./scripts/config --enable  TRACING

# 容器/namespace 相关
./scripts/config --enable  NAMESPACES
./scripts/config --enable  CGROUPS
./scripts/config --enable  CGROUP_BPF
./scripts/config --enable  MEMCG

# 减少编译时间（关闭非必要驱动）
./scripts/config --disable SOUND
./scripts/config --disable DRM

# 重新解决依赖
make ARCH=arm64 olddefconfig
echo '── 最终调试配置验证 ──'
grep -E 'CONFIG_(DEBUG_INFO|KPROBES|FTRACE|KGDB|GDB_SCRIPTS|BPF_SYSCALL)=' .config
"

ok "内核配置已生成"

# ── 3. 编译内核 ───────────────────────────────────────────────────────────────
info "编译内核（ARM64，$JOBS 核并行，约 10-20 分钟）..."

docker run --rm \
    --platform linux/arm64 \
    -v "$SRC_DIR:/linux" \
    -v "$OUT_DIR:/output" \
    ubuntu:22.04 bash -c "
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq build-essential bc bison flex libssl-dev libelf-dev 2>&1 | tail -2

cd /linux
make ARCH=arm64 -j${JOBS} Image vmlinux 2>&1 | tail -5

echo '── 复制输出文件 ──'
cp arch/arm64/boot/Image /output/Image
cp vmlinux /output/vmlinux
ls -lh /output/
"

# ── 验证 ─────────────────────────────────────────────────────────────────────
[[ -f "$OUT_DIR/Image" ]]   || die "Image 未生成"
[[ -f "$OUT_DIR/vmlinux" ]] || die "vmlinux 未生成"

DWARF=$(readelf -S "$OUT_DIR/vmlinux" 2>/dev/null | grep -c "\.debug_info" || true)
[[ "$DWARF" -gt 0 ]] && ok "vmlinux DWARF 符号已确认" || warn "vmlinux 可能缺少调试符号"

echo ""
ok "内核编译完成"
ok "  启动镜像: $OUT_DIR/Image"
ok "  调试符号: $OUT_DIR/vmlinux  ($(du -sh "$OUT_DIR/vmlinux" | cut -f1))"
echo ""
echo "下一步: bash scripts/mac/02-prepare-rootfs.sh"
