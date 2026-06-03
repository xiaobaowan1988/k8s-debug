# Kubernetes & 容器底层全链路源码级 Debug 指南

本指南旨在通过源码级断点调试（Go Delve + GDB），打通从 Kubernetes 控制平面调度指令到 Linux 内核态 Namespace 隔离的完整调用链路，建立对云原生底层架构的绝对心智模型。

---

## 零、 核心链路概览与心智模型

在打断点前，请在脑海中建立 Pod 创建的全链路流转顺序：
1. **API Server:** 接收 YAML 请求，执行准入控制，存入 etcd。
2. **Controller Manager:** 监听 etcd，将 Deployment 展开为 ReplicaSet 和未调度的 Pod。
3. **Scheduler:** 发现未调度 Pod，执行过滤打分算法，绑定到目标 Node。
4. **Kubelet:** 监听分配到本节点的 Pod，作为 Node 大管家驱动后续流程。
5. **kube-proxy:** 监听 Service 变化，配置 Node 节点的底层路由（iptables/IPVS）。
6. **containerd (CRI):** 接收 Kubelet 指令，管理 Sandbox 与业务容器生命周期。
7. **CNI & CSI:** 分配网络 IP、挂载持久化存储设备。
8. **runc (OCI):** 构造 cgroups 限制，发起底层系统调用。
9. **Linux Kernel:** 实际执行 `clone()`、`setns()` 等系统调用，完成 Namespace 隔离。

---

## 一、 调试基础设施搭建 (环境准备)

构建轻量、可控的本地单节点测试床，替代真实的 EKS 环境进行黑盒解剖。

* **基础集群构建:**
  * 安装 [Kind (Kubernetes in Docker)](https://kind.sigs.k8s.io/)。
  * 启动单节点测试集群（包含 Control Plane 与 Worker 角色）。
* **Go 调试工具链:**
  * 确保宿主机环境配置了 Go 语言编译器。
  * 安装 Go 官方调试器 **Delve (`dlv`)**。
* **内核调试沙箱 (针对极底层):**
  * 准备 QEMU 虚拟机环境。
  * 编译携带 `CONFIG_DEBUG_INFO=y` 且关闭 KASLR 的 Linux 内核镜像供 GDB 远程调试。

---

## 二、 控制平面 (Control Plane) Debug

控制平面大多为长生命周期的 Go 守护进程，可直接使用 `dlv attach`。

### 1. kube-apiserver & etcd (状态网关与存储)
* **编译准备:** `make kube-apiserver GOFLAGS="-gcflags=all=-N -l"`。
* **替换进程:** 替换 Kind 容器内的二进制文件并重启服务，使用 `dlv attach <pid>` 附加。
* **核心断点:**
  * `k8s.io/apiserver/pkg/admission/chain.go`: 观察准入控制器逻辑。
  * `k8s.io/apiserver/pkg/registry/generic/registry/store.go` (Create 方法): 观察对象存入 etcd 的瞬间。
* **etcd 拓展点:** 若要深究存储，可单独拉起 etcd 并对 `go.etcd.io/etcd/server/v3/etcdserver/api/v3rpc/kv.go` 打断点。

### 2. kube-controller-manager (状态机引擎)
* **核心断点 (Deployment):**
  * `k8s.io/kubernetes/pkg/controller/deployment/deployment_controller.go` (`syncDeployment` 函数): 观察下级 ReplicaSet 生成。
  * `k8s.io/kubernetes/pkg/controller/replicaset/replica_set.go` (`syncReplicaSet` 函数): 观察实际 Pod 对象的生成。

### 3. kube-scheduler (资源调度器)
* **调试策略:** 停止集群原生 scheduler，直接在宿主机运行 `dlv exec ./kube-scheduler -- --kubeconfig=~/.kube/config`。
* **核心断点:**
  * `k8s.io/kubernetes/pkg/scheduler/scheduler.go` (`scheduleOne`): 调度器主循环入口。
  * `k8s.io/kubernetes/pkg/scheduler/framework/runtime/framework.go` (`RunFilterPlugins` / `RunScorePlugins`): 观察节点筛选与打分逻辑。

---

## 三、 数据平面 - 节点服务 (Node Components)

### 1. Kubelet (节点管家)
* **编译准备:** `make kubelet GOFLAGS="-gcflags=all=-N -l"`。
* **核心断点:**
  * `k8s.io/kubernetes/pkg/kubelet/kuberuntime.(*kubeGenericRuntimeManager).SyncPod`: 核心控制循环，拦截 Pod 状态同步逻辑。
  * `k8s.io/kubernetes/pkg/kubelet/kuberuntime.(*kubeGenericRuntimeManager).startContainer`: 观察发起容器启动指令的过程。

### 2. kube-proxy (网络路由守护进程)
* **核心断点 (iptables 模式):**
  * `k8s.io/kubernetes/pkg/proxy/iptables/proxier.go` (`syncProxyRules`): 创建 Service 时，观察系统如何组装 `iptables -t nat` 规则。

### 3. containerd (容器运行时守护进程)
* **核心断点:**
  * `github.com/containerd/containerd/pkg/cri/server.(*criService).RunPodSandbox`: 观察底层 Sandbox (Pause) 容器的诞生。
  * `github.com/containerd/containerd/pkg/cri/server.(*criService).CreateContainer`: 观察业务容器 `config.json` (OCI Spec) 的组装。

---

## 四、 数据平面 - 瞬态进程与内核态

这些组件执行极快，需采用"源码打桩挂起"、"伪造环境变量执行"或"底层 GDB"策略。

### 1. runc (OCI 底层执行器)
* **调试策略 (源码打桩):**
  * 在 `main.go` 或 `libcontainer/process_linux.go` 的入口处硬编码插入 `time.Sleep(30 * time.Second)`。
  * 重新编译替换，Pod 创建时进程会挂起 30 秒，趁机通过 PID `dlv attach` 附加调试。
* **观察目标:** runc 如何将 `config.json` 翻译为 Cgroups 目录创建和权限设置。

### 2. CNI (容器网络接口) & CSI (容器存储接口)
* **CNI 调试策略 (环境变量直调):**
  * 无需启动集群。直接伪造参数启动：
    ```bash
    export CNI_COMMAND=ADD && export CNI_NETNS=/var/run/netns/test-ns
    ```
  * 运行 `dlv exec ./cni-plugin -- -args`，在 `cmdAdd` 函数打断点，观察 `netlink` 调用建立 veth pair 过程。
* **CSI 调试策略 (gRPC 模拟):**
  * 独立启动 CSI Driver 暴露端口。使用 `grpcurl` 伪造 `NodePublishVolume` 请求，观察底层 `mount` 系统调用。

### 3. Linux Kernel (穿透内核态)
* **调试策略 (QEMU + GDB):**
  * 启动带有 Debug 符号的 QEMU 虚拟机并挂起 (`-s -S`)。
  * 宿主机使用 `gdb-multiarch` 连接 `target remote localhost:1234`。
* **核心系统调用断点:**
  * `b sys_clone` 或 `_do_fork`: 观察内核中 `task_struct` 的复制与 Namespace 标志位。
  * `b cgroup_mkdir`: 观察 Cgroups v2 目录体系的内核态建立。
  * `b setns`: 观察业务进程如何被加入到 Pause 容器的网络命名空间。

---

## 五、 终极全链路联调建议 (End-to-End Debugging)

1. 开启 Tmux 或 5 个独立终端，分别 `dlv attach` 到 API Server、Controller Manager、Scheduler、Kubelet、kube-proxy。
2. 在所有组件的同步主循环函数打上断点并处于 `continue` 监听状态。
3. 在新终端执行：`kubectl create deployment test --image=nginx`
4. **验证心智模型:** 你将亲眼见证控制台断点按照 `阶段零` 中的架构概览顺序，像多米诺骨牌一样依次触发执行。
