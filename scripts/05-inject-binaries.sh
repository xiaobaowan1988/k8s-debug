#!/usr/bin/env bash
# 将源码编译的调试版二进制直接替换本机对应路径
# 适用于直接在 VM 上运行（无 Kind / Docker 容器）
set -euo pipefail

K8S_BUILD="${1:-$(dirname "$0")/../build/kubernetes}"
RUNTIME_BUILD="${2:-$(dirname "$0")/../build/runtime}"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[ERR ]\033[0m  $*"; exit 1; }

[[ -d "$K8S_BUILD" ]] || die "k8s 构建产物不存在: $K8S_BUILD（先运行 make build-k8s）"

inject_bin() {
    local bin_name="$1"
    local dest_path="$2"
    local src="$K8S_BUILD/$bin_name"

    [[ -f "$src" ]] || { warn "  跳过 $bin_name（本地构建产物不存在）"; return; }

    # 备份原始二进制（只备份一次）
    if [[ -f "$dest_path" ]] && [[ ! -f "${dest_path}.orig" ]]; then
        cp "$dest_path" "${dest_path}.orig"
    fi

    cp "$src" "$dest_path"
    chmod +x "$dest_path"
    local size
    size=$(stat -c %s "$dest_path" 2>/dev/null || echo "?")
    ok "  $bin_name → $dest_path  (${size} bytes)"
}

info "注入 Kubernetes 控制平面组件"
inject_bin "kube-apiserver"          /usr/local/bin/kube-apiserver
inject_bin "kube-controller-manager" /usr/local/bin/kube-controller-manager
inject_bin "kube-scheduler"          /usr/local/bin/kube-scheduler
inject_bin "kubelet"                 /usr/local/bin/kubelet
inject_bin "kube-proxy"              /usr/local/bin/kube-proxy
inject_bin "kubectl"                 /usr/local/bin/kubectl

# kubelet 还需要同步到 /usr/bin（kubeadm 默认路径）
if [[ -f "$K8S_BUILD/kubelet" ]]; then
    [[ -f /usr/bin/kubelet ]] && [[ ! -f /usr/bin/kubelet.orig ]] && \
        cp /usr/bin/kubelet /usr/bin/kubelet.orig
    cp "$K8S_BUILD/kubelet" /usr/bin/kubelet
    chmod +x /usr/bin/kubelet
fi

# ── containerd（如果已编译）──────────────────────────────────────────────────
CTD_BUILD="$RUNTIME_BUILD/containerd-bin"
if [[ -d "$CTD_BUILD" ]]; then
    info "注入 containerd 运行时"
    for bin in containerd containerd-shim-runc-v2 ctr; do
        src="$CTD_BUILD/$bin"
        [[ -f "$src" ]] || continue
        dest="/usr/local/bin/$bin"
        [[ -f "$dest" ]] && [[ ! -f "${dest}.orig" ]] && cp "$dest" "${dest}.orig"
        cp "$src" "$dest"
        chmod +x "$dest"
        ok "  $bin → $dest"
    done
fi

# ── runc（如果已编译）────────────────────────────────────────────────────────
RUNC_BIN="$RUNTIME_BUILD/runc"
if [[ -f "$RUNC_BIN" ]]; then
    info "注入 runc"
    dest=/usr/local/sbin/runc
    [[ -f "$dest" ]] && [[ ! -f "${dest}.orig" ]] && cp "$dest" "${dest}.orig"
    cp "$RUNC_BIN" "$dest"
    chmod +x "$dest"
    ok "  runc → $dest"
fi

# ── CNI 插件（如果已编译）────────────────────────────────────────────────────
CNI_OUT="$RUNTIME_BUILD/cni-plugins"
if [[ -d "$CNI_OUT" ]] && ls "$CNI_OUT"/* &>/dev/null; then
    info "注入 CNI 插件"
    mkdir -p /opt/cni/bin
    [[ ! -d /opt/cni/bin.orig ]] && cp -r /opt/cni/bin /opt/cni/bin.orig 2>/dev/null || true
    cp "$CNI_OUT"/* /opt/cni/bin/
    chmod +x /opt/cni/bin/*
    ok "  CNI 插件 → /opt/cni/bin/"
fi

# ── 触发控制平面重启（touch 静态 Pod manifests）──────────────────────────────
if [[ -d /etc/kubernetes/manifests ]]; then
    info "触发控制平面静态 Pod 重建..."
    touch /etc/kubernetes/manifests/*.yaml 2>/dev/null || true
    ok "  静态 Pod manifests 已 touch，kubelet 将自动重建"
fi

echo ""
ok "调试二进制注入完成"
echo ""
echo "已注入："
echo "  kube-apiserver, kube-controller-manager, kube-scheduler"
echo "  kubelet, kube-proxy"
[[ -d "$CTD_BUILD" ]] && echo "  containerd, containerd-shim-runc-v2"
[[ -f "$RUNC_BIN" ]] && echo "  runc"
[[ -d "$CNI_OUT" ]] && echo "  CNI: $(ls "$CNI_OUT" 2>/dev/null | tr '\n' ' ')"
echo ""
echo "下一步: make debug-all"
