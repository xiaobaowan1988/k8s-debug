#!/usr/bin/env bash
# 从 macOS 端触发：将 repo 同步到 VM，在 VM 内编译所有 K8s 组件（含调试符号）
#
# 在 macOS 上执行本脚本。它会：
#   1. rsync k8s-debug repo 到 VM 的 /home/user/k8s-debug
#   2. SSH 进 VM，依次运行 01-clone-*.sh 和 02-build-*.sh
#
# 预计耗时：首次 30-60 分钟（取决于网速和 VM CPU）
# 重新运行：幂等，已克隆/已编译的跳过
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$_SCRIPT_DIR/../.." && pwd)"
SSH_PORT="${SSH_PORT:-2222}"
SSH_KEY="$REPO_ROOT/build/mac-debug/debug-vm-key"
SSH_OPTS="-p $SSH_PORT -o StrictHostKeyChecking=no -o ConnectTimeout=10"
[[ -f "$SSH_KEY" ]] && SSH_OPTS="$SSH_OPTS -i $SSH_KEY"
VM="root@localhost"
VM_REPO="/home/user/k8s-debug"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[ERR ]\033[0m  $*"; exit 1; }

# ── 等待 VM SSH 可达 ──────────────────────────────────────────────────────────
info "等待 VM SSH (localhost:$SSH_PORT)..."
for i in $(seq 1 60); do
    ssh $SSH_OPTS $VM "echo ok" 2>/dev/null && break
    [[ $i -eq 60 ]] && die "VM SSH 不可达（先启动 QEMU: bash scripts/mac/04-launch-qemu.sh --bg）"
    sleep 3
done
ok "VM SSH 可达"

# ── 同步 repo 到 VM ────────────────────────────────────────────────────────────
info "同步 k8s-debug repo 到 VM ($VM_REPO)..."
ssh $SSH_OPTS $VM "mkdir -p $VM_REPO"
rsync -az --progress \
    -e "ssh $SSH_OPTS" \
    --exclude='.git' \
    --exclude='build/' \
    "$REPO_ROOT/" \
    "$VM:$VM_REPO/"
ok "repo 已同步"

# ── 在 VM 内执行构建 ──────────────────────────────────────────────────────────
info "在 VM 内克隆并编译所有组件（ARM64）..."

ssh $SSH_OPTS $VM bash -s << 'REMOTE'
set -euo pipefail
export PATH=$PATH:/usr/local/go/bin:/root/go/bin

cd /home/user/k8s-debug

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }

# ── 克隆源码 ──────────────────────────────────────────────────────────────────
info "=== 克隆源码 ==="
for script in \
    scripts/01-clone-k8s.sh \
    scripts/01-clone-etcd.sh \
    scripts/01-clone-containerd.sh \
    scripts/01-clone-runc.sh \
    scripts/01-clone-cni.sh \
    scripts/01-clone-csi-hostpath.sh \
    scripts/01-clone-coredns.sh; do
    [[ -f "$script" ]] || { echo "  跳过不存在的脚本: $script"; continue; }
    info "  $script"
    bash "$script" 2>&1 | tail -3
done

# ── 编译组件 ──────────────────────────────────────────────────────────────────
info "=== 编译组件（含调试符号）==="
for script in \
    scripts/02-build-k8s.sh \
    scripts/02-build-etcd.sh \
    scripts/02-build-containerd.sh \
    scripts/02-build-runc.sh \
    scripts/02-build-cni.sh \
    scripts/02-build-csi-hostpath.sh \
    scripts/02-build-coredns.sh; do
    [[ -f "$script" ]] || { echo "  跳过不存在的脚本: $script"; continue; }
    info "  $script"
    bash "$script" 2>&1 | tail -5
done

info "=== 构建产物 ==="
ls -lh /home/user/k8s-debug/build/runtime/ 2>/dev/null || true
ls -lh /home/user/k8s-debug/build/kubernetes/ 2>/dev/null | head -10 || true

ok "VM 内所有组件编译完成"
REMOTE

echo ""
ok "所有组件已在 VM 内完成编译"
echo ""
echo "下一步: bash scripts/mac/12-vm-cluster.sh"
