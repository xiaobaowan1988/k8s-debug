# Apple Silicon QEMU 调试环境 — 执行计划

## 架构总览

```
macOS (Apple Silicon, arm64)
│
├── QEMU virt (accel=hvf)  ← ARM64 native，接近原生速度
│   └── Debian 12 ARM64 VM
│       ├── [可选] 自编 Linux v6.12（CONFIG_KPROBES/FTRACE/KGDB=y）
│       ├── K8s 集群 (kubeadm, ARM64 调试版二进制)
│       └── dlv 调试服务 (端口 2345-2353)
│
├── QEMU GDB stub (:1234) ─────── macOS GDB → 内核函数断点  [Track B]
├── SSH (:2222)           ─────── VM 管理、systemd GDB attach
└── SSH 隧道 (2345-2353, 6443) ── macOS dlv connect / kubectl
```

---

## Track A：K8s 组件断点调试（推荐入门）

**不需要编译内核**，约 1-2 小时完成。VM 使用 UEFI 启动（随 QEMU 安装自带固件）。

| 步骤 | 脚本 | 说明 |
|------|------|------|
| 1 | `00-check-prerequisites.sh` | 检查 brew 依赖（qemu, docker, python3）|
| 2 | `02-prepare-rootfs.sh` | 下载 Debian 12 ARM64 cloud image + cloud-init ISO |
| 3 | `04-launch-qemu.sh --bg` | 启动 VM（UEFI 模式，自动检测，无需自编内核）|
| 4 | `10-vm-prereqs.sh` | VM 内安装 Go 1.23 / dlv / containerd / kubeadm |
| 5 | `11-vm-build.sh` | macOS 触发：rsync repo → VM，编译所有 K8s 调试版二进制 |
| 6 | `12-vm-cluster.sh` | kubeadm init + Flannel CNI + 注入调试二进制 |
| 7 | `13-vm-debug-start.sh` | 启动全部 9 个 dlv 服务（端口 2345-2353）|
| 8 | `14-mac-tunnel.sh` | SSH 隧道 + 生成 `~/.kube/config-vm-debug` |

完成后从 macOS：
```bash
export KUBECONFIG=~/.kube/config-vm-debug
kubectl get nodes
dlv connect localhost:2345   # kube-apiserver
dlv connect localhost:2348   # kubelet
bash scripts/08-test-breakpoints.sh   # 全量断点测试
```

---

## Track B：Linux 内核 + systemd + K8s 全栈调试

在 Track A 基础上增加内核和 systemd 调试能力。需要 Docker（用于 ARM64 交叉编译）。

| 步骤 | 脚本 | 说明 |
|------|------|------|
| 1 | `00-check-prerequisites.sh` | 同上，额外检查 Docker |
| 2 | `01-build-kernel.sh` | **新增**：Docker 编译 Linux v6.12 ARM64（含 KPROBES/FTRACE/KGDB）约 30 分钟 |
| 3 | `02-prepare-rootfs.sh` | 同上 |
| 4 | `03-build-systemd.sh` | **可选**：Docker 编译 systemd v257 调试版（Debian dbgsym 包也够用）|
| 5 | `04-launch-qemu.sh --bg` | 启动 VM（检测到自编内核后自动切换为内核加载模式，含 nokaslr）|
| 6-8 | `10-14-*.sh` | 同 Track A，K8s 调试同步进行 |

### 内核调试（额外步骤）
```bash
# 重启 VM，开启 GDB stub
bash scripts/mac/04-launch-qemu.sh --gdb   # 前台，或 --gdb --bg
# 另开终端
bash scripts/mac/05-kernel-debug.sh        # GDB 连接 :1234，设置断点
```

内核断点示例：`copy_process`, `tcp_connect`, `do_sys_openat2`, `cgroup_attach_task`

### systemd 调试（额外步骤）
```bash
bash scripts/mac/06-systemd-debug.sh       # SSH 进 VM，指导 gdb -p 1
```

systemd 断点示例：`unit_start`, `service_start`, `cgroup_context_apply`, `manager_add_job`

---

## 各脚本必要性说明

| 脚本 | Track A (K8s) | Track B (全栈) | 说明 |
|------|:---:|:---:|------|
| `00-check-prerequisites.sh` | ✓ | ✓ | 前置检查 |
| `01-build-kernel.sh` | — | ✓ | 仅内核调试需要（~30 min）|
| `02-prepare-rootfs.sh` | ✓ | ✓ | VM 磁盘镜像 |
| `03-build-systemd.sh` | — | 可选 | Debian dbgsym 包可替代 |
| `04-launch-qemu.sh` | ✓ | ✓ | 启动 VM（自动选择 UEFI/内核模式）|
| `05-kernel-debug.sh` | — | ✓ | 内核 GDB 会话 |
| `06-systemd-debug.sh` | — | 可选 | systemd GDB 指引 |
| `10-vm-prereqs.sh` | ✓ | ✓ | VM 内 K8s 前置依赖 |
| `11-vm-build.sh` | ✓ | ✓ | 编译 K8s 调试版二进制 |
| `12-vm-cluster.sh` | ✓ | ✓ | 初始化 K8s 集群 |
| `13-vm-debug-start.sh` | ✓ | ✓ | 启动 dlv 服务 |
| `14-mac-tunnel.sh` | ✓ | ✓ | SSH 隧道 + kubectl config |

---

## 端口分配

| 端口 | 用途 | 协议 |
|------|------|------|
| 2222 | SSH 进 VM | TCP |
| 1234 | QEMU GDB stub（`--gdb` 模式，内核调试用）| TCP |
| 2345 | kube-apiserver dlv | TCP |
| 2346 | kube-controller-manager dlv | TCP |
| 2347 | kube-scheduler dlv | TCP |
| 2348 | kubelet dlv | TCP |
| 2349 | kube-proxy dlv | TCP |
| 2350 | containerd dlv | TCP |
| 2351 | etcd dlv | TCP |
| 2352 | coredns dlv | TCP |
| 2353 | CSI hostpath dlv | TCP |
| 6443 | K8s API Server | TCP |

所有端口通过 `14-mac-tunnel.sh` 从 VM 转发到 macOS localhost。

---

## 常用命令

```bash
# 停止隧道
bash scripts/mac/14-mac-tunnel.sh --stop

# 停止 VM
bash scripts/mac/04-launch-qemu.sh --stop   # 或 Ctrl-A X

# 重新启动 K8s dlv 服务
bash scripts/mac/13-vm-debug-start.sh

# 全量断点测试（确保隧道已建立）
export KUBECONFIG=~/.kube/config-vm-debug
bash scripts/08-test-breakpoints.sh
```
