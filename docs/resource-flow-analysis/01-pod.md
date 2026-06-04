# Pod 创建链路

Pod 是 K8s 最基础的调度单元。其他所有工作负载（Deployment、StatefulSet、DaemonSet、Job）最终都通过创建 Pod 来运行容器。本文是后续工作负载文档的公共尾部。

**apiserver → etcd 路径**：见 `00-apiserver-common-flow.md`，本文从 scheduler 开始。

---

## 两种 Pod 来源

| 来源 | 说明 |
|------|------|
| 直接创建 | `kubectl run` / `kubectl apply` 直接提交 Pod 对象 |
| Controller 创建 | Deployment/StatefulSet/DaemonSet/Job 的 controller 代为创建 |

两种来源在 apiserver 写入后的路径完全相同。

---

## 接力图

```
apiserver 写入 Pod（Spec.NodeName 为空）
    ↓
Scheduler.ScheduleOne()         为 Pod 选择节点
    ↓ 写 Binding 对象（设置 NodeName）
apiserver 更新 Pod.Spec.NodeName
    ↓ watch 事件
Kubelet.HandlePodAdditions()    本节点 kubelet 接管
    ↓
syncPod()
    ├── volumeManager             挂载 Volume（CSI NodeStage + NodePublish）
    └── kuberuntime.SyncPod()
            ├── RunPodSandbox()   创建 pause 容器 + 网络 namespace + CNI
            ├── CreateContainer() 挂载 overlay rootfs
            └── StartContainer()  exec shim → runc → 容器进程
```

---

## ① Scheduler

`pkg/scheduler/scheduler.go`

```go
func (sched *Scheduler) Run(ctx context.Context) {
    go wait.UntilWithContext(ctx, sched.ScheduleOne, 0)
}

func (sched *Scheduler) ScheduleOne(ctx context.Context) {
    // ← dlv 断点

    podInfo := sched.NextPod()     // 从优先级队列取 Pod
    pod := podInfo.Pod

    // --- Filter 阶段 ---
    // 遍历所有节点，调用每个 FilterPlugin
    feasibleNodes, err := sched.findNodesThatFitPod(ctx, fwk, state, pod)
    // 内置 Filter plugin：
    //   NodeResourcesFit       — CPU/内存是否足够
    //   NodeAffinity           — 节点亲和性
    //   PodTopologySpread      — 拓扑分布约束
    //   VolumeBinding          — PVC 是否已 Bound
    //   TaintToleration        — taint/toleration 匹配

    // --- Score 阶段 ---
    priorityList, err := sched.prioritizeNodes(ctx, fwk, state, pod, feasibleNodes)
    // 内置 Score plugin：
    //   LeastAllocated         — 资源使用最少的节点得高分
    //   ImageLocality          — 已有镜像的节点得高分
    //   InterPodAffinity       — Pod 间亲和性

    // --- Select ---
    host, err := sched.selectHost(priorityList)

    // --- Bind ---
    sched.bind(ctx, fwk, pod, host, state)
    // → POST /api/v1/namespaces/{ns}/pods/{name}/binding
    // → Pod.Spec.NodeName = host
}
```

`pkg/scheduler/framework/runtime/framework.go` — 插件框架，所有 Filter/Score plugin 在此注册和调用。

---

## ② Kubelet 接收 Pod

`pkg/kubelet/kubelet.go`

```go
// informer 回调
func (kl *Kubelet) HandlePodAdditions(pods []*v1.Pod) {
    // ← dlv 断点

    for _, pod := range pods {
        kl.podManager.AddPod(pod)

        // 检查是否是 static pod（来自文件系统，不经过 apiserver）
        if kubetypes.IsStaticPod(pod) {
            kl.handleStaticPod(pod)
            continue
        }

        kl.dispatchWork(pod, kubetypes.SyncPodCreate, mirrorPod, start)
    }
}
```

`pkg/kubelet/pod_workers.go` → `podWorkerLoop()` → `syncPodFn()`

```go
func (kl *Kubelet) syncPod(ctx, updateType, pod, mirrorPod, podStatus) error {
    // 创建 Pod 目录：/var/lib/kubelet/pods/{UID}/
    kl.makePodDataDirs(pod)

    // 拉取镜像（异步，通过 imageManager）
    kl.containerManager.EnsureImageExists(pod, pullSecrets)

    // 等待 Volume 挂载就绪
    kl.volumeManager.WaitForAttachAndMount(pod)

    // 调用 CRI
    result := kl.containerRuntime.SyncPod(pod, podStatus, pullSecrets, kl.backOff)
}
```

---

## ③ Volume 挂载（CSI）

`pkg/kubelet/volumemanager/reconciler/reconciler.go`

```go
func (rc *reconciler) reconcile(ctx) {
    // NodeStageVolume：格式化 + 挂载到全局 staging 目录
    rc.operationExecutor.MountVolume(
        waitForAttachTimeout, volumeToMount, rc.actualStateOfWorld, false)
}
```

CSI 调用链：
```
kubelet volumeManager
    → csi.NodeStageVolume(volumeID, stagingTargetPath)
        → CSI driver: 格式化磁盘，挂载到 /var/lib/kubelet/plugins/kubernetes.io/csi/pv/{pvName}/globalmount
    → csi.NodePublishVolume(stagingTargetPath, targetPath)
        → bind mount: /var/lib/kubelet/plugins/... → /var/lib/kubelet/pods/{UID}/volumes/...
```

---

## ④ CRI：RunPodSandbox

`pkg/kubelet/kuberuntime/kuberuntime_manager.go` → `SyncPod()` → `createPodSandbox()`

containerd 侧：`internal/cri/server/sandbox_run.go`

```go
func (c *criService) RunPodSandbox(ctx, config, runtimeHandler) (string, error) {
    // ← dlv 断点（containerd 进程）

    // 1. 创建 network namespace
    //    syscall: unshare(CLONE_NEWNET) → __x64_sys_unshare
    netns, _ := netns.NewNetNS()

    // 2. bind mount netns 使其持久化
    //    syscall: mount(netnsPath, bindTarget, MS_BIND) → do_mount
    unix.Mount(netnsPath, bindTarget, "bind", unix.MS_BIND, "")

    // 3. 创建 pause 容器的 cgroup 层级
    cgroupPath := "/kubepods/{qos}/pod{UID}"
    os.MkdirAll("/sys/fs/cgroup/cpu/"+cgroupPath, 0755)

    // 4. 调用 CNI 配置网络（在 netns 内）
    c.setupPodNetwork(ctx, sandbox)
        → cniPlugin.Setup(id, netnsPath, opts...)
            → exec("/opt/cni/bin/loopback")   // syscall: execve
            → exec("/opt/cni/bin/bridge")     // 创建 veth pair，连接到 cni0 bridge
            → exec("/opt/cni/bin/host-local") // 分配 IP，写入 /var/lib/cni/networks/

    // pause 容器作为 Pod 的 network/IPC namespace 持有者
}
```

---

## ⑤ CRI：CreateContainer

containerd：`internal/cri/server/container_create.go`

```go
func (c *criService) CreateContainer(ctx, sandboxID, config, sandboxConfig) (string, error) {
    // ← dlv 断点

    // 1. 通过 snapshotter 准备 overlay rootfs
    //    syscall: mount("overlay", rootfsPath, "overlay", 0, opts) → do_mount
    mounts, _ := c.snapshotterService.Prepare(ctx, snapshotKey, imageKey)

    // 2. 生成 OCI spec（包含 seccomp、capabilities、挂载点等）
    spec, _ := c.generateContainerSpec(id, sandboxID, config, sandboxConfig, imageConfig, extraMounts)

    // 3. 在 containerd 内创建容器对象（尚未启动）
    cntr, _ := c.client.NewContainer(ctx, id,
        containerd.WithSpec(spec),
        containerd.WithSnapshotter(snapshotter),
        containerd.WithSnapshot(snapshotKey),
    )
}
```

---

## ⑥ CRI：StartContainer

containerd：`internal/cri/server/container_start.go`

```go
func (c *criService) StartContainer(ctx, containerID) error {
    // ← dlv 断点

    task, _ := container.NewTask(ctx, cio.NewCreator(cio.WithStdio))
    // 这一步触发完整的 exec 链：
    //
    // containerd
    //   → execve("/usr/local/bin/containerd-shim-runc-v2", [..., "start"])
    //       → execve("/usr/bin/runc", ["runc", "--root", ..., "create", "--bundle", ...])
    //           → execve("/proc/self/fd/6", ["runc", "init"])
    //               ↓ nsexec.c（C 代码，在 Go runtime 之前运行）
    //               → clone(CLONE_PARENT|SIGCHLD) = 中间进程 PID
    //                   → unshare(CLONE_NEWNS|NEWUTS|NEWIPC|NEWPID)
    //                   → clone(CLONE_PARENT|SIGCHLD) = 容器 init PID
    //                       ↓ (copy_process × 2)
    //               ↓ Go 代码接管
    //               → 设置 rootfs、挂载点、hostname、用户
    //               → 写入 cgroup.procs（cgroup_attach_task）
    //               → 应用 seccomp
    //   → execve("/usr/bin/runc", ["runc", ..., "start", containerID])
    //       → 容器 entrypoint 开始执行

    task.Start(ctx)
}
```

---

## 内核 syscall 汇总

| syscall | 内核函数 | 触发位置 |
|---------|---------|---------|
| `unshare(CLONE_NEWNET)` | `__x64_sys_unshare` | RunPodSandbox，创建 netns |
| `mount(MS_BIND)` | `do_mount` | netns bind mount |
| `mount("overlay")` | `do_mount` | CreateContainer，overlay rootfs |
| `clone(CLONE_PARENT\|SIGCHLD)` × 2 | `copy_process` | runc init nsexec.c |
| `execve(runc/shim/CNI)` | `__x64_sys_execve` | StartContainer 整个 exec 链 |
| `write(cgroup.procs)` | `cgroup_attach_task` | runc init 写入容器 PID |

---

## dlv 断点列表

```bash
# scheduler（port 2347）
b k8s.io/kubernetes/pkg/scheduler.(*Scheduler).ScheduleOne

# kubelet（port 2348）
b k8s.io/kubernetes/pkg/kubelet.(*Kubelet).HandlePodAdditions
b k8s.io/kubernetes/pkg/kubelet.(*Kubelet).syncPod

# containerd CRI（port 2350）
b github.com/containerd/containerd/v2/internal/cri/server.(*criService).RunPodSandbox
b github.com/containerd/containerd/v2/internal/cri/server.(*criService).CreateContainer
b github.com/containerd/containerd/v2/internal/cri/server.(*criService).StartContainer
```

---

## strace 命令

```bash
# 追踪 containerd 及所有子进程的关键 syscall
strace -p <containerd-PID> -f \
    -e trace=execve,unshare,mount,clone \
    -e signal=none \
    -o /tmp/pod-create.log

# 单独捕获 cgroup.procs 写入
strace -p <containerd-PID> -f -y \
    -e trace=openat,write \
    -e signal=none \
    2>&1 | grep cgroup.procs
```

---

## 相关文档

| 文档 | 说明 |
|------|------|
| `00-apiserver-common-flow.md` | apiserver → etcd 通用路径 |
| `02-replicaset.md` | ReplicaSet controller 如何创建 Pod |
| `07-pvc-dynamic.md` | Volume 挂载的 CSI 链路 |
| `../kernel-syscall-verification.md` | 内核 syscall 实测验证记录 |
