K8S_VERSION   ?= v1.32.0
CONTAINERD_VERSION ?= v2.0.1
RUNC_VERSION   ?= v1.2.3
CNI_VERSION    ?= v1.6.0
KIND_VERSION   ?= v0.26.0
DELVE_VERSION  ?= v1.23.1

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

# Kind 集群配置
KIND_CLUSTER   ?= k8s-debug
KIND_IMAGE     ?= registry.k8s.io/kindest/node:$(K8S_VERSION)
KIND_NODE_IMG  ?= kindest/node:local-debug

GOFLAGS_DEBUG  := -gcflags=all="-N -l"

.PHONY: all setup clone build-k8s build-containerd build-runc build-cni \
        build-kind-image cluster-create cluster-delete inject-binaries \
        debug-all clean help

all: help

## ── 一键安装 ──────────────────────────────────────────────────────────────────
setup:
	@echo "==> [1/5] 安装系统依赖"
	@bash scripts/00-install-deps.sh
	@echo "==> [2/5] 克隆所有源码"
	@$(MAKE) clone
	@echo "==> [3/5] 编译所有组件（带调试符号）"
	@$(MAKE) build-all
	@echo "==> [4/5] 构建 Kind 节点镜像"
	@$(MAKE) build-kind-image
	@echo "==> [5/5] 创建调试集群并注入二进制"
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

## ── Kind 节点镜像（从 k8s 源码构建）────────────────────────────────────────────
build-kind-image:
	@bash scripts/03-build-kind-image.sh $(K8S_SRC) $(KIND_NODE_IMG)

## ── 集群管理 ──────────────────────────────────────────────────────────────────
cluster-create:
	@bash scripts/04-cluster-create.sh $(KIND_CLUSTER) $(KIND_NODE_IMG) config/kind-cluster.yaml

cluster-delete:
	@kind delete cluster --name $(KIND_CLUSTER) 2>/dev/null || true

cluster-status:
	@kubectl cluster-info --context kind-$(KIND_CLUSTER) 2>/dev/null
	@kubectl get nodes -o wide 2>/dev/null

## ── 注入调试二进制 ────────────────────────────────────────────────────────────
inject-binaries:
	@bash scripts/05-inject-binaries.sh $(KIND_CLUSTER) $(K8S_BUILD) $(RUNTIME_BUILD)

inject-runc-patched:
	@bash scripts/05-inject-runc-patched.sh $(KIND_CLUSTER) $(RUNTIME_BUILD)

## ── 调试入口 ──────────────────────────────────────────────────────────────────
debug-all:
	@bash debug/all.sh $(KIND_CLUSTER)

debug-apiserver:
	@bash debug/apiserver.sh $(KIND_CLUSTER)

debug-controller:
	@bash debug/controller-manager.sh $(KIND_CLUSTER)

debug-scheduler:
	@bash debug/scheduler.sh $(KIND_CLUSTER)

debug-kubelet:
	@bash debug/kubelet.sh $(KIND_CLUSTER)

debug-proxy:
	@bash debug/kube-proxy.sh $(KIND_CLUSTER)

debug-containerd:
	@bash debug/containerd.sh $(KIND_CLUSTER)

## ── 清理 ──────────────────────────────────────────────────────────────────────
clean:
	@$(MAKE) cluster-delete
	@rm -rf $(BUILD_DIR)
	@echo "✓ 已清理构建产物和集群"

clean-src:
	@rm -rf $(SRC_DIR)

## ── 帮助 ──────────────────────────────────────────────────────────────────────
help:
	@echo "Kubernetes 全链路源码调试环境"
	@echo ""
	@echo "快速开始:"
	@echo "  make setup              # 一键完整安装（依赖+编译+集群）"
	@echo ""
	@echo "分步操作:"
	@echo "  make clone              # 克隆所有源码"
	@echo "  make build-all          # 编译所有组件（带调试符号）"
	@echo "  make build-kind-image   # 从 k8s 源码构建 Kind 节点镜像"
	@echo "  make cluster-create     # 创建调试集群"
	@echo "  make inject-binaries    # 注入调试版二进制到集群节点"
	@echo ""
	@echo "调试:"
	@echo "  make debug-all          # 开启所有组件的 dlv 调试会话（tmux）"
	@echo "  make debug-apiserver    # 仅调试 kube-apiserver"
	@echo "  make debug-scheduler    # 仅调试 kube-scheduler"
	@echo "  make debug-kubelet      # 仅调试 kubelet"
	@echo "  make debug-containerd   # 仅调试 containerd"
	@echo ""
	@echo "配置变量:"
	@echo "  K8S_VERSION=$(K8S_VERSION)  CONTAINERD_VERSION=$(CONTAINERD_VERSION)  RUNC_VERSION=$(RUNC_VERSION)"
