#!/usr/bin/env bash
# 编译 systemd（ARM64，含完整调试符号）并注入 rootfs
#
# 说明：
#   Debian 12 提供 systemd-dbgsym 包（apt install systemd-dbgsym），
#   如果只需要设断点而不关心符号是否最新，可跳过本脚本，
#   直接在 VM 内 apt install systemd-dbgsym 即可。
#
#   本脚本适合需要修改 systemd 源码并调试的场景。
#
# 输出：
#   build/mac-debug/systemd/systemd   ← 含 DWARF 符号的 systemd 二进制
#   build/mac-debug/systemd/systemd.map ← 符号表（GDB 可加载）
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$_SCRIPT_DIR/../.." && pwd)"
OUT_DIR="$REPO_ROOT/build/mac-debug/systemd"
ROOTFS="$REPO_ROOT/build/mac-debug/rootfs.qcow2"

SYSTEMD_VER="${SYSTEMD_VER:-v257}"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[ERR ]\033[0m  $*"; exit 1; }

command -v docker &>/dev/null || die "需要 Docker"
mkdir -p "$OUT_DIR"

# ── 编译 systemd（ARM64，debugoptimized）─────────────────────────────────────
info "使用 Docker 编译 systemd $SYSTEMD_VER (ARM64)..."
info "（约 5-10 分钟）"

docker run --rm \
    --platform linux/arm64 \
    -v "$OUT_DIR:/output" \
    debian:12 bash -c "
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
    build-essential meson ninja-build pkg-config git \
    libcap-dev libmount-dev libssl-dev \
    libkmod-dev libblkid-dev libseccomp-dev \
    libacl1-dev libattr1-dev libpam-dev \
    python3-jinja2 python3-pyelftools \
    libdbus-1-dev gperf \
    2>&1 | tail -5

echo '── 克隆 systemd ${SYSTEMD_VER} ──'
git clone --depth=1 --branch ${SYSTEMD_VER} \
    https://github.com/systemd/systemd.git /systemd 2>&1 | tail -3

cd /systemd

echo '── 配置编译选项 ──'
meson setup build \
    -Dbuildtype=debugoptimized \
    -Db_ndebug=false \
    -Db_pie=true \
    -Dman=false \
    -Dhtml=false \
    -Dtests=false \
    -Dfuzz-tests=false \
    -Dslow-tests=false \
    -Dstandalone-binaries=true \
    2>&1 | tail -5

echo '── 编译（仅 systemd 主进程，跳过全量组件）──'
ninja -C build systemd 2>&1 | tail -5

echo '── 验证调试符号 ──'
readelf -S build/systemd | grep -c '\.debug_info'

echo '── 复制输出 ──'
cp build/systemd /output/systemd
# 提取符号表（nm）供 GDB 加载
nm -n build/systemd > /output/systemd.map 2>/dev/null || true
ls -lh /output/
"

[[ -f "$OUT_DIR/systemd" ]] || die "systemd 编译失败"

DWARF=$(readelf -S "$OUT_DIR/systemd" 2>/dev/null | grep -c "\.debug_info" || true)
[[ "$DWARF" -gt 0 ]] && ok "systemd DWARF 符号已确认" || warn "systemd 可能缺少调试符号"

echo ""
ok "systemd 编译完成"
ok "  二进制: $OUT_DIR/systemd  ($(du -sh "$OUT_DIR/systemd" | cut -f1))"
ok "  符号表: $OUT_DIR/systemd.map"
echo ""
echo "使用方式（在 VM 内替换 systemd）："
echo "  # SSH 进 VM 后："
echo "  scp -P 2222 build/mac-debug/systemd/systemd root@localhost:/tmp/"
echo "  # 替换后用 init=/tmp/systemd 重启，或用 gdb 加载符号文件："
echo "  # (gdb) add-symbol-file /tmp/systemd 0x<text_section_addr>"
echo ""
echo "更简单的替代方案（直接用 Debian 的调试包）："
echo "  # 在 VM 内："
echo "  apt-get install -y systemd-dbgsym"
echo ""
echo "下一步: bash scripts/mac/04-launch-qemu.sh"
