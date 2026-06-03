#!/usr/bin/env bash
# 安装所有系统依赖：kubeadm、kubelet、kubectl、containerd、Delve、调试工具
set -euo pipefail

DELVE_VERSION="${DELVE_VERSION:-v1.23.1}"
K8S_VERSION="${K8S_VERSION:-1.32.0}"
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
    rsync unzip ca-certificates gnupg lsb-release apt-transport-https \
    btrfs-progs ethtool
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

# ── kubeadm / kubelet / kubectl（来自 k8s apt 仓库）──────────────────────────
if ! command -v kubeadm &>/dev/null; then
    info "安装 kubeadm / kubelet / kubectl v${K8S_VERSION}"
    mkdir -p /etc/apt/keyrings
    curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION%.*}/deb/Release.key" \
        | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION%.*}/deb/ /" \
        > /etc/apt/sources.list.d/kubernetes.list
    apt-get update -qq
    apt-get install -y -qq \
        "kubelet=${K8S_VERSION}-*" \
        "kubeadm=${K8S_VERSION}-*" \
        "kubectl=${K8S_VERSION}-*"
    apt-mark hold kubelet kubeadm kubectl
    ok "kubeadm/kubelet/kubectl ${K8S_VERSION} 安装完成"
else
    ok "kubeadm 已存在: $(kubeadm version --output short 2>/dev/null || kubeadm version)"
fi

# ── containerd（若未安装则安装；已有则保留）──────────────────────────────────
if ! command -v containerd &>/dev/null; then
    info "安装 containerd"
    CONTAINERD_VERSION="2.0.1"
    curl -fsSL "https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-linux-${GOARCH}.tar.gz" \
        -o /tmp/containerd.tar.gz
    tar -C /usr/local -xzf /tmp/containerd.tar.gz
    ok "containerd ${CONTAINERD_VERSION} 安装完成"
else
    ok "containerd 已存在: $(containerd --version)"
fi

# ── runc（若未安装则安装）────────────────────────────────────────────────────
if ! command -v runc &>/dev/null; then
    info "安装 runc"
    RUNC_VERSION="1.2.3"
    curl -fsSL "https://github.com/opencontainers/runc/releases/download/v${RUNC_VERSION}/runc.${GOARCH}" \
        -o /usr/local/sbin/runc
    chmod +x /usr/local/sbin/runc
    ok "runc ${RUNC_VERSION} 安装完成"
else
    ok "runc 已存在: $(runc --version | head -1)"
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
containerd --version
runc --version | head -1
kubeadm version --output short 2>/dev/null || true
kubectl version --client --short 2>/dev/null || true
dlv version | head -1
