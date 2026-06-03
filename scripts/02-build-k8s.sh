#!/usr/bin/env bash
# 从源码编译 Kubernetes 所有控制平面和节点组件（携带调试符号，禁用内联优化）
set -euo pipefail

K8S_SRC="${1:-$HOME/k8s-src/kubernetes}"
K8S_BUILD="${2:-$(dirname "$0")/../build/kubernetes}"
GOFLAGS_DEBUG="${3:--gcflags=all=-N -l}"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[ERR ]\033[0m  $*"; exit 1; }

[[ -d "$K8S_SRC" ]] || die "kubernetes 源码目录不存在: $K8S_SRC（先运行 make clone-k8s）"

# 配置 Go 模块代理（绕过网络限制）
export GOPROXY="${GOPROXY:-https://goproxy.cn,https://goproxy.io,direct}"
export GONOSUMCHECK="*"
export GOFLAGS=""

# DBG=1 让 k8s Makefile 使用 -gcflags=all="-N -l"
export DBG=1
export KUBE_CGO_OVERRIDES=""

mkdir -p "$K8S_BUILD"

info "开始编译 Kubernetes 组件（DBG=1, 禁用内联优化）"
info "源码: $K8S_SRC"
info "输出: $K8S_BUILD"
info "GOPROXY: $GOPROXY"

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

    # 使用 DBG=1 触发 k8s 官方 Makefile 的 debug 编译路径
    make WHAT="cmd/${comp}" DBG=1 2>&1 | tail -5

    end_ts=$(date +%s)
    elapsed=$((end_ts - start_ts))

    bin_path="_output/local/bin/linux/amd64/${comp}"
    [[ -f "$bin_path" ]] || die "$comp 编译失败，产物不存在"

    cp "$bin_path" "$K8S_BUILD/${comp}"
    ok "$comp 编译完成 (${elapsed}s) → $K8S_BUILD/${comp}"
done

# pause 镜像需要单独构建，用于 Kind 节点
info "编译 pause 容器程序"
if [[ -f "build/pause/pause.c" ]]; then
    gcc -O2 -static -o "$K8S_BUILD/pause" build/pause/pause.c
    ok "pause 编译完成"
fi

echo ""
ok "所有 Kubernetes 组件编译完成"
ls -lh "$K8S_BUILD/"
echo ""
echo "验证调试符号（应看到 DWARF 信息）:"
file "$K8S_BUILD/kube-apiserver" | grep -o "not stripped" || \
    echo "  警告: kube-apiserver 可能被 strip 了，调试符号缺失"
