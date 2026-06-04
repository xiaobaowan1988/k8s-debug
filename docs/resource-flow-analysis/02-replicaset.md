# ReplicaSet 创建链路

ReplicaSet 维护指定数量的 Pod 副本。通常不直接创建，而是由 Deployment controller 代为管理。直接创建场景较少见，但理解 RS controller 是理解 Deployment 的前提。

**apiserver → etcd 路径**：见 `00-apiserver-common-flow.md`
**Pod 创建尾部**：见 `01-pod.md`（scheduler → kubelet → CRI → 内核）

---

## 接力图

```
kubectl apply -f replicaset.yaml
    ↓
apiserver.Store.Create()   写入 ReplicaSet 对象
    ↓ watch 事件
ReplicaSetController.syncReplicaSet()
    ├── 计算差值：期望副本数 - 当前 Pod 数
    ├── scale up：批量创建 Pod（burst 策略）
    └── scale down：选择并删除多余 Pod
    ↓ 每个 Pod 写入 apiserver
Scheduler → Kubelet → CRI → kernel（见 01-pod.md）
```

---

## ReplicaSetController

`pkg/controller/replicaset/replica_set.go`

### 启动与 informer 注册

```go
func NewReplicaSetController(ctx, rsInformer, podInformer, kubeClient, burstReplicas) *ReplicaSetController {
    rsc := &ReplicaSetController{
        kubeClient:    kubeClient,
        burstReplicas: burstReplicas,      // 默认 500：单次最多创建 500 个 Pod
        queue:         workqueue.NewRateLimitingQueue(...),
    }

    // watch ReplicaSet 变更
    rsInformer.Informer().AddEventHandler(cache.ResourceEventHandlerFuncs{
        AddFunc:    rsc.addRS,
        UpdateFunc: rsc.updateRS,
        DeleteFunc: rsc.deleteRS,
    })

    // watch Pod 变更（用于调整副本计数）
    podInformer.Informer().AddEventHandler(cache.ResourceEventHandlerFuncs{
        AddFunc:    rsc.addPod,
        UpdateFunc: rsc.updatePod,
        DeleteFunc: rsc.deletePod,
    })
}
```

### 核心调谐循环

```go
func (rsc *ReplicaSetController) syncReplicaSet(ctx, key string) error {
    // ← dlv 断点

    namespace, name, _ := cache.SplitMetaNamespaceKey(key)
    rs, _ := rsc.rsLister.ReplicaSets(namespace).Get(name)

    // 获取所有属于这个 RS 的 Pod（通过 LabelSelector）
    allPods, _ := rsc.podLister.Pods(rs.Namespace).List(labels.Everything())
    filteredPods := rsc.claimPods(ctx, rs, selector, filteredPods)
    // claimPods 处理孤儿 Pod（有 ControllerRef 但 RS 不存在的 Pod）

    // 当前活跃 Pod 数
    activePods := controller.FilterActivePods(filteredPods)

    // 计算差值
    diff := len(activePods) - int(*(rs.Spec.Replicas))

    if diff < 0 {
        // scale up：需要创建 -diff 个 Pod
        rsc.slowStartBatch(-diff, controller.SlowStartInitialBatchSize,
            func() error {
                return rsc.podControl.CreatePodsWithGenerateName(
                    ctx, rs.Namespace, &rs.Spec.Template,
                    rs, metav1.NewControllerRef(rs, ...))
                // → POST /api/v1/namespaces/{ns}/pods
            })
    } else if diff > 0 {
        // scale down：选择并删除 diff 个 Pod
        podsToDelete := getPodsToDelete(filteredPods, relatedPods, diff)
        rsc.podControl.DeletePod(ctx, rs.Namespace, pod.Name, rs)
    }

    // 更新 RS 状态
    newStatus := calculateStatus(rs, filteredPods, manageReplicasErr)
    rsc.updateReplicaSetStatus(ctx, rs, newStatus)
}
```

### slowStartBatch（防止雪崩）

```go
// pkg/controller/controller_utils.go
func slowStartBatch(count int, initialBatchSize int, fn func() error) (int, error) {
    // 第 1 批：创建 initialBatchSize（默认 1）个 Pod
    // 第 2 批：创建 2 个
    // 第 3 批：创建 4 个
    // ...指数增长直到 count 全部完成
    // 任何一批失败，停止并返回已成功数量
    batchSize := integer.IntMin(count, initialBatchSize)
    for batchSize > 0 {
        // 并发创建当前批次
        errCh := make(chan error, batchSize)
        var wg sync.WaitGroup
        for i := 0; i < batchSize; i++ {
            wg.Add(1)
            go func() {
                defer wg.Done()
                errCh <- fn()
            }()
        }
        wg.Wait()
        // ...
        batchSize = integer.IntMin(2*batchSize, count-successes)
    }
}
```

### Pod 命名规则

```go
// pkg/controller/controller_utils.go
func (r RealPodControl) CreatePodsWithGenerateName(...) error {
    pod := &v1.Pod{
        ObjectMeta: template.ObjectMeta,
    }
    pod.GenerateName = rs.Name + "-"
    // apiserver 生成随机 suffix：nginx-rs-x7k2p
    pod.OwnerReferences = []metav1.OwnerReference{*controllerRef}
    // OwnerReference 让 Pod 与 RS 关联，RS 删除时 Pod 被 GC
}
```

---

## scale down 时的 Pod 选择策略

```go
// pkg/controller/replicaset/replica_set.go
func getPodsToDelete(filteredPods, relatedPods []*v1.Pod, diff int) []*v1.Pod {
    // 优先删除：
    // 1. Pending（未调度）的 Pod
    // 2. 没有分配节点的 Pod
    // 3. 处于 Unready 状态的 Pod
    // 4. 运行时间最短的 Pod（最后才删 Running 中的）
    // 同优先级时按创建时间排序，删最新的
    sort.Sort(controller.ActivePods(filteredPods))
    return filteredPods[:diff]
}
```

---

## Ownership 与 GC

RS 通过 `OwnerReferences` 管理 Pod 生命周期：
- RS 创建的每个 Pod 都有 `OwnerReference` 指向该 RS
- RS 被删除时，GC controller（`pkg/controller/garbagecollector/`）检测到孤儿 Pod，发出 `DeletePod` 请求
- `propagationPolicy: Foreground` 时，先删 Pod，再删 RS

---

## 状态更新

```go
type ReplicaSetStatus struct {
    Replicas             int32  // 当前存在的 Pod 总数
    FullyLabeledReplicas int32  // label 完全匹配的 Pod 数
    ReadyReplicas        int32  // 处于 Ready 状态的 Pod 数
    AvailableReplicas    int32  // Ready 且满足 minReadySeconds 的 Pod 数
}
```

kubelet 在容器启动成功并通过 readinessProbe 后更新 Pod.Status.Conditions，RS controller 的 pod informer 收到变更，重新统计 ReadyReplicas。

---

## dlv 断点

```bash
# controller-manager（port 2346）
b k8s.io/kubernetes/pkg/controller/replicaset.(*ReplicaSetController).syncReplicaSet

# 观察 Pod 创建调用
b k8s.io/kubernetes/pkg/controller.(*RealPodControl).CreatePodsWithGenerateName

# scale down 时的 Pod 选择
b k8s.io/kubernetes/pkg/controller/replicaset.getPodsToDelete
```

---

## 相关文档

| 文档 | 说明 |
|------|------|
| `01-pod.md` | Pod 创建尾部（scheduler → kubelet → CRI） |
| `03-deployment.md` | Deployment 如何管理 ReplicaSet |
