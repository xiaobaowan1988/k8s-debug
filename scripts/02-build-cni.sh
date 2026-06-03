#!/usr/bin/env bash
# 从源码编译 CNI 插件（携带调试符号）
set -euo pipefail

CNI_SRC="${1:-$HOME/k8s-src/cni-plugins}"
RUNTIME_BUILD="${2:-$(dirname "$0")/../build/runtime}"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[ERR ]\033[0m  $*"; exit 1; }

[[ -d "$CNI_SRC" ]] || die "cni-plugins 源码目录不存在: $CNI_SRC"

CNI_OUT="$RUNTIME_BUILD/cni-plugins"
mkdir -p "$CNI_OUT"

cd "$CNI_SRC"

info "编译 CNI 插件（携带调试符号）"

PLUGINS=(
    plugins/main/bridge
    plugins/main/loopback
    plugins/ipam/host-local
    plugins/ipam/dhcp
    plugins/meta/portmap
    plugins/meta/bandwidth
    plugins/meta/firewall
)

for plugin_path in "${PLUGINS[@]}"; do
    plugin_name=$(basename "$plugin_path")
    CGO_ENABLED=0 go build \
        -gcflags=all="-N -l" \
        -ldflags="-extldflags=-static" \
        -o "$CNI_OUT/$plugin_name" \
        "./${plugin_path}" 2>/dev/null || { info "  跳过 $plugin_name"; continue; }
    ok "  $plugin_name"
done

ok "CNI 插件编译完成"
ls -lh "$CNI_OUT/"
echo ""
echo "调试示例:"
echo "  export CNI_COMMAND=ADD CNI_CONTAINERID=test CNI_NETNS=/var/run/netns/test CNI_IFNAME=eth0 CNI_PATH=$CNI_OUT"
echo "  dlv exec $CNI_OUT/bridge < config/cni-bridge-config.json"
