#!/usr/bin/env bash
# 注册表镜像配置脚本
# 在 Kind 节点内创建 /etc/containerd/certs.d/ 下的 hosts.toml 文件
# 绕过 Docker Hub 封锁

set -euo pipefail

CERTS_DIR="/etc/containerd/certs.d"

mkdir -p "$CERTS_DIR"

# ── Docker Hub 镜像 ───────────────────────────────────────────────────────────
mkdir -p "$CERTS_DIR/docker.io"
cat > "$CERTS_DIR/docker.io/hosts.toml" << 'EOF'
server = "https://registry-1.docker.io"

# 优先使用国内镜像加速（按响应速度排序）
[host."https://docker.m.daocloud.io"]
  capabilities = ["pull", "resolve"]

[host."https://dockerhub.azk8s.cn"]
  capabilities = ["pull", "resolve"]

[host."https://hub-mirror.c.163.com"]
  capabilities = ["pull", "resolve"]

[host."https://mirror.baidubce.com"]
  capabilities = ["pull", "resolve"]

[host."https://registry.docker-cn.com"]
  capabilities = ["pull", "resolve"]
EOF

# ── registry.k8s.io ───────────────────────────────────────────────────────────
mkdir -p "$CERTS_DIR/registry.k8s.io"
cat > "$CERTS_DIR/registry.k8s.io/hosts.toml" << 'EOF'
server = "https://registry.k8s.io"

[host."https://registry.k8s.io"]
  capabilities = ["pull", "resolve"]

# 备用：阿里云镜像（同步延迟可能存在）
[host."https://registry.aliyuncs.com/google_containers"]
  capabilities = ["pull", "resolve"]
EOF

# ── gcr.io ────────────────────────────────────────────────────────────────────
mkdir -p "$CERTS_DIR/gcr.io"
cat > "$CERTS_DIR/gcr.io/hosts.toml" << 'EOF'
server = "https://gcr.io"

[host."https://gcr.m.daocloud.io"]
  capabilities = ["pull", "resolve"]

[host."https://gcr.azk8s.cn"]
  capabilities = ["pull", "resolve"]
EOF

# ── ghcr.io ────────────────────────────────────────────────────────────────────
mkdir -p "$CERTS_DIR/ghcr.io"
cat > "$CERTS_DIR/ghcr.io/hosts.toml" << 'EOF'
server = "https://ghcr.io"

[host."https://ghcr.m.daocloud.io"]
  capabilities = ["pull", "resolve"]
EOF

# ── quay.io ────────────────────────────────────────────────────────────────────
mkdir -p "$CERTS_DIR/quay.io"
cat > "$CERTS_DIR/quay.io/hosts.toml" << 'EOF'
server = "https://quay.io"

[host."https://quay.m.daocloud.io"]
  capabilities = ["pull", "resolve"]
EOF

echo "注册表镜像配置完成: $CERTS_DIR"
ls -la "$CERTS_DIR/"
