#!/usr/bin/env bash
# 将控制平面组件的静态 Pod manifest 替换为 dlv exec 版本
# 使 kube-apiserver/controller-manager/scheduler 在 dlv 调试器下运行
set -euo pipefail

CLUSTER_NAME="${1:-k8s-debug}"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[ERR ]\033[0m  $*"; exit 1; }

CONTROL_PLANE=$(kind get nodes --name "$CLUSTER_NAME" 2>/dev/null | grep control-plane | head -1)
[[ -n "$CONTROL_PLANE" ]] || die "集群 $CLUSTER_NAME 未找到控制平面节点"

docker exec "$CONTROL_PLANE" dlv version &>/dev/null || \
    die "dlv 未安装在节点，请先运行 04-cluster-create.sh"

# 修改静态 Pod manifest：在 command 列表前插入 dlv exec 命令
# 参数：组件名称、dlv 监听端口
patch_manifest() {
    local component="$1"
    local port="$2"
    local manifest="/etc/kubernetes/manifests/${component}.yaml"

    info "配置 ${component} 使用 dlv exec（端口 ${port}）..."

    docker exec "$CONTROL_PLANE" python3 - "$manifest" "$port" << 'PYTHON'
import sys, yaml

manifest_path = sys.argv[1]
port = int(sys.argv[2])

with open(manifest_path) as f:
    manifest = yaml.safe_load(f)

container = manifest['spec']['containers'][0]
original_cmd = container['command']

# 跳过已经是 dlv 的情况
if original_cmd[0].endswith('dlv'):
    print(f"已经是 dlv exec 模式，跳过")
    sys.exit(0)

binary_name = original_cmd[0]
binary_path = f"/usr/local/bin/{binary_name}"

# dlv exec 命令包装
container['command'] = [
    '/usr/local/bin/dlv', 'exec', binary_path,
    '--headless', f'--listen=0.0.0.0:{port}',
    '--api-version=2', '--accept-multiclient',
    '--continue', '--check-go-version=false',
    '--',
] + original_cmd[1:]

# 挂载 dlv 二进制
if 'volumeMounts' not in container:
    container['volumeMounts'] = []
if not any(m.get('name') == 'dlv-bin' for m in container['volumeMounts']):
    container['volumeMounts'].insert(0, {
        'mountPath': '/usr/local/bin/dlv',
        'name': 'dlv-bin',
        'readOnly': True
    })

# 延长探针超时（调试时进程可能暂停）
for probe_name in ('livenessProbe', 'readinessProbe', 'startupProbe'):
    if probe_name in container:
        container[probe_name]['failureThreshold'] = 300
        container[probe_name].setdefault('initialDelaySeconds', 30)

# 添加 dlv volume
if 'volumes' not in manifest['spec']:
    manifest['spec']['volumes'] = []
if not any(v.get('name') == 'dlv-bin' for v in manifest['spec']['volumes']):
    manifest['spec']['volumes'].insert(0, {
        'name': 'dlv-bin',
        'hostPath': {'path': '/usr/local/bin/dlv', 'type': 'File'}
    })

with open(manifest_path, 'w') as f:
    yaml.dump(manifest, f, default_flow_style=False, allow_unicode=True)

print(f"✓ {manifest_path} 已更新为 dlv exec 模式（端口 {port}）")
PYTHON
}

patch_manifest kube-apiserver         2345
patch_manifest kube-controller-manager 2346
patch_manifest kube-scheduler         2347

info "等待组件以 dlv exec 模式重启..."
for port in 2345 2346 2347; do
    until docker exec "$CONTROL_PLANE" ss -tlnp 2>/dev/null | grep -q ":${port}"; do
        sleep 2
    done
    ok "dlv 已在端口 ${port} 就绪"
done

echo ""
ok "所有控制平面组件已进入调试模式"
echo ""
echo "连接方式："
echo "  kube-apiserver:          dlv connect localhost:2345"
echo "  kube-controller-manager: dlv connect localhost:2346"
echo "  kube-scheduler:          dlv connect localhost:2347"
echo ""
echo "常用断点："
echo "  apiserver:    b k8s.io/apiserver/pkg/registry/generic/registry/store.go:446"
echo "  controller:   b k8s.io/kubernetes/pkg/controller/deployment.(*DeploymentController).syncDeployment"
echo "  scheduler:    b k8s.io/kubernetes/pkg/scheduler.(*Scheduler).scheduleOne"
