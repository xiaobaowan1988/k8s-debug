#!/usr/bin/env bash
# 安装所有系统依赖：Docker、Kind、Delve、调试工具
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
die()   { echo -e "\033[1;31m[ERR ]\033[0m  $*"; exit 1; }

# ── 系统包 ────────────────────────────────────────────────────────────────────
info "安装系统构建依赖"
apt-get update -qq
apt-get install -y -qq \
    build-essential pkg-config libseccomp-dev libapparmor-dev libbtrfs-dev \
    libdevmapper-dev libsystemd-dev libc6-dev libgpgme-dev \
    git curl wget tar jq tmux socat conntrack iptables iproute2 \
    gdb gdb-multiarch \
    rsync unzip ca-certificates gnupg lsb-release \
    btrfs-progs
ok "系统包安装完成"

# ── Go 工具链 ─────────────────────────────────────────────────────────────────
if command -v go &>/dev/null; then
    ok "Go 已存在: $(go version)"
else
    GO_VERSION="1.24.3"
    info "安装 Go $GO_VERSION"
    curl -fsSL "https://dl.google.com/go/go${GO_VERSION}.linux-${GOARCH}.tar.gz" \
        -o /tmp/go.tar.gz
    tar -C /usr/local -xzf /tmp/go.tar.gz
    echo 'export PATH=$PATH:/usr/local/go/bin' >> /etc/profile.d/go.sh
    export PATH=$PATH:/usr/local/go/bin
    ok "Go $GO_VERSION 安装完成"
fi

export GOPATH="${GOPATH:-$HOME/go}"
export PATH="$PATH:$GOPATH/bin:/usr/local/go/bin"

# ── Delve 调试器 ─────────────────────────────────────────────────────────────
if ! command -v dlv &>/dev/null; then
    info "安装 Delve $DELVE_VERSION"
    go install "github.com/go-delve/delve/cmd/dlv@${DELVE_VERSION}"
    ok "Delve 安装完成: $(dlv version | head -1)"
else
    ok "Delve 已存在: $(dlv version | head -1)"
fi

# ── Docker ───────────────────────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
    info "安装 Docker Engine"
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker 2>/dev/null || true
    ok "Docker 安装完成"
else
    ok "Docker 已存在: $(docker version --format '{{.Server.Version}}' 2>/dev/null)"
fi

# ── Kind ─────────────────────────────────────────────────────────────────────
if ! command -v kind &>/dev/null; then
    info "安装 Kind $KIND_VERSION"
    curl -fsSL "https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}/kind-linux-${GOARCH}" \
        -o /usr/local/bin/kind
    chmod +x /usr/local/bin/kind
    ok "Kind 安装完成: $(kind version)"
else
    ok "Kind 已存在: $(kind version)"
fi

# ── kubectl ───────────────────────────────────────────────────────────────────
if ! command -v kubectl &>/dev/null; then
    info "安装 kubectl"
    K8S_VER="v1.32.0"
    curl -fsSL "https://dl.k8s.io/release/${K8S_VER}/bin/linux/${GOARCH}/kubectl" \
        -o /usr/local/bin/kubectl
    chmod +x /usr/local/bin/kubectl
    ok "kubectl 安装完成"
else
    ok "kubectl 已存在"
fi

# ── grpcurl（用于 CSI 调试）──────────────────────────────────────────────────
if ! command -v grpcurl &>/dev/null; then
    info "安装 grpcurl"
    go install github.com/fullstorydev/grpcurl/cmd/grpcurl@latest
    ok "grpcurl 安装完成"
fi

echo ""
ok "所有依赖安装完成"
go version
docker version --format 'Docker: {{.Server.Version}}' 2>/dev/null || true
kind version
kubectl version --client --short 2>/dev/null || true
dlv version | head -1
