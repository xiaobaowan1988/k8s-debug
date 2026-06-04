#!/usr/bin/env bash
# 在 QEMU ARM64 VM 内安装 K8s 全链路调试前置依赖
#
# SSH 进 VM 后运行，或由 macOS 端 ssh 远程执行：
#   ssh -p 2222 root@localhost 'bash -s' < scripts/mac/10-vm-prereqs.sh
#
# 安装内容：
#   Go 1.23, dlv, git, make, gcc
#   containerd v2.0.1 (ARM64 预编译版，之后会被 debug 版替换)
#   runc v1.2.3 (同上)
#   CNI plugins v1.6.0
#   kubeadm / kubelet / kubectl v1.32
#   iptables / socat / conntrack / ethtool（K8s 依赖）
set -euo pipefail

GO_VER="1.23.4"
CONTAINERD_VER="2.0.1"
RUNC_VER="1.2.3"
CNI_VER="1.6.0"
K8S_VER="v1.32"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[ERR ]\033[0m  $*"; exit 1; }

[[ "$(uname -m)" == "aarch64" ]] || die "本脚本仅适用于 ARM64 (aarch64)"

export DEBIAN_FRONTEND=noninteractive

# ── 系统基础包 ────────────────────────────────────────────────────────────────
info "安装系统依赖..."
apt-get update -qq
apt-get install -y -qq \
    curl wget git make gcc g++ pkg-config \
    iptables ip6tables ipset iproute2 \
    socat conntrack ethtool \
    ebtables netfilter-persistent \
    libseccomp-dev libseccomp2 \
    btrfs-progs \
    gdb strace ltrace \
    linux-perf bpftrace bpfcc-tools \
    vim tmux net-tools 2>&1 | tail -3
ok "系统依赖已安装"

# ── Go ────────────────────────────────────────────────────────────────────────
if ! command -v go &>/dev/null || [[ "$(go version 2>/dev/null | grep -oP '\d+\.\d+' | head -1)" < "1.22" ]]; then
    info "安装 Go ${GO_VER} (ARM64)..."
    curl -fsSL "https://go.dev/dl/go${GO_VER}.linux-arm64.tar.gz" \
        | tar -C /usr/local -xz
    ln -sf /usr/local/go/bin/go   /usr/local/bin/go
    ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt
    ok "Go $(go version | awk '{print $3}')"
else
    ok "Go 已存在: $(go version | awk '{print $3}')"
fi

export GOPATH=/root/go
export PATH=$PATH:/usr/local/go/bin:/root/go/bin
echo 'export GOPATH=/root/go' >> /root/.bashrc
echo 'export PATH=$PATH:/usr/local/go/bin:/root/go/bin' >> /root/.bashrc

# ── dlv ───────────────────────────────────────────────────────────────────────
if ! command -v dlv &>/dev/null; then
    info "安装 dlv (Delve Go 调试器)..."
    GOPATH=/root/go go install github.com/go-delve/delve/cmd/dlv@latest
    ok "dlv $(dlv version 2>/dev/null | head -1)"
else
    ok "dlv 已存在: $(dlv version 2>/dev/null | head -1)"
fi

# ── containerd (预编译 ARM64 二进制) ──────────────────────────────────────────
if ! command -v containerd &>/dev/null; then
    info "安装 containerd v${CONTAINERD_VER} (ARM64)..."
    curl -fsSL "https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VER}/containerd-${CONTAINERD_VER}-linux-arm64.tar.gz" \
        | tar -C /usr/local -xz
    mkdir -p /etc/containerd
    containerd config default > /etc/containerd/config.toml
    # 启用 SystemdCgroup（Debian 12 默认 systemd cgroup driver）
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
    # containerd systemd service
    curl -fsSL "https://raw.githubusercontent.com/containerd/containerd/main/containerd.service" \
        -o /etc/systemd/system/containerd.service
    systemctl daemon-reload
    systemctl enable containerd
    systemctl start containerd
    ok "containerd v${CONTAINERD_VER} 已安装并启动"
else
    ok "containerd 已存在: $(containerd --version 2>/dev/null)"
fi

# ── runc ──────────────────────────────────────────────────────────────────────
if ! command -v runc &>/dev/null; then
    info "安装 runc v${RUNC_VER} (ARM64)..."
    curl -fsSL "https://github.com/opencontainers/runc/releases/download/v${RUNC_VER}/runc.arm64" \
        -o /usr/local/sbin/runc
    chmod +x /usr/local/sbin/runc
    ok "runc $(runc --version 2>/dev/null | head -1)"
else
    ok "runc 已存在: $(runc --version 2>/dev/null | head -1)"
fi

# ── CNI 插件 ──────────────────────────────────────────────────────────────────
if [[ ! -f /opt/cni/bin/bridge ]]; then
    info "安装 CNI plugins v${CNI_VER} (ARM64)..."
    mkdir -p /opt/cni/bin
    curl -fsSL "https://github.com/containernetworking/plugins/releases/download/v${CNI_VER}/cni-plugins-linux-arm64-v${CNI_VER}.tgz" \
        | tar -C /opt/cni/bin -xz
    ok "CNI 插件已安装: $(ls /opt/cni/bin | tr '\n' ' ')"
else
    ok "CNI 插件已存在"
fi

# ── kubeadm / kubelet / kubectl ───────────────────────────────────────────────
if ! command -v kubeadm &>/dev/null; then
    info "安装 kubeadm / kubelet / kubectl ${K8S_VER}..."
    mkdir -p /etc/apt/keyrings
    curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_VER}/deb/Release.key" \
        | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_VER}/deb/ /" \
        > /etc/apt/sources.list.d/kubernetes.list
    apt-get update -qq
    apt-get install -y -qq kubelet kubeadm kubectl
    apt-mark hold kubelet kubeadm kubectl
    ok "kubeadm $(kubeadm version -o short 2>/dev/null)"
else
    ok "kubeadm 已存在: $(kubeadm version -o short 2>/dev/null)"
fi

# ── 内核模块 + sysctl ─────────────────────────────────────────────────────────
info "配置内核参数（K8s 要求）..."
cat > /etc/modules-load.d/k8s.conf << 'EOF'
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

cat > /etc/sysctl.d/99-k8s.conf << 'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system -q
ok "内核参数已配置"

# ── 关闭 swap（K8s 要求）─────────────────────────────────────────────────────
swapoff -a
sed -i '/swap/d' /etc/fstab 2>/dev/null || true
ok "swap 已关闭"

echo ""
ok "VM 前置环境安装完成"
ok "  Go:        $(go version | awk '{print $3}')"
ok "  dlv:       $(/root/go/bin/dlv version 2>/dev/null | grep Version | awk '{print $2}')"
ok "  containerd: $(containerd --version 2>/dev/null | awk '{print $3}')"
ok "  kubeadm:   $(kubeadm version -o short 2>/dev/null)"
echo ""
echo "下一步: bash scripts/mac/11-vm-build.sh"
