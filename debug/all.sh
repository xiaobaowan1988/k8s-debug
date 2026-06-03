#!/usr/bin/env bash
# 终极全链路调试：一键开启所有组件的 dlv 调试会话（tmux）
set -euo pipefail

SESSION="k8s-debug"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[ERR ]\033[0m  $*"; exit 1; }

command -v tmux || die "tmux 未安装: apt-get install tmux"

SCRIPT_DIR="$(dirname "$0")"

tmux kill-session -t "$SESSION" 2>/dev/null || true

info "创建全链路调试 tmux 会话: $SESSION"

# 窗口0: kubectl 监控
tmux new-session -d -s "$SESSION" -n "overview" -x 220 -y 50
tmux send-keys -t "${SESSION}:overview" \
    "watch -n 1 'kubectl get pods -A 2>/dev/null | head -30'" Enter

# 窗口1: kube-apiserver
tmux new-window -t "$SESSION" -n "apiserver"
tmux send-keys -t "${SESSION}:apiserver" \
    "bash ${SCRIPT_DIR}/apiserver.sh 2345" Enter

# 窗口2: kube-controller-manager
tmux new-window -t "$SESSION" -n "controller"
tmux send-keys -t "${SESSION}:controller" \
    "bash ${SCRIPT_DIR}/controller-manager.sh 2346" Enter

# 窗口3: kube-scheduler
tmux new-window -t "$SESSION" -n "scheduler"
tmux send-keys -t "${SESSION}:scheduler" \
    "bash ${SCRIPT_DIR}/scheduler.sh 2347" Enter

# 窗口4: kubelet
tmux new-window -t "$SESSION" -n "kubelet"
tmux send-keys -t "${SESSION}:kubelet" \
    "bash ${SCRIPT_DIR}/kubelet.sh 2348" Enter

# 窗口5: kube-proxy
tmux new-window -t "$SESSION" -n "proxy"
tmux send-keys -t "${SESSION}:proxy" \
    "bash ${SCRIPT_DIR}/kube-proxy.sh 2349" Enter

# 窗口6: containerd
tmux new-window -t "$SESSION" -n "containerd"
tmux send-keys -t "${SESSION}:containerd" \
    "bash ${SCRIPT_DIR}/containerd.sh 2350" Enter

# 窗口7: 触发终端
tmux new-window -t "$SESSION" -n "trigger"
tmux send-keys -t "${SESSION}:trigger" "echo '
═══════════════════════════════════════════════════════
  全链路调试就绪（直接运行在 VM 上）
  在各 dlv 连接会话中设置好断点后，执行：
═══════════════════════════════════════════════════════

  kubectl create deployment chain-test --image=nginx:alpine

  预期断点触发顺序：
    apiserver:2345  → 准入控制 + etcd 写入
    controller:2346 → Deployment→ReplicaSet→Pod 展开
    scheduler:2347  → scheduleOne + 过滤打分
    kubelet:2348    → SyncPod + startContainer
    proxy:2349      → syncProxyRules（如有 Service）
    containerd:2350 → RunPodSandbox + CreateContainer
'" Enter

ok "tmux 会话 '$SESSION' 已创建"
echo ""
echo "进入会话: tmux attach-session -t $SESSION"
echo ""
echo "tmux 快捷键:"
echo "  Ctrl+b n/p  → 切换窗口"
echo "  Ctrl+b 0-7  → 直接跳转"
echo "  Ctrl+b d    → 退出但保留会话"
echo ""

if [[ -n "${TMUX:-}" ]]; then
    tmux switch-client -t "$SESSION"
else
    tmux attach-session -t "$SESSION"
fi
