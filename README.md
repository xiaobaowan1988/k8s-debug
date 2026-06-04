# k8s-debug — Kubernetes 全链路源码断点调试环境（Apple Silicon）

在真实 K8s 集群中对**所有核心组件**设置断点、单步追踪，观察请求从 kubectl 到
etcd 的完整调用链。使用 [Delve](https://github.com/go-delve/delve)（Go 调试器）
对所有 Go 组件实施 `dlv exec` / `dlv attach` headless 调试，IDE 或命令行均可连入。

> **本分支**：Apple Silicon (M 系列) + QEMU 方案。在 Mac 上通过 QEMU HVF 加速
> 运行 ARM64 Linux VM，VM 内跑完整 K8s 集群，通过 SSH 隧道从 macOS 直接调试。
> 详细执行计划见 [PLAN.md](PLAN.md)。

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

## 架构

```
macOS (Apple Silicon, arm64)
│
├── QEMU virt (accel=hvf)  ← ARM64 native，接近原生速度
│   └── Debian 12 ARM64 VM
│       ├── K8s 集群 (kubeadm, ARM64 调试版二进制)
│       └── dlv 调试服务 (端口 2345-2353)
│
├── SSH (:2222) ─────────── VM 管理
└── SSH 隧道 (2345-2353, 6443) ── macOS dlv connect / kubectl
```

可选扩展（调试 Linux 内核/systemd）：
```
├── QEMU GDB stub (:1234) ─── macOS GDB → 内核函数断点
```

---

## 快速开始

```bash
# 1. 检查 macOS 依赖（qemu, docker, python3）
bash scripts/mac/00-check-prerequisites.sh

# 2. 准备 VM 磁盘（下载 Debian 12 ARM64 cloud image，约 400MB）
bash scripts/mac/02-prepare-rootfs.sh

# 3. 启动 VM（UEFI 模式，不需要自编内核）
bash scripts/mac/04-launch-qemu.sh --bg

# 4. VM 内安装 Go / dlv / containerd / kubeadm（首次约 10 分钟）
bash scripts/mac/10-vm-prereqs.sh

# 5. 编译所有 K8s 组件调试版二进制（VM 内，首次约 30-60 分钟）
bash scripts/mac/11-vm-build.sh

# 6. 初始化 K8s 集群 + 注入调试二进制
bash scripts/mac/12-vm-cluster.sh

# 7. 启动所有 dlv 调试服务（端口 2345-2353）
bash scripts/mac/13-vm-debug-start.sh

# 8. 建立 SSH 隧道 + 配置 kubectl
bash scripts/mac/14-mac-tunnel.sh
```

完成后从 macOS 直接使用：

```bash
export KUBECONFIG=~/.kube/config-vm-debug
kubectl get nodes
dlv connect localhost:2345          # kube-apiserver
dlv connect localhost:2348          # kubelet
bash scripts/08-test-breakpoints.sh # 全量断点验证（12 个组件）
```

如需调试 Linux 内核（可选）：

```bash
bash scripts/mac/01-build-kernel.sh           # 编译 Linux v6.12（Docker，约 30 分钟）
bash scripts/mac/04-launch-qemu.sh --gdb --bg # 重启 VM，开 GDB stub :1234
bash scripts/mac/05-kernel-debug.sh           # GDB 连接内核断点
bash scripts/mac/06-systemd-debug.sh          # GDB attach systemd PID 1
```

---

## 目录结构

```
k8s-debug/
├── README.md               本文件
├── PLAN.md                 执行计划：两条调试路径、各脚本必要性、端口映射
│
├── scripts/
│   ├── mac/                macOS 侧脚本（按编号顺序执行）
│   │   ├── 00-check-prerequisites.sh   检查 brew 依赖
│   │   ├── 01-build-kernel.sh          可选：编译 Linux v6.12（内核调试用）
│   │   ├── 02-prepare-rootfs.sh        Debian 12 ARM64 cloud image + cloud-init
│   │   ├── 03-build-systemd.sh         可选：编译 systemd v257 调试版
│   │   ├── 04-launch-qemu.sh           启动 VM（UEFI 或内核直加载，自动检测）
│   │   ├── 05-kernel-debug.sh          可选：GDB → QEMU GDB stub 内核断点
│   │   ├── 06-systemd-debug.sh         可选：GDB attach systemd PID 1
│   │   ├── 10-vm-prereqs.sh            VM 内安装 Go / dlv / kubeadm
│   │   ├── 11-vm-build.sh              rsync + VM 内编译所有组件
│   │   ├── 12-vm-cluster.sh            kubeadm init + Flannel + 注入调试二进制
│   │   ├── 13-vm-debug-start.sh        启动全部 9 个 dlv 服务
│   │   └── 14-mac-tunnel.sh            SSH 隧道 + kubectl config
│   │
│   ├── 01-clone-*.sh       克隆各组件源码（由 11-vm-build.sh 在 VM 内调用）
│   ├── 02-build-*.sh       编译含调试符号的二进制（同上）
│   ├── 05-inject-binaries.sh     注入调试版二进制（由 12-vm-cluster.sh 调用）
│   ├── 06-setup-debug-manifests.sh  控制平面改为 host 进程 + dlv（同上）
│   └── 08-test-breakpoints.sh    全量断点验证（从 macOS 通过隧道运行）
│
├── debug/                  各组件 dlv 启动脚本（由 13-vm-debug-start.sh 在 VM 内调用）
│   ├── apiserver.sh / controller-manager.sh / scheduler.sh / etcd.sh
│   ├── kubelet.sh / containerd.sh   (dlv attach)
│   ├── kube-proxy.sh / coredns.sh / csi.sh
│   └── kernel-strace.sh    strace 系统调用分析
│
├── config/
│   └── cni-bridge-config.json   CNI bridge 插件调试配置示例
│
├── deploy/
│   ├── kube-proxy/          kube-proxy DaemonSet YAML
│   └── csi-hostpath/        CSI hostpath driver YAML
│
└── build/                  编译产物（git ignored）
    ├── mac-debug/           QEMU kernel / rootfs / SSH key
    ├── kubernetes/          kube-apiserver 等带调试符号的二进制
    └── runtime/             containerd / runc / coredns 等
```

---

## 核心设计

**host-process 模式**：控制平面组件（apiserver、etcd、coredns 等）不通过
kubelet/容器运行，而是直接以宿主进程运行在 `dlv exec` 下。dlv 完整控制进程生命周期，
断点/单步/变量查看不受容器隔离影响。

**端口约定**：所有 dlv headless server 统一监听 `0.0.0.0:<port>`，
`--api-version=2 --accept-multiclient --continue`，支持多客户端同时连入。

**断点连接**：
```bash
dlv connect localhost:2345          # 命令行（通过 SSH 隧道）
# 或 VS Code launch.json 配置 "request": "attach", "mode": "remote"
```

**版本**：K8s v1.32，etcd v3.5，containerd v2.0，coredns v1.11，Go 1.23，Linux v6.12
