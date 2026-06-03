#!/usr/bin/env bash
# 调试 CSI Driver（通过 gRPC 模拟 NodePublishVolume 请求）
set -euo pipefail

CSI_SOCKET="${1:-/tmp/csi-debug.sock}"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[ERR ]\033[0m  $*"; exit 1; }

command -v grpcurl 2>/dev/null || die "grpcurl 未安装: go install github.com/fullstorydev/grpcurl/cmd/grpcurl@latest"

echo "断点建议 (CSI Driver Node 服务):"
echo ""
echo "  # NodePublishVolume —— 挂载卷到容器内，内部调用 mount 系统调用"
echo "  b NodePublishVolume"
echo ""
echo "  # NodeStageVolume —— 节点级预挂载（全局挂载点）"
echo "  b NodeStageVolume"
echo ""
echo "  # NodeGetCapabilities —— kubelet 探测 CSI 能力"
echo "  b NodeGetCapabilities"
echo ""

TARGET_PATH="/tmp/csi-debug-mount"
mkdir -p "$TARGET_PATH"

info "通过 grpcurl 模拟 NodePublishVolume 请求"
info "CSI Socket: $CSI_SOCKET"

grpcurl -plaintext \
    -unix \
    -d '{
      "volume_id": "debug-volume-001",
      "target_path": "'"$TARGET_PATH"'",
      "volume_capability": {
        "mount": {
          "fs_type": "ext4"
        },
        "access_mode": {
          "mode": "SINGLE_NODE_WRITER"
        }
      },
      "readonly": false
    }' \
    "$CSI_SOCKET" \
    csi.v1.Node/NodePublishVolume \
    2>&1 || warn "gRPC 调用失败（CSI Driver 是否已启动？）"

echo ""
echo "模拟其他 CSI 接口:"
echo "  # 查询节点能力"
echo "  grpcurl -plaintext -unix $CSI_SOCKET csi.v1.Node/NodeGetCapabilities"
echo ""
echo "  # 查询卷统计"
echo "  grpcurl -plaintext -unix -d '{\"volume_id\":\"...\",\"volume_path\":\"...\"}' \\"
echo "    $CSI_SOCKET csi.v1.Node/NodeGetVolumeStats"
