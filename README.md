# k8s-debug — Kubernetes 全链路源码断点调试环境

在真实 K8s 集群中对**所有核心组件**设置断点、单步追踪，观察请求从 kubectl 到
etcd 的完整调用链。使用 [Delve](https://github.com/go-delve/delve)（Go 调试器）
对所有 Go 组件实施 `dlv exec` / `dlv attach` headless 调试，IDE 或命令行均可连入。

---

## 可调试的组件

| 端口 | 组件 | 模式 | 典型断点 |
|------|------|------|---------|
| 2345 | kube-apiserver | dlv exec | `Store.Create`（资源写入 etcd）|
| 2346 | kube-controller-manager | dlv exec | `syncDeployment` |
| 2347 | kube-scheduler | dlv exec | `scheduleOne` |
| 2348 | kubelet | dlv attach | `HandlePodAdditions` |
| 2349 | kube-proxy | dlv exec | `syncProxyRules` |
| 2350 | containerd | dlv attach | `RunPodSandbox` |
| 2351 | etcd | dlv exec | `EtcdServer.Put` |
| 2352 | coredns | dlv exec | `Forward.ServeDNS` |
| 2353 | CSI hostpath | dlv exec | `CreateVolume` |
| —    | runc | dlv exec（隔离）| `Container.Start` |
| —    | CNI bridge | dlv exec（隔离）| `cmdAdd` |
| —    | Linux 内核 | strace / GDB | 系统调用边界 |

所有 dlv 服务以 **host-process 模式**运行（控制平面组件接管系统端口，不依赖容器）。

---

## 运行环境

### 环境 A：Linux 原生（推荐，最简单）

直接在 Linux VM / 物理机上运行，无需嵌套虚拟化：

```
Linux 主机 (x86_64 或 aarch64)
└── K8s 集群 (kubeadm)
    ├── 所有组件以 host 进程 + dlv exec 运行
    └── dlv 服务监听 2345-2353
```

快速开始：

```bash
# 1. 安装依赖 + 编译 + 建集群（一键）
make setup

# 2. 开启所有组件调试服务
make debug-all        # 启动 tmux 多窗口调试会话

# 3. 验证所有断点（自动触发并验证 12 个组件）
make test-breakpoints
```

分步操作：

```bash
make clone            # 克隆 K8s / etcd / containerd / runc / coredns 等源码
make build-all        # 编译为含调试符号的二进制
make cluster-create   # kubeadm init 单节点集群
make inject-binaries  # 替换为调试版二进制
make setup-debug-manifests  # 控制平面改为 host 进程 + dlv exec

# 按组件启动调试
bash debug/apiserver.sh
bash debug/kubelet.sh
# ... 其余见 debug/
```

---

### 环境 B：Apple Silicon Mac + QEMU（无 Linux 机器时）

在 MacBook Pro/Air (M 系列) 上通过 QEMU HVF 加速运行 ARM64 Linux VM，
在 VM 内运行完整 K8s 集群，通过 SSH 隧道从 macOS 直接使用 `dlv connect` 调试。

详细计划见 [PLAN.md](PLAN.md)。概要步骤：

```bash
# macOS 侧（按顺序执行）
bash scripts/mac/00-check-prerequisites.sh   # 检查 brew 依赖
bash scripts/mac/02-prepare-rootfs.sh        # 下载 Debian 12 ARM64 cloud image
bash scripts/mac/04-launch-qemu.sh --bg      # 启动 QEMU VM（UEFI 模式）
bash scripts/mac/10-vm-prereqs.sh            # VM 内安装 Go / dlv / kubeadm
bash scripts/mac/11-vm-build.sh              # 编译 K8s 调试版二进制（VM 内）
bash scripts/mac/12-vm-cluster.sh            # kubeadm init + 调试配置
bash scripts/mac/13-vm-debug-start.sh        # 启动 VM 内全部 dlv 服务
bash scripts/mac/14-mac-tunnel.sh            # SSH 隧道 → macOS localhost

# 之后从 macOS 直接使用
export KUBECONFIG=~/.kube/config-vm-debug
kubectl get nodes
dlv connect localhost:2345                   # 调试 kube-apiserver
bash scripts/08-test-breakpoints.sh          # 全量断点测试
```

如需额外调试 Linux 内核或 systemd，还可选择运行：

```bash
bash scripts/mac/01-build-kernel.sh    # 编译 Linux v6.12（Docker，约 30 分钟）
bash scripts/mac/04-launch-qemu.sh --gdb  # 重启 VM，开 QEMU GDB stub :1234
bash scripts/mac/05-kernel-debug.sh   # GDB 连接内核，设置 copy_process 等断点
bash scripts/mac/06-systemd-debug.sh  # GDB attach systemd PID 1
```

---

## 目录结构

```
k8s-debug/
├── README.md               本文件
├── PLAN.md                 Apple Silicon QEMU 调试环境详细计划
├── Makefile                常用操作入口（make setup / debug-all / test-breakpoints）
│
├── scripts/                执行脚本（按编号顺序执行）
│   ├── 00-install-deps.sh  安装系统依赖、Go、dlv
│   ├── 01-clone-*.sh       克隆各组件源码
│   ├── 02-build-*.sh       编译含调试符号的二进制
│   ├── 04-cluster-create.sh  kubeadm init
│   ├── 05-inject-binaries.sh 注入调试版二进制到 /usr/local/bin
│   ├── 06-setup-debug-manifests.sh  控制平面改为 host 进程 + dlv
│   ├── 08-test-breakpoints.sh       全量断点验证脚本
│   └── mac/                Apple Silicon + QEMU 专用脚本（见 PLAN.md）
│
├── debug/                  各组件 dlv 启动脚本
│   ├── all.sh              一键开启所有组件（tmux 多窗口）
│   ├── apiserver.sh        kube-apiserver :2345
│   ├── controller-manager.sh :2346
│   ├── scheduler.sh        :2347
│   ├── kubelet.sh          :2348 (dlv attach)
│   ├── kube-proxy.sh       :2349
│   ├── containerd.sh       :2350 (dlv attach)
│   ├── etcd.sh             :2351
│   ├── coredns.sh          :2352
│   ├── csi.sh              :2353
│   └── kernel-strace.sh    strace 内核系统调用分析
│
├── config/                 集群配置文件
│   ├── kubeadm-config.yaml
│   └── containerd-k8s.toml
│
├── deploy/                 部署 YAML
│   ├── kube-proxy/         kube-proxy DaemonSet（含 ServiceAccount）
│   └── csi-hostpath/
│
└── build/                  编译产物（git ignored）
    ├── kubernetes/         kube-apiserver 等带调试符号的二进制
    └── runtime/            containerd / runc / coredns 等
```

---

## 核心设计

**host-process 模式**：控制平面组件（apiserver、etcd、coredns 等）不通过
kubelet/容器运行，而是直接以宿主进程运行在 `dlv exec` 下。好处是 dlv 能完整控制
进程生命周期，断点/单步/变量查看不受容器隔离影响。

**端口约定**：所有 dlv headless server 统一监听 `0.0.0.0:<port>`，
使用 `--api-version=2 --accept-multiclient --continue`，支持多客户端同时连入。

**断点连接方式**：
```bash
dlv connect localhost:2345          # 命令行
# 或在 VS Code launch.json 中配置 "connect" 类型
```

**版本**：K8s v1.32，etcd v3.5，containerd v2.0，coredns v1.11，Go 1.23
