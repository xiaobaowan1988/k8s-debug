#!/usr/bin/env bash
# 调试 systemd（GDB attach PID 1）
#
# 在 VM 内运行：
#   bash debug/systemd.sh          # 安装调试符号 + 打印断点建议
#   bash debug/systemd.sh --attach # 安装后直接进入 gdb 交互会话
#
# 触发断点示例（另开 SSH 窗口）：
#   systemctl start ssh
#   systemctl stop ssh
set -euo pipefail

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[ERR ]\033[0m  $*"; exit 1; }

[[ "$(id -u)" -eq 0 ]] || die "需要 root 权限"
command -v systemctl >/dev/null || die "非 systemd 系统"

GDB_INIT="/tmp/systemd-gdb.gdb"

# ── 安装 gdb + systemd-dbgsym ─────────────────────────────────────────────────
if ! command -v gdb >/dev/null; then
    info "安装 gdb..."
    apt-get install -y -qq gdb
fi

if ! dpkg -l systemd-dbgsym 2>/dev/null | grep -q "^ii"; then
    info "安装 systemd-dbgsym（调试符号包）..."
    # Debian debug 符号仓库
    if ! grep -q "debian-debug" /etc/apt/sources.list 2>/dev/null; then
        echo "deb http://deb.debian.org/debian-debug/ bookworm-debug main" \
            >> /etc/apt/sources.list
    fi
    apt-get update -qq
    apt-get install -y -qq systemd-dbgsym
fi

ok "gdb $(gdb --version | head -1 | grep -oP '\d+\.\d+')"
ok "systemd-dbgsym $(dpkg -l systemd-dbgsym | grep '^ii' | awk '{print $3}')"

# ── 生成 GDB 初始化脚本 ───────────────────────────────────────────────────────
cat > "$GDB_INIT" << 'EOF'
set pagination off
set print pretty on

# ── service 启动/停止 ─────────────────────────────────────────────────────────
# b unit_start
#    → 任意 unit 被激活时触发（触发: systemctl start ssh）
# b service_start
#    → service 类型 unit 启动
# b service_stop
#    → service 停止（触发: systemctl stop ssh）

# ── cgroup 管理 ───────────────────────────────────────────────────────────────
# b unit_attach_pid
#    → 进程被加入某个 unit 的 cgroup
# b cgroup_context_apply
#    → cgroup 资源限制（CPU/Memory/IO）被应用

# ── 依赖解析/job 队列 ─────────────────────────────────────────────────────────
# b manager_add_job
#    → 新任务（start/stop/reload）进入队列
# b transaction_activate
#    → 一批 job 被一起激活（解决依赖后）

# ── D-Bus 接口 ────────────────────────────────────────────────────────────────
# b bus_unit_method_start
#    → systemctl start 通过 D-Bus 调用的入口（触发: systemctl start ssh）

# 取消下行注释，启用需要的断点，然后 c 继续执行：
b unit_start
# b bus_unit_method_start
# b cgroup_context_apply

echo "断点已设置。执行 'c' 继续，另开终端 'systemctl start ssh' 触发断点。"
echo "有用命令：  p u->id    info threads    thread apply all bt"
EOF

ok "GDB 初始化脚本: $GDB_INIT"

# ── 打印使用说明 ──────────────────────────────────────────────────────────────
echo ""
echo "══ systemd GDB 调试 ══════════════════════════════════════"
echo ""
echo "  PID 1 (systemd): $(cat /proc/1/comm 2>/dev/null)"
echo "  version: $(systemctl --version | head -1)"
echo ""
echo "  连接命令（取消 $GDB_INIT 内注释选择断点）："
echo "    gdb -p 1 -x $GDB_INIT"
echo ""
echo "  断点触发（另开终端）："
echo "    systemctl start ssh"
echo "    systemctl stop ssh"
echo ""
echo "  常用 GDB 命令："
echo "    info threads           # 列出所有线程"
echo "    thread apply all bt    # 所有线程调用栈"
echo "    p u->id                # unit 名称（断在 unit_start 后）"
echo "    p *u                   # 打印 Unit 结构体"
echo "══════════════════════════════════════════════════════════"

# ── --attach 模式：直接进入 GDB ───────────────────────────────────────────────
if [[ "${1:-}" == "--attach" ]]; then
    echo ""
    info "进入 GDB（attach PID 1）..."
    exec gdb -p 1 -x "$GDB_INIT"
fi
