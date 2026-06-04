#!/usr/bin/env bash
# 检查并安装 macOS 依赖（Apple Silicon + QEMU 内核/systemd 调试环境）
#
# 整体架构：
#
#   macOS host (Apple Silicon)
#   ├── QEMU virt machine (accel=hvf, ARM64 native 速度)
#   │   ├── 自编 Linux v6.12 内核（CONFIG_KPROBES/FTRACE/KGDB=y）
#   │   └── Debian 12 ARM64 根文件系统
#   │       └── systemd v257（调试符号版）
#   │
#   ├── QEMU GDB stub (:1234) ──── gdb-multiarch vmlinux
#   │                                └── 内核函数断点
#   └── SSH (:2222) ──────────────── gdb -p 1
#                                     └── systemd 断点
#
# 执行顺序：
#   bash scripts/mac/00-check-prerequisites.sh
#   bash scripts/mac/01-build-kernel.sh
#   bash scripts/mac/02-prepare-rootfs.sh
#   bash scripts/mac/03-build-systemd.sh    # 可选，distro 版 + dbgsym 包也够用
#   bash scripts/mac/04-launch-qemu.sh      # 启动 VM（另开终端保持运行）
#   bash scripts/mac/05-kernel-debug.sh     # 内核 GDB 会话
#   bash scripts/mac/06-systemd-debug.sh    # systemd GDB 会话

set -euo pipefail

ok()   { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
info() { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
fail() { echo -e "\033[1;31m[FAIL]\033[0m  $*"; MISSING+=("$1"); }

MISSING=()

echo ""
info "══ Apple Silicon 内核/systemd 调试环境 前置检查 ══"
echo ""

# ── 系统检查 ──────────────────────────────────────────────────────────────────
info "── 系统环境 ──"

ARCH=$(uname -m)
if [[ "$ARCH" == "arm64" ]]; then
    ok "Apple Silicon (arm64) ✓"
else
    warn "检测到 $ARCH，非 Apple Silicon，HVF 加速不可用（QEMU 将以纯模拟运行，速度较慢）"
fi

HVF=$(sysctl -n kern.hv_support 2>/dev/null || echo 0)
[[ "$HVF" -eq 1 ]] && ok "HVF（硬件虚拟化）已启用 ✓" || warn "HVF 不可用（macOS 系统完整性保护可能已禁用虚拟化）"

echo ""
info "── Homebrew 依赖 ──"

if ! command -v brew &>/dev/null; then
    fail "homebrew"
    warn "请先安装 Homebrew: /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/homebrew/install/HEAD/install.sh)\""
else
    ok "Homebrew $(brew --version | head -1 | awk '{print $2}') ✓"
fi

# QEMU
if command -v qemu-system-aarch64 &>/dev/null; then
    ok "QEMU $(qemu-system-aarch64 --version | head -1 | grep -oP '\d+\.\d+\.\d+') ✓"
else
    fail "qemu"
    warn "缺少 QEMU → brew install qemu"
fi

# qemu-img（通常随 QEMU 一起安装）
command -v qemu-img &>/dev/null && ok "qemu-img ✓" || { fail "qemu-img"; warn "随 QEMU 一起安装"; }

# GDB（远程调试不需要代码签名）
if command -v gdb &>/dev/null; then
    ok "gdb $(gdb --version | head -1 | grep -oP '\d+\.\d+') ✓"
elif command -v gdb-multiarch &>/dev/null; then
    ok "gdb-multiarch ✓"
else
    fail "gdb"
    warn "缺少 GDB → brew install gdb"
    warn "注意：QEMU 远程调试不需要代码签名"
fi

# Docker（内核编译用）
if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
    ok "Docker $(docker --version | grep -oP '\d+\.\d+\.\d+' | head -1) ✓"
else
    fail "docker"
    warn "缺少 Docker（用于内核和 systemd 编译）"
    warn "安装：https://docs.docker.com/desktop/mac/install/"
fi

# SSH
command -v ssh &>/dev/null && ok "ssh ✓" || fail "ssh"

# Python3（cloud-init ISO 生成）
command -v python3 &>/dev/null && ok "python3 $(python3 --version | awk '{print $2}') ✓" || fail "python3"

echo ""
info "── 推荐安装（调试体验提升）──"

# bpftool（如果调试 eBPF）
command -v bpftool &>/dev/null && ok "bpftool ✓" || warn "可选 bpftool（eBPF 调试）"

# tmux（多窗口管理）
command -v tmux &>/dev/null && ok "tmux ✓" || warn "推荐安装 tmux（方便多终端管理）→ brew install tmux"

echo ""
# ── 汇总 ─────────────────────────────────────────────────────────────────────
if [[ ${#MISSING[@]} -eq 0 ]]; then
    ok "所有必须依赖已就绪，可以开始执行后续脚本"
else
    warn "缺少依赖: ${MISSING[*]}"
    echo ""
    echo "一键安装所有缺少的 brew 包："
    BREW_PKGS=()
    [[ " ${MISSING[*]} " == *" qemu "* ]] && BREW_PKGS+=(qemu)
    [[ " ${MISSING[*]} " == *" gdb "* ]]  && BREW_PKGS+=(gdb)
    [[ ${#BREW_PKGS[@]} -gt 0 ]] && echo "  brew install ${BREW_PKGS[*]}"
    [[ " ${MISSING[*]} " == *" docker "* ]] && echo "  # Docker Desktop: https://docs.docker.com/desktop/mac/install/"
fi
echo ""
