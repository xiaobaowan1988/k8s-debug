#!/usr/bin/env bash
# 将控制平面静态 Pod manifest 替换为 dlv exec 版本
# 直接操作本机 /etc/kubernetes/manifests/（无 Kind / Docker）
set -euo pipefail

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[ERR ]\033[0m  $*"; exit 1; }

command -v dlv      || die "dlv 未安装，请先运行 make setup"
command -v python3  || die "python3 未安装"
[[ -d /etc/kubernetes/manifests ]] || die "未找到 /etc/kubernetes/manifests，集群是否已初始化？"

patch_manifest() {
    local component="$1"
    local port="$2"
    local manifest="/etc/kubernetes/manifests/${component}.yaml"

    [[ -f "$manifest" ]] || { warn "manifest 不存在: $manifest，跳过"; return; }

    info "配置 ${component} 使用 dlv exec（端口 ${port}）..."

    python3 - "$manifest" "$port" << 'PYTHON'
import sys, yaml

manifest_path = sys.argv[1]
port = int(sys.argv[2])

with open(manifest_path) as f:
    manifest = yaml.safe_load(f)

container = manifest['spec']['containers'][0]
original_cmd = container['command']

if original_cmd[0].endswith('dlv'):
    print(f"  已是 dlv exec 模式，跳过")
    sys.exit(0)

binary_name = original_cmd[0]
binary_path = f"/usr/local/bin/{binary_name}"

container['command'] = [
    '/usr/local/bin/dlv', 'exec', binary_path,
    '--headless', f'--listen=0.0.0.0:{port}',
    '--api-version=2', '--accept-multiclient',
    '--continue', '--check-go-version=false',
    '--',
] + original_cmd[1:]

# 延长探针超时（调试暂停时进程不响应）
for probe_name in ('livenessProbe', 'readinessProbe', 'startupProbe'):
    if probe_name in container:
        container[probe_name]['failureThreshold'] = 300
        container[probe_name].setdefault('initialDelaySeconds', 30)

with open(manifest_path, 'w') as f:
    yaml.dump(manifest, f, default_flow_style=False, allow_unicode=True)

print(f"  ✓ {manifest_path} 已更新为 dlv exec 模式（端口 {port}）")
PYTHON
}

patch_manifest kube-apiserver          2345
patch_manifest kube-controller-manager 2346
patch_manifest kube-scheduler          2347

info "等待组件以 dlv exec 模式重启（端口就绪）..."
for port in 2345 2346 2347; do
    for i in $(seq 1 60); do
        ss -tlnp 2>/dev/null | grep -q ":${port}" && break
        sleep 2
    done
    if ss -tlnp 2>/dev/null | grep -q ":${port}"; then
        ok "dlv 端口 ${port} 就绪"
    else
        warn "端口 ${port} 等待超时，请手动检查"
    fi
done

echo ""
ok "控制平面已进入调试模式"
echo ""
echo "连接方式："
echo "  kube-apiserver:          dlv connect localhost:2345"
echo "  kube-controller-manager: dlv connect localhost:2346"
echo "  kube-scheduler:          dlv connect localhost:2347"
