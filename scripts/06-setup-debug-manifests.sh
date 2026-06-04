#!/usr/bin/env bash
# 将控制平面组件从容器模式切换到 host 直接运行 + dlv exec 调试模式
#
# 原理：
#   FROM-scratch 容器内无 libc，动态链接的 dlv 无法在容器内执行。
#   解决方案：移除静态 Pod manifest，在 host 上直接用 dlv exec 启动组件。
#   host 上有 libc，dlv 可正常工作；组件读取的证书/配置路径不变。
#
# 用法:
#   bash 06-setup-debug-manifests.sh          # 切换到 dlv host 调试模式
#   bash 06-setup-debug-manifests.sh restore  # 恢复容器模式（还原 manifest）
set -euo pipefail

MODE="${1:-patch}"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[ERR ]\033[0m  $*"; exit 1; }

MANIFEST_DIR=/etc/kubernetes/manifests
BACKUP_DIR=/etc/kubernetes/manifests.orig
DLV=/usr/local/bin/dlv

# ── restore 模式 ──────────────────────────────────────────────────────────────
if [[ "$MODE" == "restore" ]]; then
    info "停止 host dlv 调试进程..."
    pkill -f "dlv exec.*kube-apiserver"          2>/dev/null || true
    pkill -f "dlv exec.*kube-controller-manager" 2>/dev/null || true
    pkill -f "dlv exec.*kube-scheduler"          2>/dev/null || true
    pkill -f "dlv exec.*etcd"                    2>/dev/null || true
    sleep 2

    [[ -d "$BACKUP_DIR" ]] || die "无备份目录 $BACKUP_DIR"
    info "恢复静态 Pod manifest..."
    for f in "$BACKUP_DIR"/*.yaml; do
        name=$(basename "$f")
        cp "$f" "$MANIFEST_DIR/$name"
        ok "  $name 已恢复"
    done

    info "等待 API server 恢复..."
    for i in $(seq 1 30); do
        curl -sk https://127.0.0.1:6443/healthz 2>/dev/null | grep -q ok && \
            ok "API server 就绪" && break
        sleep 2
    done
    echo ""
    ok "控制平面已恢复为容器模式"
    exit 0
fi

# ── patch 模式前置检查 ────────────────────────────────────────────────────────
[[ -d "$MANIFEST_DIR" ]] || die "未找到 $MANIFEST_DIR"
[[ -f "$DLV" ]] || die "dlv 不在 $DLV"

# 确认 dlv 不是 symlink（FROM-scratch 容器会 fail，host 模式不需要但也确保正确）
if [[ -L "$DLV" ]]; then
    warn "dlv 是 symlink，替换为真实文件..."
    DLV_TARGET=$(readlink -f "$DLV")
    cp "$DLV_TARGET" /tmp/dlv-real
    mv /tmp/dlv-real "$DLV"
    chmod +x "$DLV"
    ok "dlv 已替换为真实文件"
fi

# 检查 debug 二进制
for bin in kube-apiserver kube-controller-manager kube-scheduler etcd; do
    host_bin="/usr/local/bin/$bin"
    if [[ ! -f "$host_bin" ]]; then
        if [[ "$bin" == "etcd" ]]; then
            warn "  $host_bin 不存在，etcd 将跳过（先运行 make build-etcd && make inject-binaries）"
            continue
        fi
        die "$host_bin 不存在，先运行 make build-k8s && make inject-binaries"
    fi
    has_dwarf=$(readelf -S "$host_bin" 2>/dev/null | grep -c "\.debug_info" || true)
    if [[ "$has_dwarf" -gt 0 ]]; then
        ok "  $host_bin：DWARF 调试符号 ✓"
    else
        warn "  $host_bin：无 DWARF（stripped），仅函数级调试"
    fi
done

# 备份 manifest（只做一次）
if [[ ! -d "$BACKUP_DIR" ]]; then
    mkdir -p "$BACKUP_DIR"
    cp "$MANIFEST_DIR"/*.yaml "$BACKUP_DIR/"
    ok "manifest 已备份至 $BACKUP_DIR"
fi

# ── 从 manifest 中提取组件启动参数 ───────────────────────────────────────────
get_component_args() {
    local component="$1"
    local manifest="$MANIFEST_DIR/${component}.yaml"

    python3 - "$manifest" << 'PYTHON'
import sys, yaml
with open(sys.argv[1]) as f:
    m = yaml.safe_load(f)
cmd = m['spec']['containers'][0]['command']
# 跳过二进制名本身，只输出参数
for arg in cmd[1:]:
    print(arg)
PYTHON
}

# ── 停止容器版本（删除 manifest，kubelet 自动停容器）────────────────────────
stop_container() {
    local component="$1"
    local manifest="$MANIFEST_DIR/${component}.yaml"

    info "停止 ${component} 容器..."
    # 只重命名（不删除），kubelet 检测到 manifest 消失后会停容器
    mv "$manifest" "${manifest}.debug-disabled"
    ok "  $component manifest 已禁用"
}

# ── 在 host 上用 dlv exec 启动组件 ───────────────────────────────────────────
start_dlv_host() {
    local component="$1"
    local port="$2"
    local log="/tmp/dlv-${component}.log"

    # 获取原始启动参数
    local args_file
    args_file=$(mktemp)
    get_component_args "$component" > "$args_file" 2>/dev/null || true

    # 构造参数列表
    mapfile -t ARGS < "$args_file"
    rm -f "$args_file"

    info "在 host 启动 dlv exec ${component}（端口 ${port}）..."
    info "  args: ${ARGS[*]:0:3} ..."

    # 停止已有的同名 dlv 进程
    pkill -f "dlv exec.*${component}" 2>/dev/null || true
    sleep 1

    bash -c "
        $DLV exec /usr/local/bin/$component \
            --headless \
            --listen=0.0.0.0:$port \
            --api-version=2 \
            --accept-multiclient \
            --continue \
            --check-go-version=false \
            -- $(printf '%q ' "${ARGS[@]}") \
        > $log 2>&1
    " &
    disown

    ok "  dlv exec ${component} 已启动（bg），日志: $log"
}

# ── 生成 launcher 脚本（正确处理含空格/特殊字符的参数）──────────────────────
make_launcher() {
    local component="$1"
    local port="$2"
    local launcher="/tmp/dlv-launch-${component}.sh"

    python3 - "$MANIFEST_DIR/${component}.yaml" "$port" "$launcher" "$DLV" << 'PYEOF'
import sys, yaml, shlex, os
manifest_path, port, launcher_path, dlv_path = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(manifest_path) as f:
    m = yaml.safe_load(f)
cmd = m['spec']['containers'][0]['command']
# cmd[0] is the binary name (e.g. kube-scheduler), resolve to /usr/local/bin/<name>
bin_name = os.path.basename(cmd[0])
binary_path = f"/usr/local/bin/{bin_name}"
args = cmd[1:]
lines = [
    "#!/usr/bin/env bash",
    f"exec {shlex.quote(dlv_path)} exec {shlex.quote(binary_path)} \\",
    f"    --headless --listen=0.0.0.0:{port} \\",
    "    --api-version=2 --accept-multiclient \\",
    "    --continue --check-go-version=false \\",
    "    -- \\",
]
for i, arg in enumerate(args):
    suffix = " \\" if i < len(args) - 1 else ""
    lines.append(f"    {shlex.quote(arg)}{suffix}")
with open(launcher_path, 'w') as f:
    f.write('\n'.join(lines) + '\n')
os.chmod(launcher_path, 0o755)
print(launcher_path)
PYEOF
}

# ── 执行切换 ──────────────────────────────────────────────────────────────────
# 组件列表：component:port — etcd 仅在二进制存在时添加
COMPONENTS=("kube-apiserver:2345" "kube-controller-manager:2346" "kube-scheduler:2347")
[[ -f "/usr/local/bin/etcd" ]] && COMPONENTS+=("etcd:2351")

# 先生成所有 launcher（manifest 还在时提取参数）
declare -A LAUNCHERS
for pair in "${COMPONENTS[@]}"; do
    component="${pair%%:*}"
    port="${pair##*:}"
    manifest="$MANIFEST_DIR/${component}.yaml"
    [[ -f "$manifest" ]] || { warn "  $manifest 不存在，跳过 $component"; continue; }
    launcher=$(make_launcher "$component" "$port") || die "生成 launcher 失败: $component"
    LAUNCHERS["$component"]="$launcher"
    ok "  launcher 已生成: $launcher"
done

# 停容器并以 dlv exec 方式在 host 启动
for pair in "${COMPONENTS[@]}"; do
    component="${pair%%:*}"
    port="${pair##*:}"

    [[ -v "LAUNCHERS[$component]" ]] || continue

    # 禁用 manifest（kubelet 检测到 manifest 消失后会停容器）
    mv "$MANIFEST_DIR/${component}.yaml" \
       "$MANIFEST_DIR/${component}.yaml.debug-disabled" 2>/dev/null || true

    # 等旧容器停（最多 20s）
    for i in $(seq 1 20); do
        if ! ctr -n k8s.io tasks list 2>/dev/null | grep -q "$component"; then
            break
        fi
        sleep 1
    done

    log="/tmp/dlv-${component}.log"
    pkill -f "dlv exec.*${component}" 2>/dev/null || true
    sleep 0.5

    # 用 launcher 脚本启动（参数已正确 shell-quoted）
    launcher="${LAUNCHERS[$component]}"
    nohup "$launcher" > "$log" 2>&1 &
    disown

    ok "  $component: dlv exec on host, port=$port, log=$log"
done

# ── 等待 dlv 端口就绪 ────────────────────────────────────────────────────────
info "等待 dlv 端口就绪（host 进程直接启动，通常 <15s）..."
declare -A PORT_COMP=([2345]="kube-apiserver" [2346]="kube-controller-manager" [2347]="kube-scheduler" [2351]="etcd")
all_ready=true

PORTS=(2345 2346 2347)
[[ -v "LAUNCHERS[etcd]" ]] && PORTS+=(2351)

for port in "${PORTS[@]}"; do
    comp="${PORT_COMP[$port]}"
    ready=false
    for i in $(seq 1 45); do
        if ss -tlnp 2>/dev/null | grep -q ":${port}"; then
            ok "  :${port} (${comp}) 就绪"
            ready=true
            break
        fi
        [[ $((i % 5)) -eq 0 ]] && info "  等待 :${port} (${i}s)..."
        sleep 2
    done
    if ! $ready; then
        warn "  :${port} (${comp}) 启动超时，查看日志: cat /tmp/dlv-${comp}.log"
        all_ready=false
    fi
done

echo ""
if $all_ready; then
    ok "所有控制平面组件已以 dlv exec host 模式启动"
else
    warn "部分组件未就绪，请检查日志"
    for comp in kube-apiserver kube-controller-manager kube-scheduler etcd; do
        [[ -f "/tmp/dlv-${comp}.log" ]] && echo "  cat /tmp/dlv-$comp.log"
    done
fi

echo ""
echo "连接命令:"
echo "  dlv connect localhost:2345   # kube-apiserver"
echo "  dlv connect localhost:2346   # kube-controller-manager"
echo "  dlv connect localhost:2347   # kube-scheduler"
[[ -v "LAUNCHERS[etcd]" ]] && echo "  dlv connect localhost:2351   # etcd"
echo ""
echo "日志:"
echo "  tail -f /tmp/dlv-kube-apiserver.log"
echo "  tail -f /tmp/dlv-kube-scheduler.log"
[[ -v "LAUNCHERS[etcd]" ]] && echo "  tail -f /tmp/dlv-etcd.log"
echo ""
echo "恢复容器模式: bash scripts/06-setup-debug-manifests.sh restore"
