#!/usr/bin/env bash
# 从源码编译 Kubernetes 所有组件（携带调试符号，禁用内联优化）
set -euo pipefail

K8S_SRC="${1:-$HOME/k8s-src/kubernetes}"
K8S_BUILD="${2:-$(dirname "$0")/../build/kubernetes}"
GOFLAGS_EXTRA="${3:-}"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[ERR ]\033[0m  $*"; exit 1; }

[[ -d "$K8S_SRC" ]] || die "kubernetes 源码目录不存在: $K8S_SRC（先运行 make clone-k8s）"

mkdir -p "$K8S_BUILD"

# K8s 1.32 go.mod 指定 go 1.23，用 GOTOOLCHAIN=local 强制使用本地 Go 避免网络下载
export GOTOOLCHAIN=local
# 使用系统默认 go（1.24.x），前向兼容 K8s 1.32
GO_BIN=$(command -v go)
GO_VER=$("$GO_BIN" version | awk '{print $3}')

info "编译 Kubernetes 组件（DBG=1，禁用内联优化）"
info "  源码:    $K8S_SRC"
info "  输出:    $K8S_BUILD"
info "  Go:      $GO_VER (GOTOOLCHAIN=local)"
info "  并行度:  $(nproc) CPU"

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

# 并行编译加速：先编译无依赖的组件，再依次完成
for comp in "${COMPONENTS[@]}"; do
    info "编译 $comp ..."
    start_ts=$(date +%s)

    # DBG=1 → -gcflags=all="-N -l"（禁止内联和逃逸优化，保留完整 DWARF）
    # KUBE_BUILD_PLATFORMS 明确指定平台避免交叉编译判断错误
    KUBE_BUILD_PLATFORMS=linux/amd64 \
    make WHAT="cmd/${comp}" DBG=1 2>&1 | tail -5

    elapsed=$(( $(date +%s) - start_ts ))
    bin_path="_output/local/bin/linux/amd64/${comp}"

    if [[ ! -f "$bin_path" ]]; then
        # K8s 有时输出路径带架构目录
        bin_path=$(find _output -name "$comp" -type f 2>/dev/null | head -1)
        [[ -n "$bin_path" ]] || die "$comp 编译失败，未找到输出文件"
    fi

    cp "$bin_path" "$K8S_BUILD/${comp}"
    ok "$comp 完成 (${elapsed}s，$(du -sh "$K8S_BUILD/$comp" | cut -f1))"
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
