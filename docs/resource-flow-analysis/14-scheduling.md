# PriorityClass + PodDisruptionBudget + RuntimeClass

三个调度/运行时相关资源，各自独立但都影响 Pod 的调度与运行行为。

---

## PriorityClass

### 职责

PriorityClass 给 Pod 分配数字优先级（0–1,000,000,000）。高优先级 Pod 在资源不足时可以**抢占**低优先级 Pod。

### 接力图

```
kubectl apply -f priorityclass.yaml
    ↓
apiserver.Store.Create()   写入 PriorityClass（集群级别资源，无 namespace）
    ↓
Pod 创建时（带 spec.priorityClassName）
    ↓
PriorityAdmission plugin（apiserver 内）
    → 查找 PriorityClass，写入 Pod.Spec.Priority（整数值）
    ↓
scheduler.ScheduleOne()
    ├── Filter/Score 阶段：优先级用于排队顺序（高优先先调度）
    └── 资源不足时：抢占（Preemption）
        → 找可抢占节点（驱逐低优先 Pod 后能放下高优先 Pod）
        → 为低优先 Pod 设置 nominatedNodeName
        → 删除低优先 Pod（触发 Graceful Termination）
```

### PriorityAdmission Plugin

`plugin/pkg/admission/priority/admission.go`

```go
func (p *Plugin) Admit(ctx, a admission.Attributes, o admission.ObjectInterfaces) error {
    pod, ok := a.GetObject().(*api.Pod)
    if !ok {
        return nil
    }

    if pod.Spec.PriorityClassName == "" {
        // 没有指定 PriorityClassName，使用默认值（如果有）
        if p.defaultClass != nil {
            pod.Spec.PriorityClassName = p.defaultClass.Name
            pod.Spec.Priority = &p.defaultClass.Value
        }
        return nil
    }

    // 查找 PriorityClass
    pc, err := p.lister.Get(pod.Spec.PriorityClassName)
    pod.Spec.Priority = &pc.Value
    // pod.Spec.PreemptionPolicy = pc.PreemptionPolicy（Never 则不抢占其他 Pod）
    return nil
}
```

### 抢占（Preemption）

`pkg/scheduler/framework/plugins/preemption/preemption.go`

```go
func (pl *DefaultPreemption) PostFilter(ctx, state, pod, filteredNodeStatusMap) (*framework.PostFilterResult, *framework.Status) {
    // ← dlv 断点（Pod 无法调度时触发）

    // 找候选节点：哪些节点上删掉低优先 Pod 后能放下当前 Pod
    candidates, nodeToVictims, _ := pl.findCandidates(ctx, pod, filteredNodeStatusMap)

    // 选最佳候选节点（最少驱逐、PDB 影响最小）
    bestCandidate := pl.SelectCandidate(ctx, candidates)

    // 删除被抢占的低优先 Pod
    pl.prepareCandidate(ctx, bestCandidate, pod, pl.PluginName)
    // → 写入 pod.Status.NominatedNodeName = bestCandidate.Name
    // → DELETE 低优先 Pod（触发 GracefulTermination）
}
```

### 系统内置优先级

```yaml
# 已内置，不需要手动创建
system-cluster-critical:  2000000000  # kube-apiserver, kube-scheduler 等
system-node-critical:     2000001000  # kubelet, kube-proxy 等（比 cluster 高）
```

---

## PodDisruptionBudget（PDB）

### 职责

PDB 限制在维护操作（kubectl drain、滚动更新）期间同时中断的 Pod 数量，保护服务可用性。

### 接力图

```
kubectl apply -f pdb.yaml
    ↓
apiserver.Store.Create()   写入 PDB 对象
    ↓
DisruptionController.sync()
    → 统计当前 disrupted + healthy Pod 数，更新 PDB.Status
    ↓（当有驱逐/删除操作时）
Eviction API（/api/v1/namespaces/{ns}/pods/{name}/eviction）
    → EvictionAdmission plugin 检查 PDB
    → 允许或拒绝（429 Too Many Requests）
```

### DisruptionController

`pkg/controller/disruption/disruption.go`

```go
func (dc *DisruptionController) syncOne(ctx, key string) error {
    // ← dlv 断点

    pdb, _ := dc.pdbLister.PodDisruptionBudgets(namespace).Get(name)

    // 获取受 PDB 保护的 Pod
    selector, _ := metav1.LabelSelectorAsSelector(pdb.Spec.Selector)
    pods, _ := dc.podLister.Pods(pdb.Namespace).List(selector)

    // 统计健康（Ready）的 Pod 数
    _, currentHealthy := dc.currentHealthy(pods)
    expectedPods := int32(len(pods))

    // 计算允许的最大中断数
    pdb.Status.DisruptionsAllowed = pdb.Status.ExpectedPods - pdb.Status.DesiredHealthy
    // maxUnavailable: DesiredHealthy = expectedPods - maxUnavailable
    // minAvailable:   DesiredHealthy = minAvailable

    pdb.Status.CurrentHealthy = currentHealthy
    pdb.Status.ExpectedPods = expectedPods
    dc.kubeClient.PolicyV1().PodDisruptionBudgets(pdb.Namespace).UpdateStatus(ctx, pdb, ...)
}
```

### Eviction Admission

`pkg/registry/core/pod/storage/eviction.go`

```go
func (r *EvictionREST) Create(ctx, name, obj, createValidation, options) (runtime.Object, error) {
    // ← dlv 断点（kubectl drain 时触发）

    eviction := obj.(*policy.Eviction)
    pod, _ := r.store.Get(ctx, name, ...)

    // 检查 PDB
    pdbs, _ := r.getPodDisruptionBudgets(ctx, pod)
    for _, pdb := range pdbs {
        if pdb.Status.DisruptionsAllowed <= 0 {
            // PDB 不允许更多中断，拒绝驱逐
            return nil, errors.NewTooManyRequestsError("Cannot evict pod as it would violate PDB")
            // HTTP 429 → kubectl drain 会等待重试
        }
    }

    // 允许驱逐，删除 Pod
    r.store.Delete(ctx, pod.Name, ...)
}
```

---

## RuntimeClass

### 职责

RuntimeClass 允许为不同 Pod 选择不同的容器运行时（如 kata-containers、gVisor/runsc），提供更强的隔离性。

### 接力图

```
kubectl apply -f runtimeclass.yaml
    ↓
apiserver.Store.Create()   写入 RuntimeClass（集群级别资源）
    ↓
Pod 创建时（带 spec.runtimeClassName）
    ↓
scheduler 的 NodeAffinity 逻辑
    → RuntimeClass.Scheduling.NodeSelector / Tolerations 注入到 Pod
    → 确保 Pod 调度到支持该 runtime 的节点
    ↓
kubelet 收到 Pod
    → 查询 RuntimeClass 获取 handler 名
    → CRI RuntimeClassName 字段传给 containerd
    ↓
containerd 按 handler 选择 runtime shim
    → "runc"：默认 containerd-shim-runc-v2
    → "kata":  containerd-shim-kata-v2（QEMU VM 隔离）
    → "runsc": containerd-shim-runsc-v1（gVisor 用户态内核）
```

### RuntimeClass 对象

```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: kata-containers
handler: kata                    # 对应 containerd 配置中的 runtime handler
overhead:
  podFixed:
    memory: "160Mi"              # kata VM 自身开销，scheduler 计算时扣除
    cpu: "250m"
scheduling:
  nodeSelector:
    kata-containers: "true"      # 只调度到有 kata 的节点
  tolerations:
    - key: kata-containers
      operator: Exists
      effect: NoSchedule
```

### kubelet 处理 RuntimeClass

`pkg/kubelet/kuberuntime/kuberuntime_manager.go`

```go
func (m *kubeGenericRuntimeManager) runPodSandbox(ctx, pod, pullSecrets) (string, error) {
    // 获取 RuntimeClass
    runtimeClass := ""
    if pod.Spec.RuntimeClassName != nil {
        rc, _ := m.runtimeClassLister.Get(*pod.Spec.RuntimeClassName)
        runtimeClass = rc.Handler  // "kata" / "runsc" / ""
    }

    // 通过 CRI 创建 sandbox，传入 runtimeHandler
    podSandboxID, err := m.runtimeService.RunPodSandbox(ctx, podSandboxConfig, runtimeClass)
    // containerd 根据 runtimeHandler 选择对应的 shim 二进制
}
```

### containerd 配置

```toml
# /etc/containerd/config.toml
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes]

  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
    runtime_type = "io.containerd.runc.v2"

  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.kata]
    runtime_type = "io.containerd.kata.v2"

  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runsc]
    runtime_type = "io.containerd.runsc.v1"
```

---

## dlv 断点

```bash
# PriorityClass 抢占（scheduler，port 2347）
b k8s.io/kubernetes/pkg/scheduler/framework/plugins/preemption.(*DefaultPreemption).PostFilter

# PDB 驱逐检查（apiserver，port 2345）
b k8s.io/kubernetes/pkg/registry/core/pod/storage.(*EvictionREST).Create

# DisruptionController（controller-manager，port 2346）
b k8s.io/kubernetes/pkg/controller/disruption.(*DisruptionController).syncOne

# RuntimeClass 选择（kubelet，port 2348）
b k8s.io/kubernetes/pkg/kubelet/kuberuntime.(*kubeGenericRuntimeManager).runPodSandbox
```

---

## 相关文档

| 文档 | 说明 |
|------|------|
| `01-pod.md` | Pod 完整创建链路 |
| `13-hpa.md` | HPA 扩容时新 Pod 会使用 PriorityClass |
| `05-daemonset.md` | DaemonSet Pod 通常配置 system-node-critical 优先级 |
