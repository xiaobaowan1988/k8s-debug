#!/usr/bin/env bash
# 从源码编译 Kubernetes 所有组件（携带调试符号，禁用内联优化）
set -euo pipefail

K8S_SRC="${1:-$HOME/k8s-src/kubernetes}"
K8S_BUILD="${2:-$(dirname "$0")/../build/kubernetes}"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[ERR ]\033[0m  $*"; exit 1; }

[[ -d "$K8S_SRC" ]] || die "kubernetes 源码目录不存在: $K8S_SRC（先运行 make clone-k8s）"

mkdir -p "$K8S_BUILD"

info "编译 Kubernetes 组件（DBG=1，禁用内联优化）"
info "  源码: $K8S_SRC"
info "  输出: $K8S_BUILD"

cd "$K8S_SRC"

COMPONENTS=(
    kube-apiserver
    kube-controller-manager
    kube-scheduler
    kubelet
    kube-proxy
    kubectl
    kubeadm
)

for comp in "${COMPONENTS[@]}"; do
    info "编译 $comp ..."
    start_ts=$(date +%s)

    # DBG=1 使 k8s Makefile 自动添加 -gcflags=all="-N -l"（禁止内联和优化）
    make WHAT="cmd/${comp}" DBG=1 2>&1 | tail -3

    elapsed=$(( $(date +%s) - start_ts ))
    bin_path="_output/local/bin/linux/amd64/${comp}"
    [[ -f "$bin_path" ]] || die "$comp 编译失败"

    cp "$bin_path" "$K8S_BUILD/${comp}"
    ok "$comp 完成 (${elapsed}s)"
done

# pause 容器程序
if [[ -f "build/pause/pause.c" ]]; then
    info "编译 pause"
    gcc -O2 -static -o "$K8S_BUILD/pause" build/pause/pause.c
    ok "pause 完成"
fi

echo ""
ok "所有组件编译完成"
ls -lh "$K8S_BUILD/"
echo ""
echo "验证调试符号（应显示 'not stripped'）:"
file "$K8S_BUILD/kube-apiserver"
