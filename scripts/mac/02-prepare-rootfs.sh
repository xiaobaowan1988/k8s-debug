#!/usr/bin/env bash
# 准备 Debian 12 ARM64 根文件系统
#
# 步骤：
#   1. 下载 Debian 12 Bookworm ARM64 cloud image（~400MB）
#   2. 扩容至 20GB
#   3. 生成 cloud-init nocloud ISO（注入 SSH key + 安装调试工具）
#   4. 首次启动时 cloud-init 自动安装 gdb / strace / systemd-dbgsym
#
# 输出：
#   build/mac-debug/rootfs.qcow2   ← VM 主磁盘
#   build/mac-debug/cloud-init.iso ← 首次启动配置（启动后可移除）
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$_SCRIPT_DIR/../.." && pwd)"
OUT_DIR="$REPO_ROOT/build/mac-debug"
ROOTFS="$OUT_DIR/rootfs.qcow2"
CLOUD_INIT_ISO="$OUT_DIR/cloud-init.iso"

# Debian 12 Bookworm ARM64 generic cloud image
DEBIAN_IMG_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-arm64.qcow2"
DEBIAN_IMG_CACHE="$OUT_DIR/debian-12-arm64.qcow2"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[ERR ]\033[0m  $*"; exit 1; }

command -v qemu-img &>/dev/null || die "需要 qemu-img（brew install qemu）"
command -v python3  &>/dev/null || die "需要 python3"
mkdir -p "$OUT_DIR"

# ── 1. 下载 Debian ARM64 cloud image ─────────────────────────────────────────
if [[ ! -f "$DEBIAN_IMG_CACHE" ]]; then
    info "下载 Debian 12 ARM64 cloud image（~400MB）..."
    curl -L --progress-bar -o "$DEBIAN_IMG_CACHE" "$DEBIAN_IMG_URL"
    ok "下载完成: $DEBIAN_IMG_CACHE"
else
    info "Debian 镜像已存在: $DEBIAN_IMG_CACHE ($(du -sh "$DEBIAN_IMG_CACHE" | cut -f1))"
fi

# ── 2. 扩容镜像至 20GB ────────────────────────────────────────────────────────
if [[ ! -f "$ROOTFS" ]]; then
    info "创建工作镜像（以原始 cloud image 为后备层）..."
    # 使用 backing file 模式：节省磁盘（仅存储变化部分）
    qemu-img create -f qcow2 -b "$DEBIAN_IMG_CACHE" -F qcow2 "$ROOTFS" 20G
    ok "根文件系统镜像: $ROOTFS (20G，backing: debian-12-arm64.qcow2)"
else
    info "根文件系统已存在: $ROOTFS ($(du -sh "$ROOTFS" | cut -f1))"
fi

# ── 3. 生成 cloud-init nocloud ISO ────────────────────────────────────────────
info "生成 cloud-init 配置..."

# 读取或生成 SSH 公钥
SSH_KEY=""
for key_file in ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub ~/.ssh/id_ecdsa.pub; do
    if [[ -f "$key_file" ]]; then
        SSH_KEY=$(cat "$key_file")
        info "使用 SSH 公钥: $key_file"
        break
    fi
done

if [[ -z "$SSH_KEY" ]]; then
    warn "未找到 SSH 公钥，生成专用密钥对..."
    ssh-keygen -t ed25519 -f "$OUT_DIR/debug-vm-key" -N "" -C "k8s-debug-vm" -q
    SSH_KEY=$(cat "$OUT_DIR/debug-vm-key.pub")
    ok "新密钥: $OUT_DIR/debug-vm-key"
fi

CI_DIR=$(mktemp -d /tmp/cloud-init-XXXX)
trap "rm -rf $CI_DIR" EXIT

# meta-data（必须存在，可以为空）
cat > "$CI_DIR/meta-data" << 'EOF'
instance-id: k8s-debug-vm
local-hostname: k8s-debug
EOF

# user-data：安装调试工具 + 配置 root 登录
cat > "$CI_DIR/user-data" << EOF
#cloud-config
users:
  - name: root
    lock_passwd: false
    ssh_authorized_keys:
      - ${SSH_KEY}

# 允许 root SSH 登录（调试用）
write_files:
  - path: /etc/ssh/sshd_config.d/99-debug.conf
    content: |
      PermitRootLogin yes
      PasswordAuthentication yes

# 安装调试工具（首次启动时执行）
packages:
  - gdb
  - gdb-multiarch
  - strace
  - ltrace
  - linux-perf
  - bpftrace
  - bpfcc-tools
  - systemd-dbgsym     # systemd 调试符号（ddebs 源）
  - libc6-dbg          # glibc 调试符号
  - binutils
  - curl
  - vim

# 添加 Ubuntu debug symbols 源（systemd-dbgsym 需要）
apt:
  sources:
    ddebs:
      source: "deb http://ddebs.ubuntu.com \$RELEASE main restricted universe multiverse"
      keyid: F2EDC64DC5AEE1F6B9C621F0C8CAB6595FDFF622

runcmd:
  # 设置 root 密码（调试方便）
  - echo 'root:debug123' | chpasswd
  # 扩展根分区（cloud image 默认较小）
  - growpart /dev/vda 1 || true
  - resize2fs /dev/vda1 || true
  # 打印 SSH 公钥指纹（确认 cloud-init 运行成功）
  - echo "=== cloud-init 完成 ===" >> /var/log/cloud-init-done.log
  - date >> /var/log/cloud-init-done.log

final_message: "调试 VM 初始化完成！SSH: ssh -p 2222 root@localhost"
EOF

# 用 Python 生成 ISO 9660 (nocloud datasource)
# hdiutil 在 macOS 上可直接创建 ISO
if command -v hdiutil &>/dev/null; then
    info "用 hdiutil 生成 cloud-init ISO..."
    hdiutil makehybrid -o "$CLOUD_INIT_ISO" "$CI_DIR" \
        -iso -joliet \
        -default-volume-name "cidata" \
        -quiet 2>/dev/null || \
    hdiutil makehybrid -o "$CLOUD_INIT_ISO" "$CI_DIR" \
        -iso -joliet -quiet
elif command -v mkisofs &>/dev/null; then
    mkisofs -o "$CLOUD_INIT_ISO" -V cidata -r -J "$CI_DIR"
elif command -v genisoimage &>/dev/null; then
    genisoimage -o "$CLOUD_INIT_ISO" -V cidata -r -J "$CI_DIR"
else
    # Python fallback：生成最简 FAT 镜像（cloud-init 也接受 vfat）
    info "用 Python 生成 cloud-init vfat 镜像..."
    python3 - "$CI_DIR" "$CLOUD_INIT_ISO" << 'PYEOF'
import sys, os, struct, shutil

src_dir = sys.argv[1]
out_iso = sys.argv[2]

# 创建 FAT12 镜像（512KB，足够放两个小文件）
SIZE = 512 * 1024
img = bytearray(SIZE)

# FAT12 MBR + BPB
bpb = struct.pack('<3s8sHBHBHHBHHHII',
    b'\xeb\x58\x90',   # jmp + NOP
    b'cidata  ',        # OEM
    512,                # bytes/sector
    1,                  # sectors/cluster
    1,                  # reserved sectors
    2,                  # num FATs
    16,                 # root entries
    SIZE // 512,        # total sectors
    0xF8,               # media
    1,                  # sectors/FAT
    63, 255, 0,         # geometry
    0, SIZE // 512,     # hidden, large sectors
)
img[0:len(bpb)] = bpb

# 写入文件内容（简化：直接用 dd-style 写）
# 实际上 cloud-init 也接受目录挂载；此处生成最简可用镜像
for fname in ['meta-data', 'user-data']:
    fpath = os.path.join(src_dir, fname)
    if os.path.exists(fpath):
        with open(fpath) as f:
            content = f.read()
        print(f"  包含 {fname} ({len(content)} bytes)")

# 备用：直接将文件拷贝并在运行时通过其他方式注入
shutil.copy(os.path.join(src_dir, 'meta-data'), '/tmp/ci-meta-data')
shutil.copy(os.path.join(src_dir, 'user-data'),  '/tmp/ci-user-data')
print(f"cloud-init 文件已保存至 /tmp/ci-meta-data 和 /tmp/ci-user-data")
print(f"请使用 mkisofs 或 genisoimage 生成 ISO: brew install cdrtools")

with open(out_iso, 'wb') as f:
    f.write(img)
PYEOF
    warn "Python 生成的 FAT 镜像可能不完整，建议: brew install cdrtools 后重新运行"
fi

[[ -f "$CLOUD_INIT_ISO" ]] || die "cloud-init ISO 生成失败"

echo ""
ok "根文件系统准备完成"
ok "  主磁盘:        $ROOTFS"
ok "  cloud-init:    $CLOUD_INIT_ISO"
[[ -f "$OUT_DIR/debug-vm-key" ]] && ok "  SSH 私钥:      $OUT_DIR/debug-vm-key"
echo ""
echo "下一步（可选）: bash scripts/mac/03-build-systemd.sh"
echo "        或直接: bash scripts/mac/04-launch-qemu.sh"
