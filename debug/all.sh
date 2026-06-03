#!/usr/bin/env bash
# 终极全链路调试：一键开启所有组件的 dlv 调试会话
# 使用 tmux 创建多个窗格，每个组件一个终端
set -euo pipefail

CLUSTER_NAME="${1:-k8s-debug}"
SESSION="k8s-debug"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[ERR ]\033[0m  $*"; exit 1; }

command -v tmux || die "tmux 未安装: apt-get install tmux"

SCRIPT_DIR="$(dirname "$0")"

# 杀死已有 session
tmux kill-session -t "$SESSION" 2>/dev/null || true

info "创建全链路调试 tmux 会话: $SESSION"

# 创建 session，第一个窗格是 kubectl 监控
tmux new-session -d -s "$SESSION" -n "overview" -x 220 -y 50

# 窗口0: 概览 / kubectl 监控
tmux send-keys -t "${SESSION}:overview" "
watch -n 1 'kubectl get pods -A --context kind-${CLUSTER_NAME} 2>/dev/null | head -30'
" Enter

# 窗口1: kube-apiserver 调试
tmux new-window -t "$SESSION" -n "apiserver"
tmux send-keys -t "${SESSION}:apiserver" "
bash ${SCRIPT_DIR}/apiserver.sh ${CLUSTER_NAME} 2345
echo '---'
echo '连接命令: dlv connect localhost:2345'
echo '核心断点: b k8s.io/apiserver/pkg/registry/generic/registry/store.go:370'
" Enter

# 窗口2: kube-controller-manager 调试
tmux new-window -t "$SESSION" -n "controller"
tmux send-keys -t "${SESSION}:controller" "
bash ${SCRIPT_DIR}/controller-manager.sh ${CLUSTER_NAME} 2346
echo '---'
echo '连接命令: dlv connect localhost:2346'
echo '核心断点: b k8s.io/kubernetes/pkg/controller/deployment.(*DeploymentController).syncDeployment'
" Enter

# 窗口3: kube-scheduler 调试
tmux new-window -t "$SESSION" -n "scheduler"
tmux send-keys -t "${SESSION}:scheduler" "
bash ${SCRIPT_DIR}/scheduler.sh ${CLUSTER_NAME} 2347
echo '---'
echo '连接命令: dlv connect localhost:2347'
echo '核心断点: b k8s.io/kubernetes/pkg/scheduler.(*Scheduler).scheduleOne'
" Enter

# 窗口4: kubelet 调试
tmux new-window -t "$SESSION" -n "kubelet"
tmux send-keys -t "${SESSION}:kubelet" "
bash ${SCRIPT_DIR}/kubelet.sh ${CLUSTER_NAME} 2348
echo '---'
echo '连接命令: dlv connect localhost:2348'
echo '核心断点: b k8s.io/kubernetes/pkg/kubelet/kuberuntime.(*kubeGenericRuntimeManager).SyncPod'
" Enter

# 窗口5: kube-proxy 调试
tmux new-window -t "$SESSION" -n "proxy"
tmux send-keys -t "${SESSION}:proxy" "
bash ${SCRIPT_DIR}/kube-proxy.sh ${CLUSTER_NAME} 2349
echo '---'
echo '连接命令: dlv connect localhost:2349'
echo '核心断点: b k8s.io/kubernetes/pkg/proxy/iptables.(*Proxier).syncProxyRules'
" Enter

# 窗口6: containerd 调试
tmux new-window -t "$SESSION" -n "containerd"
tmux send-keys -t "${SESSION}:containerd" "
bash ${SCRIPT_DIR}/containerd.sh ${CLUSTER_NAME} 2350
echo '---'
echo '连接命令: dlv connect localhost:2350'
echo '核心断点: b github.com/containerd/containerd/pkg/cri/server.(*criService).RunPodSandbox'
" Enter

# 窗口7: 触发全链路的终端
tmux new-window -t "$SESSION" -n "trigger"
tmux send-keys -t "${SESSION}:trigger" "
echo '═══════════════════════════════════════════════════════'
echo '  全链路调试就绪'
echo '  在各 dlv 连接会话中设置好断点后，执行以下命令触发：'
echo '═══════════════════════════════════════════════════════'
echo ''
echo '  kubectl create deployment chain-test --image=nginx:alpine --context kind-${CLUSTER_NAME}'
echo ''
echo '  预期断点触发顺序：'
echo '    apiserver:2345  → 准入控制 + etcd 写入'
echo '    controller:2346 → Deployment→ReplicaSet→Pod 展开'
echo '    scheduler:2347  → scheduleOne + 过滤打分'
echo '    kubelet:2348    → SyncPod + startContainer'
echo '    proxy:2349      → syncProxyRules（如有 Service）'
echo '    containerd:2350 → RunPodSandbox + CreateContainer'
echo ''
" Enter

ok "tmux 会话 '$SESSION' 已创建"
echo ""
echo "进入会话: tmux attach-session -t $SESSION"
echo ""
echo "tmux 快捷键:"
echo "  Ctrl+b n  → 切换到下一个窗口"
echo "  Ctrl+b p  → 切换到上一个窗口"
echo "  Ctrl+b 0-7 → 直接跳转到指定窗口"
echo "  Ctrl+b d  → 退出但保留会话"
echo ""

# 尝试自动 attach
if [[ -n "${TMUX:-}" ]]; then
    info "已在 tmux 内，切换到调试 session"
    tmux switch-client -t "$SESSION"
else
    tmux attach-session -t "$SESSION"
fi
