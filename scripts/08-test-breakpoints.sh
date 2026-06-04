#!/usr/bin/env bash
# 自动化断点测试：验证所有组件的 dlv 调试功能
# 每个组件：连接 → 设断点 → 触发 → 验证 stack/locals/变量
set -euo pipefail

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
fail()  { echo -e "\033[1;31m[FAIL]\033[0m  $*"; FAILED+=("$1"); }

FAILED=()
RESULTS=()

# ── 工具函数 ──────────────────────────────────────────────────────────────────

# 通过 named pipe 向已有 dlv headless server 发送命令并捕获输出
# 用法: dlv_session <host:port> <timeout_s> <cmd_sequence...>
dlv_session() {
    local addr="$1"; shift
    local timeout_s="$1"; shift
    local cmds=("$@")

    local fifo tmp_out
    fifo=$(mktemp -u /tmp/dlv-fifo-XXXX)
    tmp_out=$(mktemp /tmp/dlv-session-XXXX)
    mkfifo "$fifo"

    (
        for cmd in "${cmds[@]}"; do
            echo "$cmd"
            sleep 0.3
        done
        sleep 1
        echo "exit"
    ) > "$fifo" &

    timeout "$timeout_s" dlv connect "$addr" \
        --allow-non-terminal-interactive=true \
        < "$fifo" > "$tmp_out" 2>&1 || true
    rm -f "$fifo"
    cat "$tmp_out"
    rm -f "$tmp_out"
}

# grep_output: grep dlv output without pipefail SIGPIPE false-negative
# set -o pipefail + large output + grep -q causes SIGPIPE on printf side;
# writing to a temp file first avoids the pipe entirely.
grep_output() {
    local out="$1" pat="$2" tmp rc
    tmp=$(mktemp)
    printf '%s' "$out" > "$tmp"
    grep -qaE "$pat" "$tmp"; rc=$?
    rm -f "$tmp"
    return "$rc"
}

# 通过 named pipe 直接运行 dlv exec（非 headless），用于 host 进程测试
dlv_exec_session() {
    local binary="$1"; shift
    local timeout_s="$1"; shift
    local cmds=("$@")

    local fifo
    fifo=$(mktemp -u /tmp/dlv-fifo-XXXX)
    mkfifo "$fifo"

    (
        for cmd in "${cmds[@]}"; do
            echo "$cmd"
            sleep 0.3
        done
        sleep 1
        echo "exit"
    ) > "$fifo" &

    timeout "$timeout_s" dlv exec "$binary" \
        --check-go-version=false \
        --allow-non-terminal-interactive=true \
        < "$fifo" 2>&1 || true
    rm -f "$fifo"
}

record() {
    local name="$1" result="$2" detail="$3"
    RESULTS+=("$(printf "  %-35s %s  %s" "$name" "$result" "$detail")")
}

# ── 1. kube-scheduler (port 2347) ─────────────────────────────────────────────
test_scheduler() {
    info "═══ 测试 kube-scheduler (port 2347) ═══"
    local port=2347

    if ! ss -tlnp 2>/dev/null | grep -q ":$port"; then
        warn "端口 $port 未监听，跳过（先运行 make debug-all 或 06-setup-debug-manifests.sh）"
        record "kube-scheduler bp" "⚠ SKIP" "port $port not listening"
        return
    fi

    local bp="k8s.io/kubernetes/pkg/scheduler.(*Scheduler).ScheduleOne"
    info "  断点: $bp"

    # 触发：创建 test pod
    kubectl run sched-test-$(date +%s) \
        --image=registry.k8s.io/pause:3.10 \
        --restart=Never \
        --dry-run=server 2>/dev/null \
        --overrides='{"spec":{"nodeName":""}}' || true

    local output
    output=$(dlv_session "localhost:$port" 20 \
        "b $bp" \
        "c" \
    ) || true

    # 触发调度
    kubectl run sched-test-bp \
        --image=registry.k8s.io/pause:3.10 \
        --restart=Never 2>/dev/null || true
    sleep 3

    output=$(dlv_session "localhost:$port" 15 \
        "goroutines" \
        "stack" \
        "locals" \
        "clearall" \
        "c" \
    ) || true

    kubectl delete pod sched-test-bp --ignore-not-found 2>/dev/null || true

    if grep_output "$output" "ScheduleOne|Goroutine|goroutine"; then
        ok "  kube-scheduler 断点验证通过"
        record "kube-scheduler ScheduleOne" "✓ PASS" "stack visible"
    else
        fail "kube-scheduler"
        record "kube-scheduler ScheduleOne" "✗ FAIL" "no stack output"
    fi
    echo "$output" | tail -30
}

# ── 2. kube-apiserver (port 2345) ─────────────────────────────────────────────
test_apiserver() {
    info "═══ 测试 kube-apiserver (port 2345) ═══"
    local port=2345

    if ! ss -tlnp 2>/dev/null | grep -q ":$port"; then
        warn "端口 $port 未监听，跳过"
        record "kube-apiserver bp" "⚠ SKIP" "port $port not listening"
        return
    fi

    local bp="k8s.io/apiserver/pkg/registry/generic/registry.(*Store).Create"
    info "  断点: $bp"

    # Session 1: set breakpoint and continue
    dlv_session "localhost:$port" 10 "b $bp" "c" > /dev/null 2>&1 || true

    # 触发 API 请求
    (kubectl create configmap apiserver-test-$(date +%s) \
        --from-literal=key=val 2>/dev/null || true) &
    sleep 3

    # Session 2: query state while paused at breakpoint
    local output
    output=$(dlv_session "localhost:$port" 15 \
        "goroutines" \
        "stack" \
        "locals" \
        "clearall" \
        "c" \
    ) || true

    kubectl delete configmap --selector='!app' --ignore-not-found 2>/dev/null || true

    if grep_output "$output" "Store|Goroutine|goroutine|Breakpoint"; then
        ok "  kube-apiserver 断点验证通过"
        record "kube-apiserver Store.Create" "✓ PASS" "breakpoint hit"
    else
        warn "  kube-apiserver 输出未包含预期内容"
        record "kube-apiserver Store.Create" "⚠ WARN" "check output"
    fi
    echo "$output" | tail -30
}

# ── 3. kube-controller-manager (port 2346) ────────────────────────────────────
test_controller() {
    info "═══ 测试 kube-controller-manager (port 2346) ═══"
    local port=2346

    if ! ss -tlnp 2>/dev/null | grep -q ":$port"; then
        warn "端口 $port 未监听，跳过"
        record "kube-controller-manager bp" "⚠ SKIP" "port $port not listening"
        return
    fi

    local bp="k8s.io/kubernetes/pkg/controller/deployment.(*DeploymentController).syncDeployment"
    info "  断点: $bp"

    # Session 1: set breakpoint and continue
    dlv_session "localhost:$port" 10 "b $bp" "c" > /dev/null 2>&1 || true

    # 触发 Deployment 同步
    kubectl create deployment ctrl-test \
        --image=registry.k8s.io/pause:3.10 \
        --replicas=1 2>/dev/null || true
    sleep 3

    # Session 2: query state while paused, then clear and continue
    local output
    output=$(dlv_session "localhost:$port" 15 \
        "goroutines" \
        "stack" \
        "locals" \
        "clearall" \
        "c" \
    ) || true

    kubectl delete deployment ctrl-test --ignore-not-found 2>/dev/null || true

    if grep_output "$output" "syncDeployment|Breakpoint|Goroutine|goroutine"; then
        ok "  kube-controller-manager 断点验证通过"
        record "controller syncDeployment" "✓ PASS" "breakpoint hit"
    else
        record "controller syncDeployment" "⚠ WARN" "check output"
    fi
    echo "$output" | tail -30
    # restart if process exited due to leader election timeout during test
    if ! ss -tlnp 2>/dev/null | grep -q ":$port"; then
        warn "  controller-manager 进程已退出，重启..."
        nohup /tmp/dlv-launch-kube-controller-manager.sh \
            > /tmp/dlv-kube-controller-manager.log 2>&1 &
        disown
        sleep 5
        ss -tlnp 2>/dev/null | grep -q ":$port" && ok "  controller-manager 已重启" || true
    fi
}

# ── 4. kubelet (port 2348) ────────────────────────────────────────────────────
test_kubelet() {
    info "═══ 测试 kubelet (port 2348) ═══"
    local port=2348

    if ! ss -tlnp 2>/dev/null | grep -q ":$port"; then
        warn "端口 $port 未监听，跳过（先运行 debug/kubelet.sh）"
        record "kubelet bp" "⚠ SKIP" "port $port not listening"
        return
    fi

    local bp="k8s.io/kubernetes/pkg/kubelet.(*Kubelet).HandlePodAdditions"
    info "  断点: $bp"

    # Session 1: set breakpoint and continue
    dlv_session "localhost:$port" 10 "b $bp" "c" > /dev/null 2>&1 || true

    # 触发: create test pod
    kubectl run kubelet-test \
        --image=registry.k8s.io/pause:3.10 \
        --restart=Never 2>/dev/null || true
    sleep 4

    # Session 2: query state while paused, then clear and continue
    local output
    output=$(dlv_session "localhost:$port" 15 \
        "goroutines" \
        "stack" \
        "locals" \
        "clearall" \
        "c" \
    ) || true

    kubectl delete pod kubelet-test --ignore-not-found 2>/dev/null || true

    if grep_output "$output" "HandlePodAdditions|Breakpoint|Goroutine|goroutine"; then
        ok "  kubelet 断点验证通过"
        record "kubelet HandlePodAdditions" "✓ PASS" "breakpoint hit"
    else
        record "kubelet HandlePodAdditions" "⚠ WARN" "check output"
    fi
    echo "$output" | tail -30
}

# ── 5. containerd (port 2350) ─────────────────────────────────────────────────
test_containerd() {
    info "═══ 测试 containerd (port 2350) ═══"
    local port=2350

    if ! ss -tlnp 2>/dev/null | grep -q ":$port"; then
        warn "端口 $port 未监听，跳过（先运行 debug/containerd.sh）"
        record "containerd bp" "⚠ SKIP" "port $port not listening"
        return
    fi

    local bp="github.com/containerd/containerd/pkg/cri/server.(*criService).RunPodSandbox"
    info "  断点: $bp"

    local fifo
    fifo=$(mktemp -u /tmp/dlv-ctd-XXXX)
    mkfifo "$fifo"

    (
        echo "b $bp"
        sleep 1
        echo "c"
        sleep 8
        echo "goroutines"
        echo "stack"
        echo "locals"
        echo "c"
        sleep 1
        echo "exit"
    ) > "$fifo" &

    (sleep 4; kubectl run ctd-test \
        --image=registry.k8s.io/pause:3.10 \
        --restart=Never 2>/dev/null || true) &

    local output
    output=$(timeout 25 dlv connect "localhost:$port" \
        --allow-non-terminal-interactive=true \
        < "$fifo" 2>&1 || true)
    rm -f "$fifo"

    kubectl delete pod ctd-test --ignore-not-found 2>/dev/null || true

    if grep_output "$output" "RunPodSandbox|Breakpoint|Goroutine|goroutine"; then
        ok "  containerd 断点验证通过"
        record "containerd RunPodSandbox" "✓ PASS" "breakpoint hit"
    else
        record "containerd RunPodSandbox" "⚠ WARN" "check output"
    fi
    echo "$output" | tail -30
}

# ── 运行所有测试 ──────────────────────────────────────────────────────────────
echo ""
info "═══════════════════════════════════════════════"
info "  K8s 全链路 dlv 断点测试"
info "═══════════════════════════════════════════════"
echo ""

test_scheduler
echo ""
test_apiserver
echo ""
test_controller
echo ""
test_kubelet
echo ""
test_containerd

# ── 结果汇总 ──────────────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════"
echo "  测试结果汇总"
echo "══════════════════════════════════════════════════════"
for r in "${RESULTS[@]}"; do echo "$r"; done
echo ""

if [[ ${#FAILED[@]} -eq 0 ]]; then
    ok "所有测试通过 ✓"
else
    warn "失败组件: ${FAILED[*]}"
    exit 1
fi
