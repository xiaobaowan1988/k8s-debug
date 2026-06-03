#!/usr/bin/env bash
# 创建 Kind 调试集群
# - 使用本地构建的节点镜像（不依赖 Docker Hub）
# - 配置 containerd 注册表镜像
# - 配置 containerd 允许 privileged + ptrace
set -euo pipefail

CLUSTER_NAME="${1:-k8s-debug}"
KIND_NODE_IMG="${2:-kindest/node:local-debug}"
KIND_CONFIG="${3:-$(dirname "$0")/../config/kind-cluster.yaml}"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[ERR ]\033[0m  $*"; exit 1; }

command -v kind || die "Kind 未安装"
command -v docker || die "Docker 未运行"

# 如果本地 debug 镜像不存在，尝试 registry.k8s.io（不需要 Docker Hub）
if ! docker image inspect "$KIND_NODE_IMG" &>/dev/null; then
    FALLBACK_IMG="registry.k8s.io/kindest/node:v1.32.0"
    warn "本地镜像 $KIND_NODE_IMG 不存在，尝试拉取 $FALLBACK_IMG"
    if docker pull "$FALLBACK_IMG" 2>/dev/null; then
        docker tag "$FALLBACK_IMG" "$KIND_NODE_IMG"
        ok "使用 $FALLBACK_IMG 作为节点镜像"
    else
        # 尝试阿里云镜像
        ALI_IMG="registry.aliyuncs.com/google_containers/kindest/node:v1.32.0"
        warn "尝试阿里云镜像: $ALI_IMG"
        if docker pull "$ALI_IMG" 2>/dev/null; then
            docker tag "$ALI_IMG" "$KIND_NODE_IMG"
            ok "使用阿里云镜像"
        else
            die "无法获取 Kind 节点镜像。请先运行 'make build-kind-image' 从源码构建"
        fi
    fi
fi

# 检查集群是否已存在
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    warn "集群 $CLUSTER_NAME 已存在"
    read -rp "是否重建？[y/N] " yn
    if [[ "$yn" =~ ^[Yy]$ ]]; then
        kind delete cluster --name "$CLUSTER_NAME"
    else
        info "保留现有集群"
        kubectl cluster-info --context "kind-${CLUSTER_NAME}" 2>/dev/null || true
        exit 0
    fi
fi

# 准备挂载目录
mkdir -p /tmp/k8s-debug-bins /tmp/k8s-debug-src

# 生成实际使用的 Kind config（替换镜像名）
ACTUAL_CONFIG="/tmp/kind-config-${CLUSTER_NAME}.yaml"
sed "s|kindest/node:local-debug|${KIND_NODE_IMG}|g" "$KIND_CONFIG" > "$ACTUAL_CONFIG"

info "创建 Kind 集群: $CLUSTER_NAME"
info "  节点镜像: $KIND_NODE_IMG"
info "  配置文件: $ACTUAL_CONFIG"

kind create cluster \
    --name "$CLUSTER_NAME" \
    --config "$ACTUAL_CONFIG" \
    --wait 120s \
    2>&1

ok "集群创建完成"

# 在每个节点配置 containerd 注册表镜像（解决 Docker Hub 被封问题）
info "配置 containerd 注册表镜像（绕过 Docker Hub）"
for node in $(kind get nodes --name "$CLUSTER_NAME"); do
    info "  配置节点: $node"

    # 创建 containerd hosts.d 配置
    docker exec "$node" bash -c '
mkdir -p /etc/containerd/certs.d/docker.io
cat > /etc/containerd/certs.d/docker.io/hosts.toml <<EOF
server = "https://registry-1.docker.io"

[host."https://docker.m.daocloud.io"]
  capabilities = ["pull", "resolve"]

[host."https://dockerhub.azk8s.cn"]
  capabilities = ["pull", "resolve"]

[host."https://hub-mirror.c.163.com"]
  capabilities = ["pull", "resolve"]

[host."https://mirror.baidubce.com"]
  capabilities = ["pull", "resolve"]
EOF

# 确保 containerd config 指向 hosts.d
mkdir -p /etc/containerd/certs.d/registry.k8s.io
cat > /etc/containerd/certs.d/registry.k8s.io/hosts.toml <<EOF
server = "https://registry.k8s.io"

[host."https://registry.k8s.io"]
  capabilities = ["pull", "resolve"]
EOF
'

    # 重启 containerd 使配置生效
    docker exec "$node" systemctl restart containerd 2>/dev/null || \
    docker exec "$node" kill -HUP "$(docker exec "$node" pgrep containerd | head -1)" 2>/dev/null || true

    ok "  节点 $node 配置完成"
done

echo ""
ok "集群就绪"
kubectl cluster-info --context "kind-${CLUSTER_NAME}"
echo ""
kubectl get nodes -o wide --context "kind-${CLUSTER_NAME}"
echo ""
echo "kubeconfig 已自动配置到 ~/.kube/config"
echo "切换上下文: kubectl config use-context kind-${CLUSTER_NAME}"
