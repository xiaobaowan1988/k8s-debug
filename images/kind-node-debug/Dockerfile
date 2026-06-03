FROM kindest/node:local-base

# Fix for nested Docker: use native snapshotter (no overlayfs needed)
# and cgroupfs cgroup driver (avoids systemd cgroup path format issues).
RUN sed -i 's/snapshotter = "overlayfs"/snapshotter = "native"/' /etc/containerd/config.toml && \
    sed -i 's/SystemdCgroup = true/SystemdCgroup = false/g' /etc/containerd/config.toml

# Fix for nested Docker: restrict_oom_score_adj=true prevents runc/nsexec
# from trying to write oomScoreAdj=-998 without CAP_SYS_RESOURCE.
# containerd reads its own oom_score_adj (0) and clamps container values
# to max(0, requested), so nsexec writes 0 instead of -998 → no EACCES.
RUN sed -i 's/restrict_oom_score_adj = false/restrict_oom_score_adj = true/' /etc/containerd/config.toml

# Fix for nested Docker: create kubelet cgroup dirs under cpuset and hugetlb.
# Docker doesn't scope these controllers to the container, so kind's entrypoint
# skips them. We create them before kubelet starts via an ExecStartPre drop-in.
RUN cat > /usr/local/bin/setup-kubelet-cgroups.sh << 'SCRIPT'
#!/bin/bash
for controller in cpuset hugetlb; do
    base="/sys/fs/cgroup/${controller}"
    [ -d "${base}" ] || continue
    for dir in kubelet kubelet.slice; do
        target="${base}/${dir}"
        if [ ! -d "${target}" ]; then
            mkdir -p "${target}"
            if [ "${controller}" = "cpuset" ]; then
                cat "${base}/cpuset.cpus" > "${target}/cpuset.cpus" 2>/dev/null || true
                cat "${base}/cpuset.mems" > "${target}/cpuset.mems" 2>/dev/null || true
            fi
        fi
    done
done
SCRIPT
RUN chmod +x /usr/local/bin/setup-kubelet-cgroups.sh && \
    mkdir -p /etc/systemd/system/kubelet.service.d && \
    printf '[Service]\nExecStartPre=/usr/local/bin/setup-kubelet-cgroups.sh\n' \
    > /etc/systemd/system/kubelet.service.d/50-setup-cgroups.conf

# Pre-load Kubernetes container images (built from source with debug symbols)
COPY *.tar /tmp/kind-imgs/

RUN containerd --log-level=error & \
    CONTAINERD_PID=$! && \
    for i in $(seq 1 30); do \
        [ -S /run/containerd/containerd.sock ] && break; \
        sleep 1; \
    done && \
    for f in /tmp/kind-imgs/*.tar; do \
        ctr -n k8s.io images import "$f" 2>&1 || true; \
    done && \
    kill $CONTAINERD_PID && \
    wait $CONTAINERD_PID 2>/dev/null || true && \
    rm -rf /tmp/kind-imgs
