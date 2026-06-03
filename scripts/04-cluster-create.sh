#!/usr/bin/env bash
# 创建 Kind 调试集群并完成所有必要的配置
set -euo pipefail

CLUSTER_NAME="${1:-k8s-debug}"
KIND_NODE_IMG="${2:-kindest/node:local-debug}"
KIND_CONFIG="${3:-$(dirname "$0")/../config/kind-cluster.yaml}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[ERR ]\033[0m  $*"; exit 1; }

command -v kind   || die "Kind 未安装"
command -v docker || die "Docker 未运行"

docker image inspect "$KIND_NODE_IMG" &>/dev/null || die "节点镜像不存在: $KIND_NODE_IMG  请先运行 03-build-kind-image.sh"

if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    warn "集群 $CLUSTER_NAME 已存在"
    read -rp "是否重建？[y/N] " yn
    [[ "$yn" =~ ^[Yy]$ ]] || exit 0
    kind delete cluster --name "$CLUSTER_NAME"
fi

mkdir -p /tmp/k8s-debug-bins /tmp/k8s-debug-src

info "创建 Kind 集群: $CLUSTER_NAME"
kind create cluster \
    --name "$CLUSTER_NAME" \
    --config "$KIND_CONFIG" \
    --retain \
    --wait 0s 2>&1 || true

CONTROL_PLANE=$(kind get nodes --name "$CLUSTER_NAME" | grep control-plane | head -1)
[[ -n "$CONTROL_PLANE" ]] || die "未找到控制平面节点"

info "等待控制平面就绪..."
until kubectl get pods -n kube-system --context "kind-${CLUSTER_NAME}" 2>/dev/null | \
      grep -q "etcd.*Running"; do sleep 2; done
ok "etcd 已启动"

# ── 配置 CNI ─────────────────────────────────────────────────────────────────
info "配置 CNI 插件..."

# 检查节点内是否有 bridge 插件，若没有则安装构建好的版本
if ! docker exec "$CONTROL_PLANE" ls /opt/cni/bin/bridge &>/dev/null; then
    if [[ -f "${REPO_ROOT}/build/cni-plugins/bridge" ]]; then
        docker cp "${REPO_ROOT}/build/cni-plugins/bridge" "${CONTROL_PLANE}:/root/bridge"
        docker exec "$CONTROL_PLANE" mv /root/bridge /opt/cni/bin/bridge
        docker exec "$CONTROL_PLANE" chmod +x /opt/cni/bin/bridge
        ok "bridge CNI 插件已安装"
    else
        warn "bridge CNI 插件未找到，请先运行 02-build-cni.sh"
    fi
fi

# 应用 bridge CNI 配置
docker exec "$CONTROL_PLANE" mkdir -p /etc/cni/net.d
CNI_CONFIG="${REPO_ROOT}/config/cni-bridge-config.json"
docker cp "$CNI_CONFIG" "${CONTROL_PLANE}:/root/cni.json"
docker exec "$CONTROL_PLANE" mv /root/cni.json /etc/cni/net.d/10-k8s-debug.conflist

# 重启 containerd 以加载 CNI 配置
info "重启 containerd 加载 CNI..."
docker exec "$CONTROL_PLANE" systemctl restart containerd
until kubectl get node "$CONTROL_PLANE" --context "kind-${CLUSTER_NAME}" 2>/dev/null | \
      grep -q "Ready"; do sleep 2; done
ok "节点已 Ready（CNI 已加载）"

# ── 导入 kube-proxy 镜像 ──────────────────────────────────────────────────────
info "检查 kube-proxy 镜像..."
if ! docker exec "$CONTROL_PLANE" ctr -n k8s.io images ls 2>/dev/null | \
     grep -q "kube-proxy"; then
    if docker image inspect registry.k8s.io/kube-proxy:v1.32.0 &>/dev/null; then
        info "导入 kube-proxy 镜像到节点..."
        docker save registry.k8s.io/kube-proxy:v1.32.0 > /tmp/kube-proxy.tar
        docker cp /tmp/kube-proxy.tar "${CONTROL_PLANE}:/root/kube-proxy.tar"
        docker exec "$CONTROL_PLANE" ctr -n k8s.io images import /root/kube-proxy.tar
        docker exec "$CONTROL_PLANE" rm /root/kube-proxy.tar
        rm -f /tmp/kube-proxy.tar
        ok "kube-proxy 镜像已导入"
    else
        warn "kube-proxy 镜像不在本地，请先运行 02-build-k8s.sh 并构建 kube-proxy 镜像"
    fi
fi

# ── 安装 dlv 到节点 ───────────────────────────────────────────────────────────
info "安装 dlv 到节点..."
DLV_BIN="${GOPATH:-$HOME/go}/bin/dlv"
if [[ ! -f "$DLV_BIN" ]]; then
    info "在宿主机安装 dlv..."
    GOPATH="${GOPATH:-$HOME/go}" go install github.com/go-delve/delve/cmd/dlv@latest
fi
docker cp "$DLV_BIN" "${CONTROL_PLANE}:/root/dlv"
docker exec "$CONTROL_PLANE" mv /root/dlv /usr/local/bin/dlv
docker exec "$CONTROL_PLANE" chmod +x /usr/local/bin/dlv
ok "dlv $(docker exec "$CONTROL_PLANE" dlv version 2>/dev/null | head -1) 已安装"

ok "集群配置完成"
echo ""
kubectl get nodes --context "kind-${CLUSTER_NAME}"
echo ""
kubectl get pods -A --context "kind-${CLUSTER_NAME}"
echo ""
echo "下一步："
echo "  运行 scripts/06-setup-debug-manifests.sh 以配置 dlv 调试模式"
echo "  或直接运行 debug/all.sh 启动调试会话"
