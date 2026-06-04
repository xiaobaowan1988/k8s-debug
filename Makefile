K8S_VERSION        ?= v1.32.0
CONTAINERD_VERSION ?= v2.0.1
RUNC_VERSION       ?= v1.2.3
CNI_VERSION        ?= v1.6.0
DELVE_VERSION      ?= v1.23.1

# 源码目录
SRC_DIR        ?= $(HOME)/k8s-src
K8S_SRC        := $(SRC_DIR)/kubernetes
CONTAINERD_SRC := $(SRC_DIR)/containerd
RUNC_SRC       := $(SRC_DIR)/runc
CNI_SRC        := $(SRC_DIR)/cni-plugins

# 输出目录（带调试符号的二进制）
BUILD_DIR      ?= $(CURDIR)/build
K8S_BUILD      := $(BUILD_DIR)/kubernetes
RUNTIME_BUILD  := $(BUILD_DIR)/runtime

GOFLAGS_DEBUG  := -gcflags=all="-N -l"

.PHONY: all setup clone build-k8s build-containerd build-runc build-cni \
        cluster-create cluster-delete inject-binaries \
        setup-debug-manifests restore-manifests test-breakpoints \
        debug-all debug-apiserver debug-controller debug-scheduler \
        debug-kubelet debug-proxy debug-containerd \
        clean clean-src help

all: help

## ── 一键安装 ──────────────────────────────────────────────────────────────────
setup:
	@echo "==> [1/5] 安装系统依赖（kubeadm、kubelet、containerd、dlv）"
	@bash scripts/00-install-deps.sh
	@echo "==> [2/5] 克隆所有源码"
	@$(MAKE) clone
	@echo "==> [3/5] 编译所有组件（带调试符号）"
	@$(MAKE) build-all
	@echo "==> [4/5] 构建离线镜像（网络受限时从 dl.k8s.io + GitHub 下载）"
	@$(MAKE) build-offline-images
	@echo "==> [5/5] 初始化集群并注入调试二进制"
	@$(MAKE) cluster-create inject-binaries
	@echo ""
	@echo "✓ 环境就绪。运行 'make debug-all' 开启全链路调试。"

## ── 克隆源码 ──────────────────────────────────────────────────────────────────
clone: clone-k8s clone-containerd clone-runc clone-cni

clone-k8s:
	@bash scripts/01-clone-k8s.sh $(K8S_SRC) $(K8S_VERSION)

clone-containerd:
	@bash scripts/01-clone-containerd.sh $(CONTAINERD_SRC) $(CONTAINERD_VERSION)

clone-runc:
	@bash scripts/01-clone-runc.sh $(RUNC_SRC) $(RUNC_VERSION)

clone-cni:
	@bash scripts/01-clone-cni.sh $(CNI_SRC) $(CNI_VERSION)

## ── 编译 ──────────────────────────────────────────────────────────────────────
build-all: build-k8s build-containerd build-runc build-cni

build-k8s:
	@bash scripts/02-build-k8s.sh $(K8S_SRC) $(K8S_BUILD) "$(GOFLAGS_DEBUG)"

build-containerd:
	@bash scripts/02-build-containerd.sh $(CONTAINERD_SRC) $(RUNTIME_BUILD)

build-runc:
	@bash scripts/02-build-runc.sh $(RUNC_SRC) $(RUNTIME_BUILD)

build-runc-patched:
	@echo "==> 构建含 sleep 桩点的 runc（用于 dlv attach 调试）"
	@bash scripts/02-build-runc.sh $(RUNC_SRC) $(RUNTIME_BUILD) patched

build-cni:
	@bash scripts/02-build-cni.sh $(CNI_SRC) $(RUNTIME_BUILD)

## ── 离线镜像构建 ──────────────────────────────────────────────────────────────
build-offline-images:
	@bash scripts/03-build-offline-images.sh

## ── 集群管理（直接在 VM 上用 kubeadm）────────────────────────────────────────
cluster-create:
	@bash scripts/04-cluster-create.sh config/kubeadm-config.yaml

cluster-delete:
	@kubeadm reset --force 2>/dev/null || true
	@rm -rf /etc/kubernetes /var/lib/etcd $$HOME/.kube/config

cluster-status:
	@kubectl cluster-info 2>/dev/null || true
	@kubectl get nodes -o wide 2>/dev/null || true

## ── 注入调试二进制 ────────────────────────────────────────────────────────────
inject-binaries:
	@bash scripts/05-inject-binaries.sh $(K8S_BUILD) $(RUNTIME_BUILD)

inject-runc-patched:
	@bash scripts/05-inject-runc-patched.sh $(RUNTIME_BUILD)

## ── 调试 manifest 管理 ────────────────────────────────────────────────────────
setup-debug-manifests:
	@bash scripts/06-setup-debug-manifests.sh

restore-manifests:
	@bash scripts/06-setup-debug-manifests.sh restore

## ── 断点测试 ──────────────────────────────────────────────────────────────────
test-breakpoints:
	@bash scripts/08-test-breakpoints.sh

## ── 调试入口 ──────────────────────────────────────────────────────────────────
debug-all:
	@bash debug/all.sh

debug-apiserver:
	@bash debug/apiserver.sh

debug-controller:
	@bash debug/controller-manager.sh

debug-scheduler:
	@bash debug/scheduler.sh

debug-kubelet:
	@bash debug/kubelet.sh

debug-proxy:
	@bash debug/kube-proxy.sh

debug-containerd:
	@bash debug/containerd.sh

## ── 清理 ──────────────────────────────────────────────────────────────────────
clean:
	@$(MAKE) cluster-delete
	@rm -rf $(BUILD_DIR)
	@echo "✓ 已清理构建产物和集群"

clean-src:
	@rm -rf $(SRC_DIR)

## ── 帮助 ──────────────────────────────────────────────────────────────────────
help:
	@echo "Kubernetes 全链路源码调试环境（直接运行在 VM，无 Docker-in-Docker）"
	@echo ""
	@echo "快速开始:"
	@echo "  make setup              # 一键完整安装（依赖+编译+集群）"
	@echo ""
	@echo "分步操作:"
	@echo "  make clone              # 克隆所有源码"
	@echo "  make build-all          # 编译所有组件（带调试符号）"
	@echo "  make cluster-create     # kubeadm init 创建单节点集群"
	@echo "  make inject-binaries    # 注入调试版二进制到 /usr/local/bin"
	@echo ""
	@echo "调试:"
	@echo "  make debug-all          # 开启所有组件的 dlv 调试会话（tmux）"
	@echo "  make debug-apiserver    # 仅调试 kube-apiserver (port 2345)"
	@echo "  make debug-controller   # 仅调试 kube-controller-manager (port 2346)"
	@echo "  make debug-scheduler    # 仅调试 kube-scheduler (port 2347)"
	@echo "  make debug-kubelet      # 仅调试 kubelet (port 2348)"
	@echo "  make debug-proxy        # 仅调试 kube-proxy (port 2349)"
	@echo "  make debug-containerd   # 仅调试 containerd (port 2350)"
	@echo ""
	@echo "集群管理:"
	@echo "  make cluster-status     # 查看节点和 Pod 状态"
	@echo "  make cluster-delete     # kubeadm reset + 清理"
	@echo ""
	@echo "配置变量:"
	@echo "  K8S_VERSION=$(K8S_VERSION)  CONTAINERD_VERSION=$(CONTAINERD_VERSION)  RUNC_VERSION=$(RUNC_VERSION)"
	@echo ""
	@echo "注意: cgroup driver 使用 cgroupfs（本环境 systemd 不是 PID 1）"
