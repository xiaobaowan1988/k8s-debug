#!/usr/bin/env bash
# 启动 QEMU ARM64 调试虚拟机
#
# 模式：
#   普通启动（默认）:  bash scripts/mac/04-launch-qemu.sh
#   内核调试模式:      bash scripts/mac/04-launch-qemu.sh --gdb
#                        → QEMU 在 :1234 开启 GDB server，启动时暂停
#                        → 另开终端: bash scripts/mac/05-kernel-debug.sh
#   后台运行:          bash scripts/mac/04-launch-qemu.sh --bg
#
# VM 访问：
#   SSH:  ssh -p 2222 -i build/mac-debug/debug-vm-key root@localhost
#         或 ssh -p 2222 root@localhost  (密码: debug123)
#
# QEMU monitor：Ctrl-A C  进入 monitor，Ctrl-A X  退出 QEMU
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$_SCRIPT_DIR/../.." && pwd)"
MAC_BUILD="$REPO_ROOT/build/mac-debug"

KERNEL="$MAC_BUILD/kernel/Image"
ROOTFS="$MAC_BUILD/rootfs.qcow2"
CLOUD_INIT_ISO="$MAC_BUILD/cloud-init.iso"
SSH_KEY="$MAC_BUILD/debug-vm-key"

MEM="${MEM:-4096}"         # MB
CPUS="${CPUS:-4}"
SSH_PORT="${SSH_PORT:-2222}"
GDB_PORT="${GDB_PORT:-1234}"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[ERR ]\033[0m  $*"; exit 1; }

[[ -f "$KERNEL" ]] || die "内核镜像不存在: $KERNEL（先运行 bash scripts/mac/01-build-kernel.sh）"
[[ -f "$ROOTFS" ]] || die "根文件系统不存在: $ROOTFS（先运行 bash scripts/mac/02-prepare-rootfs.sh）"

# ── 参数解析 ──────────────────────────────────────────────────────────────────
GDB_MODE=false
BG_MODE=false
PAUSE_AT_START=false

for arg in "$@"; do
    case "$arg" in
        --gdb)   GDB_MODE=true ;;
        --gdbs)  GDB_MODE=true; PAUSE_AT_START=true ;;  # --gdbs: 启动时暂停（调试早期 boot）
        --bg)    BG_MODE=true ;;
        --help)
            echo "用法: $0 [--gdb] [--gdbs] [--bg]"
            echo "  --gdb   开启 QEMU GDB server (:$GDB_PORT)，不暂停"
            echo "  --gdbs  开启 GDB server，启动时暂停（调试 kernel boot 序列）"
            echo "  --bg    后台运行（nohup）"
            exit 0 ;;
    esac
done

# ── QEMU 命令构建 ─────────────────────────────────────────────────────────────
QEMU_ARGS=(
    qemu-system-aarch64

    # ── 硬件配置 ──────────────────────────────────────────────────────────────
    -machine "virt,accel=hvf"       # ARM64 virt 机器类型 + Apple HVF 加速
    -cpu     host                   # 使用宿主 CPU（Cortex-A 系列）
    -m       "${MEM}M"
    -smp     "$CPUS"

    # ── 内核 ──────────────────────────────────────────────────────────────────
    -kernel  "$KERNEL"
    -append  "root=/dev/vda1 rw console=ttyAMA0 loglevel=8 nokaslr net.ifnames=0 biosdevname=0"
    #         ^^^^^^  关闭地址随机化，GDB 断点地址固定（调试必须）

    # ── 存储 ──────────────────────────────────────────────────────────────────
    -drive   "if=virtio,format=qcow2,file=${ROOTFS}"
)

# cloud-init ISO（仅首次启动需要；之后可移除）
if [[ -f "$CLOUD_INIT_ISO" ]]; then
    QEMU_ARGS+=(
        -drive "if=virtio,format=raw,file=${CLOUD_INIT_ISO},readonly=on"
    )
fi

# ── 网络 ──────────────────────────────────────────────────────────────────────
QEMU_ARGS+=(
    -netdev "user,id=net0,hostfwd=tcp::${SSH_PORT}-:22"
    -device "virtio-net-pci,netdev=net0"
)

# ── 串口（console + KGDB 预留）────────────────────────────────────────────────
QEMU_ARGS+=(
    -nographic
    -serial mon:stdio      # 串口 → macOS 终端，Ctrl-A C 进入 QEMU monitor
)

# ── GDB stub ──────────────────────────────────────────────────────────────────
if $GDB_MODE; then
    QEMU_ARGS+=(-gdb "tcp::${GDB_PORT}")   # 等价于 -s（固定 1234）但端口可配置
    $PAUSE_AT_START && QEMU_ARGS+=(-S)      # -S：启动时暂停，等待 GDB 连接
fi

# ── 显示命令 ──────────────────────────────────────────────────────────────────
echo ""
info "══ 启动 QEMU ARM64 调试 VM ══"
echo ""
info "内核:    $KERNEL"
info "根文件系统: $ROOTFS"
info "内存:    ${MEM}MB  CPU: $CPUS"
info "SSH:     ssh -p $SSH_PORT root@localhost  (密码: debug123)"
$GDB_MODE && info "GDB:     localhost:$GDB_PORT  → bash scripts/mac/05-kernel-debug.sh"
echo ""
echo "QEMU 命令："
echo "  ${QEMU_ARGS[*]}" | fold -s -w 100 | sed 's/^/  /'
echo ""

if $PAUSE_AT_START; then
    warn "VM 启动后将暂停，等待 GDB 连接后才继续 boot"
    warn "另开终端: bash scripts/mac/05-kernel-debug.sh"
fi

# ── 启动 ──────────────────────────────────────────────────────────────────────
if $BG_MODE; then
    LOG="$MAC_BUILD/qemu.log"
    nohup "${QEMU_ARGS[@]}" > "$LOG" 2>&1 &
    QEMU_PID=$!
    disown
    sleep 2
    kill -0 "$QEMU_PID" 2>/dev/null && ok "QEMU 已在后台运行 (PID $QEMU_PID)，日志: $LOG" || \
        die "QEMU 启动失败，查看: $LOG"
    echo ""
    echo "SSH 就绪后（cloud-init 首次约 2-3 分钟）："
    SSH_OPTS="-p $SSH_PORT -o StrictHostKeyChecking=no -o ConnectTimeout=5"
    [[ -f "$SSH_KEY" ]] && SSH_OPTS="$SSH_OPTS -i $SSH_KEY"
    echo "  ssh $SSH_OPTS root@localhost"
else
    # 前台运行，Ctrl-A X 退出
    exec "${QEMU_ARGS[@]}"
fi
