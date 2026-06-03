#!/usr/bin/env bash
# 调试 CNI 插件（bridge / host-local）
# 策略：伪造 CNI 环境变量，直接用 dlv exec 运行，无需启动集群
set -euo pipefail

CNI_BUILD="${1:-$(dirname "$0")/../build/runtime/cni-plugins}"
PLUGIN="${2:-bridge}"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[ERR ]\033[0m  $*"; exit 1; }

CNI_BIN="$CNI_BUILD/$PLUGIN"
[[ -f "$CNI_BIN" ]] || die "CNI 插件不存在: $CNI_BIN（先运行 make build-cni）"

CNI_NS="/var/run/netns/cni-debug-test"

info "准备 CNI 调试环境"

# 创建测试 netns
ip netns add cni-debug-test 2>/dev/null || true
ok "测试 netns: $CNI_NS"

# 生成 bridge CNI 配置
CNI_CONFIG_FILE="/tmp/cni-debug-config.json"
cat > "$CNI_CONFIG_FILE" << 'EOF'
{
  "cniVersion": "1.0.0",
  "name": "cni-debug-net",
  "type": "bridge",
  "bridge": "cni-debug0",
  "isGateway": true,
  "ipMasq": true,
  "ipam": {
    "type": "host-local",
    "ranges": [
      [{"subnet": "10.88.0.0/16"}]
    ],
    "routes": [
      {"dst": "0.0.0.0/0"}
    ]
  }
}
EOF

ok "CNI 配置已生成: $CNI_CONFIG_FILE"

echo ""
echo "断点建议 (bridge CNI):"
echo ""
echo "  # cmdAdd —— CNI ADD 操作入口（分配 IP、创建 veth pair）"
echo "  b main.cmdAdd"
echo ""
echo "  # setupBridge —— 创建 Linux bridge 设备"
echo "  b github.com/containernetworking/plugins/plugins/main/bridge.setupBridge"
echo ""
echo "  # setupVeth —— 创建 veth pair 并移入容器 netns"
echo "  b github.com/containernetworking/plugins/plugins/main/bridge.setupVeth"
echo ""
echo "  # host-local IPAM —— IP 分配逻辑"
echo "  b github.com/containernetworking/plugins/plugins/ipam/host-local.cmdAdd"
echo ""
echo "观察 netlink 调用（内核 veth 创建）："
echo "  strace -f -e trace=network,clone dlv exec $CNI_BIN < $CNI_CONFIG_FILE"
echo ""

# 设置 CNI 环境变量
export CNI_COMMAND=ADD
export CNI_CONTAINERID="debug-container-$(date +%s)"
export CNI_NETNS="$CNI_NS"
export CNI_IFNAME="eth0"
export CNI_PATH="$CNI_BUILD"

info "启动 dlv exec $PLUGIN"
info "环境变量:"
echo "  CNI_COMMAND=$CNI_COMMAND"
echo "  CNI_CONTAINERID=$CNI_CONTAINERID"
echo "  CNI_NETNS=$CNI_NETNS"
echo "  CNI_IFNAME=$CNI_IFNAME"
echo "  CNI_PATH=$CNI_PATH"
echo ""

dlv exec "$CNI_BIN" \
    --headless=false \
    --api-version=2 \
    -- < "$CNI_CONFIG_FILE"

# 清理
ip netns del cni-debug-test 2>/dev/null || true
ip link del cni-debug0 2>/dev/null || true
