#!/usr/bin/env bash
# 安装所有系统依赖：Go 工具链、Docker、Kind、Delve、调试工具
set -euo pipefail

DELVE_VERSION="${DELVE_VERSION:-v1.23.1}"
KIND_VERSION="${KIND_VERSION:-v0.26.0}"
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  GOARCH=amd64 ;;
  aarch64) GOARCH=arm64 ;;
  *)       echo "不支持的架构: $ARCH"; exit 1 ;;
esac

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[ERR ]\033[0m  $*"; exit 1; }

# ── 系统包 ────────────────────────────────────────────────────────────────────
info "安装系统构建依赖"
apt-get update -qq
apt-get install -y -qq \
    build-essential pkg-config libseccomp-dev libapparmor-dev libbtrfs-dev \
    libdevmapper-dev libsystemd-dev libc6-dev libgpgme-dev \
    git curl wget tar jq tmux socat conntrack iptables iproute2 \
    gdb gdb-multiarch qemu-user-static \
    rsync unzip ca-certificates gnupg lsb-release \
    btrfs-progs \
    2>/dev/null

ok "系统包安装完成"

# ── Go 工具链（复用已有 or 安装）─────────────────────────────────────────────
GO_MIN="1.22"
if command -v go &>/dev/null; then
    GOVER=$(go version | awk '{print $3}' | sed 's/go//')
    info "检测到 Go $GOVER"
else
    GO_VERSION="1.24.3"
    info "安装 Go $GO_VERSION"
    # 优先从 Go 官方镜像（不依赖 Docker Hub）
    for mirror in \
        "https://golang.google.cn/dl" \
        "https://mirrors.aliyun.com/golang" \
        "https://dl.google.com/go"; do
        url="${mirror}/go${GO_VERSION}.linux-${GOARCH}.tar.gz"
        if curl -fsSL --connect-timeout 10 "$url" -o /tmp/go.tar.gz 2>/dev/null; then
            break
        fi
        warn "镜像 $mirror 不可用，尝试下一个"
    done
    tar -C /usr/local -xzf /tmp/go.tar.gz
    echo 'export PATH=$PATH:/usr/local/go/bin' >> /etc/profile.d/go.sh
    export PATH=$PATH:/usr/local/go/bin
fi

export GOPATH="${GOPATH:-$HOME/go}"
export PATH="$PATH:$GOPATH/bin:/usr/local/go/bin"

# ── Delve 调试器 ─────────────────────────────────────────────────────────────
if ! command -v dlv &>/dev/null; then
    info "安装 Delve $DELVE_VERSION"
    GOFLAGS="" go install "github.com/go-delve/delve/cmd/dlv@${DELVE_VERSION}"
    ok "Delve 安装完成: $(dlv version | head -1)"
else
    ok "Delve 已存在: $(dlv version | head -1)"
fi

# ── Docker ───────────────────────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
    info "安装 Docker Engine"
    # 使用阿里云镜像源（不依赖 Docker Hub / apt.docker.com）
    curl -fsSL https://mirrors.aliyun.com/docker-ce/linux/ubuntu/gpg \
        | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    DISTRO=$(lsb_release -cs)
    echo "deb [arch=${GOARCH} signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] \
https://mirrors.aliyun.com/docker-ce/linux/ubuntu ${DISTRO} stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io
    systemctl enable --now docker 2>/dev/null || true
    ok "Docker 安装完成"
else
    ok "Docker 已存在: $(docker version --format '{{.Server.Version}}' 2>/dev/null)"
fi

# 配置 Docker 镜像加速（绕过 Docker Hub 封锁）
DOCKER_CFG_DIR=/etc/docker
mkdir -p "$DOCKER_CFG_DIR"
cat > "$DOCKER_CFG_DIR/daemon.json" <<'EOF'
{
  "registry-mirrors": [
    "https://dockerhub.azk8s.cn",
    "https://docker.m.daocloud.io",
    "https://registry.docker-cn.com",
    "https://mirror.baidubce.com",
    "https://hub-mirror.c.163.com"
  ],
  "exec-opts": ["native.cgroupdriver=cgroupfs"],
  "log-driver": "json-file",
  "log-opts": {"max-size": "100m"},
  "storage-driver": "overlay2"
}
EOF
systemctl reload docker 2>/dev/null || true
ok "Docker 镜像加速已配置"

# ── Kind ─────────────────────────────────────────────────────────────────────
if ! command -v kind &>/dev/null; then
    info "安装 Kind $KIND_VERSION"
    for base in \
        "https://ghproxy.com/https://github.com/kubernetes-sigs/kind/releases/download" \
        "https://github.com/kubernetes-sigs/kind/releases/download"; do
        url="${base}/${KIND_VERSION}/kind-linux-${GOARCH}"
        if curl -fsSL --connect-timeout 15 "$url" -o /usr/local/bin/kind 2>/dev/null; then
            chmod +x /usr/local/bin/kind
            ok "Kind 安装完成: $(kind version)"
            break
        fi
        warn "$base 不可用"
    done
else
    ok "Kind 已存在: $(kind version)"
fi

# ── kubectl ───────────────────────────────────────────────────────────────────
if ! command -v kubectl &>/dev/null; then
    info "安装 kubectl"
    K8S_VER="v1.32.0"
    for base in \
        "https://storage.googleapis.com/kubernetes-release/release" \
        "https://mirrors.aliyun.com/kubernetes/kubectl/${K8S_VER}/bin/linux/${GOARCH}"; do
        url="${base}/${K8S_VER}/bin/linux/${GOARCH}/kubectl"
        if curl -fsSL --connect-timeout 15 "$url" -o /usr/local/bin/kubectl 2>/dev/null; then
            chmod +x /usr/local/bin/kubectl
            ok "kubectl 安装完成"
            break
        fi
    done
else
    ok "kubectl 已存在: $(kubectl version --client -o json 2>/dev/null | jq -r '.clientVersion.gitVersion' 2>/dev/null)"
fi

# ── grpcurl（用于 CSI 调试）──────────────────────────────────────────────────
if ! command -v grpcurl &>/dev/null; then
    info "安装 grpcurl"
    GOFLAGS="" go install github.com/fullstorydev/grpcurl/cmd/grpcurl@latest 2>/dev/null || \
        warn "grpcurl 安装失败，CSI gRPC 调试时可手动安装"
fi

echo ""
ok "所有依赖安装完成"
echo "  Go:      $(go version 2>/dev/null)"
echo "  Docker:  $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '需要启动 Docker daemon')"
echo "  Kind:    $(kind version 2>/dev/null)"
echo "  kubectl: $(kubectl version --client --short 2>/dev/null || echo 'n/a')"
echo "  Delve:   $(dlv version 2>/dev/null | head -1)"
