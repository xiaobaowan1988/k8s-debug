#!/usr/bin/env bash
# 克隆 Kubernetes 源码
set -euo pipefail

K8S_SRC="${1:-$HOME/k8s-src/kubernetes}"
K8S_VERSION="${2:-v1.32.0}"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }

if [[ -d "$K8S_SRC/.git" ]]; then
    CURRENT_TAG=$(git -C "$K8S_SRC" describe --tags --exact-match 2>/dev/null || git -C "$K8S_SRC" rev-parse --short HEAD)
    if [[ "$CURRENT_TAG" == "$K8S_VERSION" ]]; then
        ok "kubernetes $K8S_VERSION 已存在，跳过克隆"
        exit 0
    fi
    info "版本不符（当前 $CURRENT_TAG），重新克隆"
    rm -rf "$K8S_SRC"
fi

mkdir -p "$(dirname "$K8S_SRC")"
info "克隆 kubernetes $K8S_VERSION"
git clone --depth=1 --branch "$K8S_VERSION" \
    https://github.com/kubernetes/kubernetes.git "$K8S_SRC"

ok "kubernetes $K8S_VERSION 克隆完成: $K8S_SRC"
