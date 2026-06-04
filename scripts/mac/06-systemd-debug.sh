#!/usr/bin/env bash
# systemd GDB 调试指南（在 VM 内部调试 PID 1）
#
# 前置：
#   bash scripts/mac/04-launch-qemu.sh   ← VM 已启动并可 SSH
#   VM 内已安装 gdb + systemd-dbgsym 或使用自编 systemd 二进制
#
# 两种调试方式：
#   方式 A：VM 内 gdb attach PID 1（最简单，调试运行中的 systemd）
#   方式 B：通过 QEMU GDB stub 调试 systemd（05-kernel-debug.sh 连接后
#            可对用户态进程设断点，但需要 kernel + systemd 符号同时加载）
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$_SCRIPT_DIR/../.." && pwd)"
SSH_KEY="$REPO_ROOT/build/mac-debug/debug-vm-key"
SSH_PORT="${SSH_PORT:-2222}"
SSH_OPTS="-p $SSH_PORT -o StrictHostKeyChecking=no -o ConnectTimeout=10"
[[ -f "$SSH_KEY" ]] && SSH_OPTS="$SSH_OPTS -i $SSH_KEY"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }

echo ""
info "══ systemd GDB 调试指南 ══"
echo ""

# ── 检查 VM SSH 可达性 ────────────────────────────────────────────────────────
info "检查 VM SSH 连接 (localhost:$SSH_PORT)..."
SSH_READY=false
for i in $(seq 1 30); do
    ssh $SSH_OPTS root@localhost "echo ok" 2>/dev/null && { SSH_READY=true; break; } || sleep 2
done

$SSH_READY && ok "VM SSH 可达" || warn "VM SSH 不可达（VM 可能仍在启动，等待 cloud-init 完成）"

# ── 在 VM 内安装调试工具 ──────────────────────────────────────────────────────
if $SSH_READY; then
    info "在 VM 内检查/安装 systemd 调试符号..."
    ssh $SSH_OPTS root@localhost << 'REMOTE'
# 检查 systemd-dbgsym 是否已安装
if ! dpkg -l systemd-dbgsym 2>/dev/null | grep -q "^ii"; then
    echo "[INFO] 安装 systemd-dbgsym..."
    # Debian dbgsym 包来自 deb.debian.org/debian-debug
    cat >> /etc/apt/sources.list << 'EOF'
deb http://deb.debian.org/debian-debug/ bookworm-debug main
EOF
    apt-get update -qq
    apt-get install -y systemd-dbgsym gdb 2>&1 | tail -5
else
    echo "[OK] systemd-dbgsym 已安装"
fi
dpkg -l systemd-dbgsym 2>/dev/null | grep "^ii" | awk '{print "[OK] systemd-dbgsym version:", $3}'
REMOTE
fi

echo ""
info "══ 方式 A：VM 内 gdb attach PID 1 ══"
echo ""
echo "  # SSH 进 VM"
echo "  ssh $SSH_OPTS root@localhost"
echo ""
echo "  # VM 内执行："
echo "  gdb -p 1   # attach 到 systemd (PID 1)"
echo ""
echo "  # GDB 中的断点建议："
echo ""
echo "  ─── service 启动/停止 ──────────────────────────────────────────"
echo "  (gdb) b unit_start"
echo "       → 任意 unit 被激活时触发"
echo "       触发: systemctl start ssh  （另开 SSH 窗口执行）"
echo ""
echo "  (gdb) b service_start"
echo "       → service 类型 unit 启动"
echo ""
echo "  (gdb) b service_stop"
echo "       → service 停止"
echo "       触发: systemctl stop ssh"
echo ""
echo "  ─── cgroup 管理 ────────────────────────────────────────────────"
echo "  (gdb) b unit_attach_pid"
echo "       → 进程被加入某个 unit 的 cgroup"
echo ""
echo "  (gdb) b cgroup_context_apply"
echo "       → cgroup 资源限制（CPU/Memory/IO）被应用"
echo ""
echo "  ─── 依赖解析/job 队列 ───────────────────────────────────────────"
echo "  (gdb) b manager_add_job"
echo "       → 新任务（start/stop/reload）进入队列"
echo ""
echo "  (gdb) b transaction_activate"
echo "       → 一批 job 被一起激活（解决依赖后）"
echo ""
echo "  ─── D-Bus 接口 ─────────────────────────────────────────────────"
echo "  (gdb) b bus_unit_method_start"
echo "       → systemctl start 通过 D-Bus 调用的入口"
echo "       触发: systemctl start ssh"
echo ""
echo "  ─── socket/fd 管理 ─────────────────────────────────────────────"
echo "  (gdb) b socket_enter_listening"
echo "       → socket unit 开始监听"
echo ""
echo "  ─── 有用的 GDB 命令 ────────────────────────────────────────────"
echo "  (gdb) info threads           # 列出所有 systemd 线程"
echo "  (gdb) thread apply all bt    # 所有线程调用栈"
echo "  (gdb) p *u                   # 打印 Unit 结构体（断在 unit_start 后）"
echo "  (gdb) p u->id                # unit 名称"
echo "  (gdb) call unit_full_status_string(u)  # 调用 systemd 内部函数"
echo ""
echo "  # 继续执行（设完断点后）："
echo "  (gdb) c"
echo ""

info "══ 方式 B：注入自编 systemd 二进制 ══"
echo ""
echo "  # 将编译好的 debug systemd 发送到 VM"
echo "  scp $SSH_OPTS $REPO_ROOT/build/mac-debug/systemd/systemd root@localhost:/tmp/"
echo ""
echo "  # SSH 进 VM，加载符号文件而不替换运行中的 systemd"
echo "  ssh $SSH_OPTS root@localhost"
echo "  gdb -p 1"
echo "  (gdb) symbol-file /tmp/systemd     # 加载自编版符号（覆盖 dbgsym 包）"
echo "  (gdb) b unit_start"
echo "  (gdb) c"
echo ""
echo "  # 也可直接替换 systemd 二进制（需重启，init= 参数指定新路径）"
echo "  # 在 QEMU -append 中加: init=/tmp/systemd"
echo ""

info "══ strace 快速观察（无需调试符号）══"
echo ""
echo "  # SSH 进 VM："
echo "  strace -p 1 -e trace=openat,socket,connect,clone -f 2>&1 | head -50"
echo "  # 触发: systemctl start ssh"
echo ""

# ── 打开一个 SSH 会话到 VM ────────────────────────────────────────────────────
if $SSH_READY; then
    echo ""
    read -rp "是否现在 SSH 进入 VM 开始调试？ [y/N] " ans
    if [[ "$ans" =~ ^[Yy]$ ]]; then
        exec ssh $SSH_OPTS root@localhost
    fi
else
    echo ""
    echo "VM 就绪后，执行："
    echo "  ssh $SSH_OPTS root@localhost"
fi
