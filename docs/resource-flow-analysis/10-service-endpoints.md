# Service + Endpoints + EndpointSlice 创建链路

Service 为一组 Pod 提供稳定的 VIP 和 DNS 名。EndpointSlice 跟踪这组 Pod 的实际地址，kube-proxy 把 VIP 规则写入内核。

**apiserver → etcd 路径**：见 `00-apiserver-common-flow.md`

---

## 接力图

```
kubectl apply -f service.yaml
    ↓
apiserver.Store.Create()   写入 Service（分配 ClusterIP）
    ↓ watch 事件（两路并行）
    ├── EndpointSliceController.syncService()
    │       ├── list Pod（labelSelector 匹配）
    │       ├── 为每个 Ready Pod 生成 Endpoint
    │       └── 创建/更新 EndpointSlice 对象
    └── CoreDNS（watch Service）
            → 更新 DNS 记录（{svc}.{ns}.svc.cluster.local → ClusterIP）
    ↓ EndpointSlice 写入 apiserver
kube-proxy watch EndpointSlice + Service
    ↓
syncProxyRules()
    ├── iptables 模式：iptables-restore 写入 KUBE-SERVICES 链规则
    └── ipvs 模式：ipvsadm 创建 virtual server + real server
```

---

## ClusterIP 分配

`pkg/registry/core/service/storage/storage.go`

```go
func (r *REST) Create(ctx, obj, createValidation, options) (runtime.Object, error) {
    service := obj.(*api.Service)

    if service.Spec.ClusterIP == "" && service.Spec.Type != api.ServiceTypeExternalName {
        // 从 service-cluster-ip-range 分配一个空闲 IP
        ip, err := r.serviceIPAllocator.AllocateNext()
        service.Spec.ClusterIP = ip.String()
        // 分配结果写入 etcd（/registry/services/specs/{ns}/{name}）
        // 同时更新 /registry/ranges/serviceips（IP 位图）
    }
}
```

ClusterIP 一旦分配，与 Service 共存亡——Service 删除时 IP 被回收。

---

## EndpointSliceController

`pkg/controller/endpointslice/endpointslice_controller.go`

### 触发条件

```go
func NewController(ctx, podInformer, serviceInformer, nodeInformer, endpointSliceInformer, ...) *Controller {
    esm := &Controller{}

    // Service 变更时触发
    serviceInformer.Informer().AddEventHandler(cache.ResourceEventHandlerFuncs{
        AddFunc:    esm.onServiceUpdate,
        UpdateFunc: esm.onServiceUpdate,
        DeleteFunc: esm.onServiceDelete,
    })

    // Pod 变更时触发（最关键：Pod Ready 状态变化）
    podInformer.Informer().AddEventHandler(cache.ResourceEventHandlerFuncs{
        AddFunc:    esm.addPod,
        UpdateFunc: esm.updatePod,  // ← Pod 变 Ready 时触发
        DeleteFunc: esm.deletePod,
    })
}
```

### 核心调谐

```go
func (c *Controller) syncService(ctx, key string) error {
    // ← dlv 断点

    namespace, name, _ := cache.SplitMetaNamespaceKey(key)
    service, _ := c.serviceLister.Services(namespace).Get(name)

    // 获取匹配 Service.Spec.Selector 的所有 Pod
    pods, _ := c.podLister.Pods(namespace).List(selector)

    // 获取现有的 EndpointSlice
    existingSlices, _ := c.endpointSliceLister.EndpointSlices(namespace).List(
        labels.Set{discovery.LabelServiceName: name}.AsSelector())

    // 生成期望的 Endpoint 列表
    desiredSet := c.reconciler.newEndpointSlices(service, pods)
    // 每个 Ready Pod 的每个 containerPort 生成一个 Endpoint
    // Endpoint 包含：IP、Port、Ready 状态、hostname、topology 信息

    // 与现有 EndpointSlice 对比，增删改
    c.reconciler.reconcile(service, pods, existingSlices, triggerTime)
}
```

### Endpoint 生成规则

```go
func podToEndpoint(pod *v1.Pod, node *v1.Node, service *v1.Service, addressType discovery.AddressType) discovery.Endpoint {
    // 只包含 Ready 且不在 Terminating 状态的 Pod
    ready := podutil.IsPodReady(pod) && !pod.DeletionTimestamp != nil
    serving := podutil.IsPodReady(pod)

    ep := discovery.Endpoint{
        Addresses: []string{pod.Status.PodIP},  // 或 PodIPs[IPv6]
        Conditions: discovery.EndpointConditions{
            Ready:       &ready,
            Serving:     &serving,
            Terminating: pointer.Bool(pod.DeletionTimestamp != nil),
        },
        NodeName:  &pod.Spec.NodeName,
        TargetRef: &v1.ObjectReference{Kind: "Pod", Name: pod.Name, ...},
        // 拓扑信息（用于拓扑感知路由）
        Zone: node.Labels[v1.LabelTopologyZone],
    }
    return ep
}
```

### EndpointSlice 分片

每个 EndpointSlice 最多 100 个 Endpoint（`maxEndpointsPerSlice`）。大 Service 会有多个 EndpointSlice：

```go
// pkg/controller/endpointslice/reconciler.go
func (r *Reconciler) reconcile(service, pods, existingSlices, triggerTime) error {
    // 将 desired endpoints 按 100 个一组打包到 EndpointSlice
    // 尽量复用现有 EndpointSlice（减少写操作）
    // 新建/更新/删除 EndpointSlice
    toCreate, toUpdate, toDelete := r.diffEndpointSlices(existingSlices, desiredSlices)

    for _, slice := range toCreate {
        r.client.DiscoveryV1().EndpointSlices(namespace).Create(ctx, slice, ...)
    }
    for _, slice := range toUpdate {
        r.client.DiscoveryV1().EndpointSlices(namespace).Update(ctx, slice, ...)
    }
    for _, slice := range toDelete {
        r.client.DiscoveryV1().EndpointSlices(namespace).Delete(ctx, slice.Name, ...)
    }
}
```

---

## kube-proxy：写入内核规则

`pkg/proxy/iptables/proxier.go`（iptables 模式）

### 触发

```go
func NewProxier(syncPeriod, minSyncPeriod, ...) (*Proxier, error) {
    proxier := &Proxier{
        serviceChanges:      proxy.NewServiceChangeTracker(...),
        endpointsChanges:    proxy.NewEndpointChangeTracker(...),
    }

    // watch Service 和 EndpointSlice 变更
    // 变更入队，按 minSyncPeriod 批量处理
}
```

### syncProxyRules

```go
func (proxier *Proxier) syncProxyRules() {
    // ← dlv 断点（kube-proxy 进程）

    // 构造 iptables 规则（全量重算）
    proxier.iptablesData.Reset()

    // KUBE-SERVICES 链：ClusterIP 的入口
    for svcName, svcInfo := range proxier.svcPortMap {
        // -A KUBE-SERVICES -d <ClusterIP>/32 -p tcp --dport <Port>
        //   -m comment --comment "default/nginx cluster IP"
        //   -j KUBE-SVC-XXXX

        // KUBE-SVC-XXXX：随机选择 Endpoint（DNAT 负载均衡）
        for i, ep := range endpointChains {
            // -A KUBE-SVC-XXXX -m statistic --mode random --probability 1/N
            //   -j KUBE-SEP-YYYY（第 i 个 Endpoint）

            // KUBE-SEP-YYYY：DNAT 到具体 Pod IP
            // -A KUBE-SEP-YYYY -p tcp -j DNAT --to-destination <PodIP>:<Port>
        }
    }

    // KUBE-NODEPORTS 链：NodePort 的入口
    // KUBE-EXTERNAL-IP 链：ExternalIP / LoadBalancer

    // 一次性原子写入 iptables
    proxier.iptables.RestoreAll(proxier.iptablesData.Bytes(), utiliptables.NoFlushTables, ...)
    // 底层调用：iptables-restore
    // syscall: execve("/usr/sbin/iptables-restore", ...)
}
```

### ipvs 模式

`pkg/proxy/ipvs/proxier.go`

```go
func (proxier *Proxier) syncProxyRules() {
    // 使用 ipvsadm 创建/更新 virtual server
    proxier.ipvs.AddVirtualServer(&utilipvs.VirtualServer{
        Address:   net.ParseIP(clusterIP),
        Port:      uint16(svcInfo.Port()),
        Protocol:  string(svcInfo.Protocol()),
        Scheduler: proxier.ipvsScheduler,  // rr / lc / wrr 等
    })

    // 为每个 Endpoint 添加 real server
    proxier.ipvs.AddRealServer(vs, &utilipvs.RealServer{
        Address: net.ParseIP(epInfo.IP()),
        Port:    uint16(epInfo.Port()),
        Weight:  1,
    })
    // syscall: socket(AF_NETLINK) + sendmsg（netlink 接口操作 IPVS）
}
```

---

## Service 类型与处理差异

| Service 类型 | ClusterIP | kube-proxy 额外操作 |
|-------------|-----------|-------------------|
| ClusterIP | 分配 VIP | DNAT 规则 |
| NodePort | 分配 VIP | 额外监听 nodePort（每个节点） |
| LoadBalancer | 分配 VIP | 通知 cloud-controller-manager 创建云 LB |
| ExternalName | 不分配 | DNS CNAME 记录（CoreDNS 处理） |
| Headless（clusterIP: None） | 不分配 | 不创建 iptables 规则，DNS 直接返回 Pod IP |

---

## CoreDNS

watch Service 和 EndpointSlice，维护以下 DNS 记录：

```
{svc}.{ns}.svc.cluster.local → ClusterIP（A/AAAA）
{pod-ip-dashed}.{ns}.pod.cluster.local → PodIP（A）
_port._proto.{svc}.{ns}.svc.cluster.local → SRV 记录
```

Headless Service：直接返回所有 Pod IP（多 A 记录）。

---

## dlv 断点

```bash
# controller-manager（port 2346）
b k8s.io/kubernetes/pkg/controller/endpointslice.(*Controller).syncService

# kube-proxy（需要单独 dlv attach）
b k8s.io/kubernetes/pkg/proxy/iptables.(*Proxier).syncProxyRules
b k8s.io/kubernetes/pkg/proxy/ipvs.(*Proxier).syncProxyRules
```

---

## strace（kube-proxy）

```bash
# iptables 模式：观察 iptables-restore 调用
strace -p <kube-proxy-PID> -f -e trace=execve 2>&1 | grep iptables

# ipvs 模式：观察 netlink socket 操作
strace -p <kube-proxy-PID> -f -e trace=socket,sendmsg,recvmsg 2>&1 | grep NETLINK
```

---

## 相关文档

| 文档 | 说明 |
|------|------|
| `11-ingress.md` | Ingress：L7 负载均衡 |
| `12-networkpolicy.md` | NetworkPolicy：Pod 间访问控制 |
| `01-pod.md` | Pod Ready 状态如何影响 Endpoint |
