#!/usr/bin/env bash
# 调试 etcd（切换到 host 进程 + dlv exec 模式）
# 依赖 scripts/06-setup-debug-manifests.sh 已将 etcd 切换为 host 进程
set -euo pipefail

DLV_PORT="${1:-2351}"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[ERR ]\033[0m  $*"; exit 1; }

if ! ss -tlnp 2>/dev/null | grep -q ":$DLV_PORT"; then
    warn "端口 $DLV_PORT 未监听"
    warn "请先运行: bash scripts/06-setup-debug-manifests.sh"
    exit 1
fi

echo ""
echo "断点建议 (etcd 存储层):"
echo ""
echo "  b go.etcd.io/etcd/server/v3/etcdserver.(*EtcdServer).put"
echo "  b go.etcd.io/etcd/server/v3/etcdserver.(*EtcdServer).applyEntryNormal"
echo "  b go.etcd.io/etcd/server/v3/mvcc.(*watchableStore).Put"
echo "  b go.etcd.io/etcd/server/v3/storage/mvcc.(*watchableStore).Put"
echo ""
echo "触发调试:"
echo "  kubectl create configmap etcd-test --from-literal=key=value"
echo "  kubectl get pods -A"
echo ""
echo "连接: dlv connect localhost:${DLV_PORT}"
echo ""
ok "dlv 已在 localhost:${DLV_PORT} 监听"
