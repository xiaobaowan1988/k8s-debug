# K8s 全链路内核 syscall 验证记录

本文记录通过 **strace** 和**功能性验证**对 StatefulSet 创建全链路中涉及的内核函数的确认结果。

## 验证环境

| 项目 | 版本 |
|------|------|
| Linux 内核 | 6.18.5 |
| Kubernetes | v1.32.0 |
| containerd | v2.0.1 |
| runc | v1.3.4 |
| cgroup 模式 | cgroupv1 (`cgroupfs` driver) |

strace 命令：
```bash
strace -p <containerd-PID> -f \
    -e trace=execve,unshare,mount,clone,openat \
    -e signal=none \
    -o /tmp/kernel-syscall-verify.log
```

> **注意**：strace 附加在 containerd 进程上（`-f` 追踪所有子进程），因此同时覆盖了
> containerd-shim-runc-v2、runc、runc init、CNI 插件等全部子进程的系统调用。

---

## 触发路径

创建一个带 `volumeClaimTemplates` 的 StatefulSet，完整链路为：

```
kubectl apply → apiserver → etcd
  → controller-manager (syncStatefulSet) → 创建 Pod-0 + PVC-0
  → apiserver → etcd
  → controller-manager (syncUnboundClaim) → CSI CreateVolume
  → controller-manager (bindVolumeToClaim) → PVC Bound
  → scheduler (ScheduleOne) → kubelet (HandlePodAdditions)
  → containerd CRI (RunPodSandbox)
      → unshare(CLONE_NEWNET)            ← ① kernel
      → mount(netns, MS_BIND)            ← ② kernel
      → execve(CNI bridge/loopback)      ← ⑥ kernel
  → containerd CRI (CreateContainer)
      → mount("overlay", rootfs)         ← ③ kernel
  → containerd CRI (StartContainer)
      → execve(containerd-shim-runc-v2)
          → execve(runc create)          ← ⑤ kernel
              → execve(runc init)
                  → clone(CLONE_PARENT|SIGCHLD) ← ④ kernel
                      → [container process]
                          → cgroup.procs 写入  ← ⑦ kernel
```

---

## 验证结果

### ① `__x64_sys_unshare` — 创建 network namespace

**触发位置**：`sandbox_run.go` → `netns_linux.go:116`
```go
unix.Unshare(unix.CLONE_NEWNET)
```

**strace 输出**：
```
25907 unshare(CLONE_NEWNET) = 0
```

附加的 unshare 调用（runc 创建容器所有 namespace）：
```
13254 unshare(CLONE_NEWNS|CLONE_NEWUTS|CLONE_NEWIPC|CLONE_NEWPID) = 0
```

✓ **内核函数 `__x64_sys_unshare` 已触发**

---

### ② `do_mount(MS_BIND)` — netns bind mount

**触发位置**：`netns_linux.go:130`
```go
unix.Mount(netnsPath, bindTarget, "bind", unix.MS_BIND, "")
```

**strace 输出**：
```
25907 mount("/proc/17219/task/25907/ns/net",
            "/var/run/netns/cni-60d34d8b-7bf8-665d-3e7f-47a57765acbb",
            0xc000c01300, MS_BIND, NULL) = 0
```

后续 runc rootfs bind mount：
```
13255 mount("/run/containerd/.../rootfs", ".../rootfs",
            0xc000162860, MS_BIND|MS_REC, NULL) = 0
```

✓ **内核函数 `do_mount` (MS_BIND 路径) 已触发**

---

### ③ `do_mount(overlay)` — overlay rootfs 挂载

**触发位置**：containerd snapshot 层，`CreateContainer` 期间挂载 overlay
```go
// containerd overlayfs snapshotter
mount("overlay", rootfsPath, "overlay", 0, options)
```

**strace 输出**：
```
13234 mount("overlay",
            "/run/containerd/io.containerd.runtime.v2.task/k8s.io/e41f8a7e.../rootfs",
            "overlay", 0,
            "workdir=/var/lib/containerd/io.c"...) = 0
17676 mount("overlay",
            "/var/lib/containerd/tmpmounts/containerd-mount4253163302",
            "overlay", 0, "lowerdir=/var/lib/containerd/io."...) = 0
```

✓ **内核函数 `do_mount` (overlay 路径) 已触发**

---

### ④ `copy_process` — fork 容器进程

**触发位置**：`runc/libcontainer/nsenter/nsexec.c:322`
```c
clone(child_func, CLONE_PARENT|SIGCHLD, &ca)
```

**调用链**：`runc create` → fork `runc init` → `nsexec.c` C 代码运行（在 Go runtime 之前）→ `clone()`

**strace 输出**（三级 fork）：
```
# runc create (PID 13243) fork runc init
13252 execve("/proc/self/fd/6", ["runc", "init"], ...) = 0

# runc init 第一级 clone（创建 namespace 中间进程）
13252 clone(child_stack=0x7ffd4778b690, flags=CLONE_PARENT|SIGCHLD) = 13254

# 第二级 clone（创建真正的容器 init 进程）
13254 unshare(CLONE_NEWNS|CLONE_NEWUTS|CLONE_NEWIPC|CLONE_NEWPID) = 0
13254 clone(child_stack=0x7ffd4778b690, flags=CLONE_PARENT|SIGCHLD) = 13255
```

每次 `clone()` 系统调用都触发内核的 `copy_process()`（由 `kernel_clone()` 调用）。

✓ **内核函数 `copy_process` 已触发**

---

### ⑤ runc `Container.Start` — exec 调用链

**触发位置**：`container_start.go:177` → containerd-shim → runc

**strace 输出**：
```
# containerd-shim-runc-v2 被 exec（start 阶段）
13223 execve("/usr/local/bin/containerd-shim-runc-v2",
             [..., "-id", "e41f8a7e...", "start"], ...) = 0

# shim exec runc create
13243 execve("/usr/bin/runc",
             ["runc", "--root", "/run/containerd/runc/k8s.io",
              "--log-format", "json", "create",
              "--bundle", "...", "e41f8a7e..."], ...) = 0

# runc create exec runc init（三级 exec 链）
13252 execve("/proc/self/fd/6", ["runc", "init"], ...) = 0

# shim exec runc start
13263 execve("/usr/bin/runc",
             ["runc", ..., "start", "e41f8a7e..."], ...) = 0
```

完整 exec 链：`containerd` → `exec containerd-shim-runc-v2` → `exec runc create` → `exec runc init` → `execve 容器入口`

✓ **runc `Container.Start` exec 调用链已确认**

---

### ⑥ CNI `cmdAdd` — 网络配置

**触发位置**：`sandbox_run.go:241` → CNI plugin executor → `exec` CNI 二进制

**strace 输出**：
```
13149 execve("/opt/cni/bin/loopback",  ["/opt/cni/bin/loopback"],  ...) = 0
13150 execve("/opt/cni/bin/bridge",    ["/opt/cni/bin/bridge"],    ...) = 0
13196 execve("/opt/cni/bin/host-local",["/opt/cni/bin/host-local"],...) = 0
```

CNI 插件通过 netlink `RTM_NEWLINK` 在内核创建 veth pair（bridge 插件）并配置 loopback（loopback 插件）。

✓ **CNI `cmdAdd` (bridge + loopback + host-local) exec 已确认**

---

### ⑦ `cgroup_attach_task` — 容器进程加入 cgroup

**触发位置**：runc 写入 `cgroup.procs` → 内核调用 `cgroup_attach_task`（`kernel/cgroup/cgroup.c`）

**初次 strace 为何未捕获**：第一次 strace 命令仅追踪了 `execve,unshare,mount,clone,openat`，**没有包含 `write`**。runc init 对 `cgroup.procs` 的写入是 `write(fd, "27583\n", 6)` 而非 `openat`，因此被过滤规则排除在外。seccomp 阻断的是容器 init 进程自己调用 `PTRACE_TRACEME` 的路径，不影响 runc init 对 cgroup.procs 的写入。

**直接捕获方法**（`strace -y` + grep）：

strace 的 `-y` 选项会将每个 fd 参数标注为它在 `/proc/pid/fd/N` 的真实路径，使 `write(fd, ...)` 的输出中包含文件路径信息。由于 cgroup.procs 的完整路径含有动态生成的 Pod UID 和 container ID，无法提前指定；用 `-y` 配合 grep 流式过滤是最直接的方式：

```bash
strace -p <containerd-PID> -f -y \
    -e trace=openat,write \
    -e signal=none \
    2>&1 | grep cgroup.procs
```

预期输出（runc init 写入容器 PID）：
```
13255 openat(AT_FDCWD, "/sys/fs/cgroup/cpu/kubepods/besteffort/pod.../cgroup.procs",
             O_WRONLY|O_TRUNC) = 7
13255 write(7</sys/fs/cgroup/cpu/kubepods/besteffort/.../cgroup.procs>, "27583\n", 6) = 6
```

**功能性验证**（等价证明）：

```bash
# 容器 PID 已写入 5 个 cgroup 子系统的 cgroup.procs
$ cat /sys/fs/cgroup/cpu/kubepods/besteffort/podcc5f15e9-.../09bb95.../cgroup.procs
27583

# 容器进程的 cgroup 成员关系
$ cat /proc/27583/cgroup
8:cpuset:/kubepods/besteffort/podcc5f15e9.../09bb9598...
7:pids:/kubepods/besteffort/podcc5f15e9.../09bb9598...
3:memory:/kubepods/besteffort/podcc5f15e9.../09bb9598...
2:cpuacct:/kubepods/besteffort/podcc5f15e9.../09bb9598...
1:cpu:/kubepods/besteffort/podcc5f15e9.../09bb9598...
```

在 cgroupv1 中，进程只能通过写入 `cgroup.procs`（或 `tasks`）文件来加入 cgroup，该写入**必然**触发内核 `cgroup_attach_task`——这是唯一代码路径。容器 PID 已出现在 5 个子系统的 cgroup 层级中，证明 `cgroup_attach_task` 已被内核执行。

✓ **内核函数 `cgroup_attach_task` 已功能性确认**

---

## 汇总

| # | 内核函数 | 对应用户态调用 | 验证方式 | 结果 |
|---|---------|-------------|---------|------|
| ① | `__x64_sys_unshare` | `unix.Unshare(CLONE_NEWNET)` | strace `unshare()` | ✓ |
| ② | `do_mount(MS_BIND)` | `unix.Mount(..., MS_BIND)` | strace `mount()` | ✓ |
| ③ | `do_mount(overlay)` | overlay snapshotter | strace `mount()` | ✓ |
| ④ | `copy_process` | `clone(CLONE_PARENT\|SIGCHLD)` | strace `clone()` | ✓ |
| ⑤ | runc exec 链 | `StartContainer` → shim → runc | strace `execve()` | ✓ |
| ⑥ | CNI `cmdAdd` | sandbox_run.go:241 → exec | strace `execve()` | ✓ |
| ⑦ | `cgroup_attach_task` | `cgroup.procs` 写入 | 功能性验证 | ✓ |

所有 7 项均已验证。完整 19 步链路的 dlv 断点验证见 `scripts/08-test-breakpoints.sh`。

---

## 相关文件

| 文件 | 说明 |
|------|------|
| `scripts/08-test-breakpoints.sh` | 自动化断点测试脚本（含 StatefulSet 全链路） |
| `debug/containerd.sh` | containerd dlv attach 脚本 |
| `debug/kubelet.sh` | kubelet dlv attach 脚本 |
| `debug/csi.sh` | CSI hostpath driver dlv exec 脚本 |
| `debug/kernel-container.sh` | QEMU + GDB 内核断点脚本 |
