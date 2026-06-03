FROM kindest/base:local

# Trust sandbox TLS inspection CA (only needed in Anthropic's sandbox environment)
COPY anthropic-sandbox.crt /usr/local/share/ca-certificates/
RUN update-ca-certificates

# Pre-built Kubernetes binaries with debug symbols (DBG=1, no inlining)
COPY k8s-bins/ /usr/local/bin/

# kubeadm requires kubelet at /usr/bin
RUN cp /usr/local/bin/kubelet /usr/bin/kubelet

RUN chmod +x /usr/local/bin/kube-* /usr/local/bin/kubectl /usr/local/bin/kubelet

ARG K8S_VERSION=v1.32.0
LABEL io.k8s.sigs.kind.node-image-config="{\"kubernetesVersion\": \"${K8S_VERSION}\"}"

RUN mkdir -p /etc/kubernetes/manifests

RUN echo "${K8S_VERSION}" > /kind/version

ENTRYPOINT ["/usr/local/bin/entrypoint", "/sbin/init"]
