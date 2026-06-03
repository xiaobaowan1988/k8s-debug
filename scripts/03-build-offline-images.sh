#!/usr/bin/env bash
# 在网络受限环境中构建 Kubernetes 控制平面所需的容器镜像
# 策略：从 dl.k8s.io / github releases 下载静态链接二进制，
#       用 FROM scratch 构建本地镜像，导入 containerd k8s.io namespace
set -euo pipefail

K8S_VERSION="${K8S_VERSION:-1.32.0}"
ETCD_VERSION="${ETCD_VERSION:-3.5.16}"
COREDNS_VERSION="${COREDNS_VERSION:-1.11.3}"
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  GOARCH=amd64 ;;
  aarch64) GOARCH=arm64 ;;
  *)       echo "不支持的架构: $ARCH"; exit 1 ;;
esac

BUILD_DIR="/tmp/k8s-offline-imgs"
BINS_DIR="/tmp/k8s-offline-bins"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }

mkdir -p "$BUILD_DIR" "$BINS_DIR"

# 检查镜像是否已在 containerd 中
img_exists() {
    ctr -n k8s.io images list 2>/dev/null | grep -q "^$1 " 2>/dev/null
}

# 构建并导入单个镜像
build_and_import() {
    local tag="$1"
    local bin_src="$2"
    local bin_name="$3"
    local entrypoint="$4"
    local img_dir="${BUILD_DIR}/${bin_name}"

    if img_exists "$tag"; then
        ok "  镜像已存在: $tag"
        return
    fi

    info "  构建 $tag ..."
    mkdir -p "$img_dir"
    cp "$bin_src" "${img_dir}/${bin_name}"
    cat > "${img_dir}/Dockerfile" << DEOF
FROM scratch
COPY ${bin_name} ${entrypoint}
CMD ["${entrypoint}"]
DEOF
    docker build -t "$tag" "$img_dir/" -q 2>&1
    docker save "$tag" | ctr -n k8s.io images import - 2>&1 | grep -v "^$" | grep -v "^time=" | tail -1
    ok "  $tag 已导入"
}

# ── 1. 下载 k8s 服务端二进制 ─────────────────────────────────────────────────
info "检查 Kubernetes 服务端二进制..."
for bin in kube-apiserver kube-controller-manager kube-scheduler; do
    dest="${BINS_DIR}/${bin}"
    if [[ ! -f "$dest" ]]; then
        info "  下载 $bin..."
        curl -fsSL "https://dl.k8s.io/release/v${K8S_VERSION}/bin/linux/${GOARCH}/${bin}" \
            -o "$dest"
        chmod +x "$dest"
    fi
done
ok "k8s 服务端二进制就绪"

# ── 2. 下载 etcd ─────────────────────────────────────────────────────────────
if [[ ! -f "${BINS_DIR}/etcd" ]]; then
    info "下载 etcd v${ETCD_VERSION}..."
    curl -fsSL "https://github.com/etcd-io/etcd/releases/download/v${ETCD_VERSION}/etcd-v${ETCD_VERSION}-linux-${GOARCH}.tar.gz" \
        -o /tmp/etcd.tar.gz
    tar -xzf /tmp/etcd.tar.gz -C "$BINS_DIR" --strip-components=1 \
        "etcd-v${ETCD_VERSION}-linux-${GOARCH}/etcd" \
        "etcd-v${ETCD_VERSION}-linux-${GOARCH}/etcdctl"
fi
ok "etcd 二进制就绪"

# ── 3. 下载 coredns ───────────────────────────────────────────────────────────
if [[ ! -f "${BINS_DIR}/coredns" ]]; then
    info "下载 coredns v${COREDNS_VERSION}..."
    curl -fsSL "https://github.com/coredns/coredns/releases/download/v${COREDNS_VERSION}/coredns_${COREDNS_VERSION}_linux_${GOARCH}.tgz" \
        -o /tmp/coredns.tgz
    tar -xzf /tmp/coredns.tgz -C "$BINS_DIR" coredns
fi
ok "coredns 二进制就绪"

# ── 4. 编译 pause ─────────────────────────────────────────────────────────────
if [[ ! -f "${BINS_DIR}/pause" ]]; then
    info "编译 pause（静态链接 C 程序）..."
    cat > /tmp/pause.c << 'CEOF'
#include <signal.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
static volatile int g_sigcount = 0;
static void sigdown(int signo) { (void)signo; g_sigcount++; }
static void sigreap(int signo) { (void)signo; while (waitpid(-1, NULL, WNOHANG) > 0); }
int main(void) {
    signal(SIGINT, sigdown); signal(SIGTERM, sigdown); signal(SIGCHLD, sigreap);
    for (;;) { pause(); if (g_sigcount > 0) break; }
    return 0;
}
CEOF
    gcc -static -o "${BINS_DIR}/pause" /tmp/pause.c
fi
ok "pause 二进制就绪"

# ── 5. 构建并导入镜像 ─────────────────────────────────────────────────────────
info "构建并导入容器镜像..."

# 检查 containerd socket
[[ -S /run/containerd/containerd.sock ]] || {
    warn "containerd 未运行，跳过镜像导入"
    exit 0
}

build_and_import \
    "registry.k8s.io/kube-apiserver:v${K8S_VERSION}" \
    "${BINS_DIR}/kube-apiserver" \
    "kube-apiserver" \
    "/usr/local/bin/kube-apiserver"

build_and_import \
    "registry.k8s.io/kube-controller-manager:v${K8S_VERSION}" \
    "${BINS_DIR}/kube-controller-manager" \
    "kube-controller-manager" \
    "/usr/local/bin/kube-controller-manager"

build_and_import \
    "registry.k8s.io/kube-scheduler:v${K8S_VERSION}" \
    "${BINS_DIR}/kube-scheduler" \
    "kube-scheduler" \
    "/usr/local/bin/kube-scheduler"

build_and_import \
    "registry.k8s.io/etcd:${ETCD_VERSION}-0" \
    "${BINS_DIR}/etcd" \
    "etcd" \
    "/usr/local/bin/etcd"

build_and_import \
    "registry.k8s.io/coredns/coredns:v${COREDNS_VERSION}" \
    "${BINS_DIR}/coredns" \
    "coredns" \
    "/coredns"

# pause 需要两个 tag
if ! img_exists "registry.k8s.io/pause:3.10"; then
    build_and_import \
        "registry.k8s.io/pause:3.10" \
        "${BINS_DIR}/pause" \
        "pause" \
        "/pause"
fi
# containerd 默认用 3.10.1
if ! img_exists "registry.k8s.io/pause:3.10.1"; then
    ctr -n k8s.io images tag registry.k8s.io/pause:3.10 registry.k8s.io/pause:3.10.1 2>/dev/null || true
    ok "  registry.k8s.io/pause:3.10.1 (tag)"
fi

echo ""
ok "所有离线镜像就绪"
ctr -n k8s.io images list 2>/dev/null | grep "registry.k8s.io" | awk '{print "  " $1}'
