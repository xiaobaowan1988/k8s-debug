# NetworkPolicy 创建链路

NetworkPolicy 定义 Pod 间的网络访问控制规则（L3/L4）。K8s 本身只存储 NetworkPolicy 对象，**实际的规则强制执行由 CNI plugin 完成**——不同 CNI 实现方式不同（iptables、eBPF、OVS 等）。

**apiserver → etcd 路径**：见 `00-apiserver-common-flow.md`

---

## 接力图

```
kubectl apply -f networkpolicy.yaml
    ↓
apiserver.Store.Create()   写入 NetworkPolicy 对象
    ↓ watch 事件
CNI plugin agent（DaemonSet，每节点一个）
    └── 监听 NetworkPolicy + Pod + Namespace 变更
    ↓
下发内核规则（按 CNI 实现不同）：
    ├── Calico:   felix agent → iptables/nftables 规则
    ├── Cilium:   cilium-agent → eBPF 程序加载到内核
    ├── Flannel:  不支持 NetworkPolicy（需要额外 kube-flannel）
    └── WeaveNet: weave-npc → iptables 规则
```

---

## NetworkPolicy 规范

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: api-allow
  namespace: production
spec:
  podSelector:
    matchLabels:
      app: api          # 规则应用到哪些 Pod
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              purpose: frontend    # 允许来自 frontend namespace 的 Pod
        - podSelector:
            matchLabels:
              app: monitor         # 允许来自同 namespace 的 monitor Pod
      ports:
        - protocol: TCP
          port: 8080
  egress:
    - to:
        - ipBlock:
            cidr: 10.0.0.0/8
            except: [10.0.0.0/24]
      ports:
        - protocol: TCP
          port: 5432              # 允许访问 10.0.0.0/8 的 5432 端口（除 /24 子网）
```

**默认行为**：没有 NetworkPolicy 选中某 Pod 时，该 Pod 接受所有流量。一旦被任何 NetworkPolicy 选中，未被明确允许的流量都被拒绝。

---

## Calico：felix 实现

`github.com/projectcalico/calico/felix/`

### 监听 K8s 资源

```go
// felix/k8sfv/felixconfig.go + felix/dataplane/linux/
func (d *InternalDataplane) Start() {
    // Calico 使用自己的 CRD（GlobalNetworkPolicy, NetworkPolicy 等）
    // 同时也处理 K8s 原生 NetworkPolicy
    d.k8sNetworkPolicyWatcher.Watch(ctx)
}
```

### 规则生成（iptables 模式）

```go
// felix/iptables/table.go
func (t *Table) Apply() {
    // 每个 NetworkPolicy 生成一组 iptables 链
    // Pod 的每个方向（ingress/egress）有对应链：
    //   cali-pi-{policy-hash}（policy ingress）
    //   cali-po-{policy-hash}（policy egress）

    // 每个 Pod 有 workload 链：
    //   cali-tw-{interface}（to workload，入方向）
    //   cali-fw-{interface}（from workload，出方向）

    // 规则示例：
    // -A cali-pi-xxx -s 10.0.1.0/24 -p tcp --dport 8080 -j ACCEPT
    // -A cali-pi-xxx -j DROP（默认拒绝）

    // syscall: execve("/usr/sbin/iptables-restore", ...)
    t.iptables.RestoreAll(buf.Bytes(), ...)
}
```

---

## Cilium：eBPF 实现

`github.com/cilium/cilium/daemon/`

### NetworkPolicy 转换为 eBPF 程序

```go
// pkg/policy/distillery.go
func (cache *PolicyCache) distillPolicy(identity *Identity, identities cache.IdentityCache) (*distillery.cachedSelectorPolicy, error) {
    // NetworkPolicy 中的 selector 转换为 numeric identity
    // 每个 namespace/label 组合被分配一个唯一的 numeric security identity

    // 生成 eBPF map 条目：
    // key: {src_identity, dst_port, protocol}
    // value: allow/deny
    policyMap.Update(key, value, ...)
}
```

### eBPF 程序挂载到网络接口

```go
// pkg/datapath/linux/probes/
func (l *loader) reloadDatapath(ctx, ep) error {
    // 为每个 Pod 的 veth 接口加载 eBPF 程序
    // tc（traffic control）挂载点：ingress 和 egress

    // 加载 BPF 目标文件
    spec, _ := ebpf.LoadCollectionSpec("/var/lib/cilium/bpf/bpf_lxc.o")
    coll, _ := ebpf.NewCollection(spec)

    // 挂载到 tc ingress hook
    // syscall: bpf(BPF_PROG_LOAD, ...) + bpf(BPF_MAP_UPDATE_ELEM, ...)
    netlink.FilterAdd(&netlink.BpfFilter{
        FilterAttrs: netlink.FilterAttrs{
            LinkIndex: linkIndex,
            Parent:    netlink.HANDLE_MIN_INGRESS,
        },
        Fd:           coll.Programs["handle_xgress"].FD(),
        DirectAction: true,
    })
}
```

eBPF 程序在内核数据平面执行，每个数据包到达时查询 policy map 决定允许/丢弃，无需经过 iptables。

---

## K8s 层面：没有内置 controller

与其他资源不同，NetworkPolicy 在 K8s control plane 里**没有 controller**处理它：

```go
// pkg/controller/networkpolicy/ ← 该目录不存在
```

NetworkPolicy 只是一个数据声明，存在 etcd 里。完全由 CNI plugin 自己 watch 并实现。

这就是为什么不装 CNI 或 CNI 不支持 NetworkPolicy 时，规则不生效但也不报错。

---

## 验证 NetworkPolicy 是否生效

```bash
# 查看 iptables 规则（Calico/Flannel）
iptables -L -n | grep -E 'cali|KUBE-NET'

# 查看 eBPF 程序（Cilium）
cilium policy get
bpftool prog list
bpftool map dump id <policy-map-id>

# 测试连通性
kubectl exec -n production -it test-pod -- curl http://api-svc:8080
```

---

## strace（CNI agent）

```bash
# Calico felix：观察 iptables-restore 调用
strace -p <felix-PID> -f -e trace=execve 2>&1 | grep iptables

# Cilium agent：观察 eBPF 程序加载
strace -p <cilium-PID> -f -e trace=bpf 2>&1 | head -50
```

---

## 相关文档

| 文档 | 说明 |
|------|------|
| `10-service-endpoints.md` | Service：NetworkPolicy 通常与 Service 配合使用 |
| `01-pod.md` | Pod 网络接口的创建（RunPodSandbox + CNI） |
