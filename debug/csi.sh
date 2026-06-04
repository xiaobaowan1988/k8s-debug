#!/usr/bin/env bash
# 调试 CSI hostpath driver（host 进程 + dlv exec 模式）
#
# 前置：
#   bash scripts/01-clone-csi-hostpath.sh
#   bash scripts/02-build-csi-hostpath.sh
#   kubectl apply -f deploy/csi-hostpath/csi-hostpath.yaml
#
# 触发（另开终端）：
#   kubectl apply -f deploy/csi-hostpath/test-pvc.yaml
set -euo pipefail

DLV_PORT="${1:-2353}"
CSI_BIN="${CSI_BIN:-/usr/local/bin/csi-hostpathplugin}"
CSI_SOCK_DIR="/var/lib/kubelet/plugins/hostpath.csi.k8s.io"
CSI_SOCK="unix://${CSI_SOCK_DIR}/csi.sock"
CSI_DATA_DIR="/var/lib/csi-hostpath-data"
DLV=/usr/local/bin/dlv
LOG=/tmp/dlv-csi-hostpath.log

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[ERR ]\033[0m  $*"; exit 1; }

[[ -f "$CSI_BIN" ]] || die "$CSI_BIN 不存在（先运行 bash scripts/02-build-csi-hostpath.sh && sudo cp build/runtime/csi-hostpathplugin /usr/local/bin/）"
[[ -f "$DLV" ]]     || die "dlv 不在 $DLV"

has_dwarf=$(readelf -S "$CSI_BIN" 2>/dev/null | grep -c "\.debug_info" || true)
[[ "$has_dwarf" -gt 0 ]] || warn "$CSI_BIN 无 DWARF 符号"

mkdir -p "$CSI_SOCK_DIR" "$CSI_DATA_DIR"

# 停旧进程
pkill -f "dlv exec.*csi-hostpathplugin" 2>/dev/null || true
pkill -x csi-hostpathplugin             2>/dev/null || true
rm -f "${CSI_SOCK_DIR}/csi.sock"
sleep 1

echo ""
echo "断点建议 (CSI hostpath driver):"
echo ""
echo "  # CreateVolume —— PVC 创建时 external-provisioner 触发"
echo "  b github.com/kubernetes-csi/csi-driver-host-path/pkg/hostpath.(*hostPath).CreateVolume"
echo ""
echo "  # NodePublishVolume —— kubelet 将 volume mount 到 Pod 时触发"
echo "  b github.com/kubernetes-csi/csi-driver-host-path/pkg/hostpath.(*hostPath).NodePublishVolume"
echo ""
echo "  # NodeStageVolume —— kubelet 全局 mount（staging）时触发"
echo "  b github.com/kubernetes-csi/csi-driver-host-path/pkg/hostpath.(*hostPath).NodeStageVolume"
echo ""
echo "触发:"
echo "  kubectl apply -f deploy/csi-hostpath/test-pvc.yaml"
echo ""
echo "连接: dlv connect localhost:${DLV_PORT}"
echo ""

info "启动 csi-hostpathplugin (dlv exec, port ${DLV_PORT})..."

nohup "$DLV" exec "$CSI_BIN" \
    --headless \
    --listen="0.0.0.0:${DLV_PORT}" \
    --api-version=2 \
    --accept-multiclient \
    --continue \
    --check-go-version=false \
    -- \
    --drivername=hostpath.csi.k8s.io \
    --endpoint="$CSI_SOCK" \
    --nodeid="$(hostname)" \
    --statedir="$CSI_DATA_DIR" \
    --v=5 \
    > "$LOG" 2>&1 &
disown

sleep 3
if ss -tlnp 2>/dev/null | grep -q ":${DLV_PORT}"; then
    ok "dlv 已在 localhost:${DLV_PORT} 监听"
    ok "CSI socket: ${CSI_SOCK_DIR}/csi.sock"
    ok "数据目录:   ${CSI_DATA_DIR}"
    ok "日志:       $LOG"
else
    warn "dlv 未启动，查看日志:"
    tail -20 "$LOG" 2>/dev/null || true
    exit 1
fi
