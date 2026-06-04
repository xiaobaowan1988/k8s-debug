# DaemonSet 创建链路

DaemonSet 保证每个（满足条件的）节点上都运行一个 Pod 副本。与 ReplicaSet/Deployment 不同，它**不经过 scheduler**——DaemonSet controller 直接把 Pod 绑定到指定节点。

**apiserver → etcd 路径**：见 `00-apiserver-common-flow.md`
**Pod 创建尾部**：见 `01-pod.md`（kubelet 侧）

---

## 接力图

```
kubectl apply -f daemonset.yaml
    ↓
apiserver.Store.Create()   写入 DaemonSet 对象
    ↓ watch 事件
DaemonSetController.syncDaemonSet()
    ├── 计算每个节点是否需要 Pod
    ├── nodeShouldRunDaemonPod()：检查 taint/affinity/资源
    ├── 在需要的节点上：createPod()，直接设置 NodeName（跳过 scheduler）
    └── 在多余的节点上：deletePod()
    ↓ 写入 Pod（Spec.NodeName 已设置）
Kubelet.HandlePodAdditions()
    ↓ 不经过 scheduler，直接进入 syncPod()
CRI → kernel（见 01-pod.md）
```

---

## DaemonSetController

`pkg/controller/daemon/daemon_controller.go`

### 启动与 informer

```go
func NewDaemonSetsController(ctx, dsInformer, historyInformer, podInformer, nodeInformer, kubeClient, ...) {
    dsc := &DaemonSetsController{...}

    dsInformer.Informer().AddEventHandler(cache.ResourceEventHandlerFuncs{
        AddFunc:    dsc.addDaemonset,
        UpdateFunc: dsc.updateDaemonset,
        DeleteFunc: dsc.deleteDaemonset,
    })

    // 关键：监听 Node 变更
    // 新节点加入集群时，DaemonSet controller 立即为其创建 Pod
    nodeInformer.Informer().AddEventHandler(cache.ResourceEventHandlerFuncs{
        AddFunc:    dsc.addNode,     // 新节点 → 所有 DaemonSet 入队
        UpdateFunc: dsc.updateNode, // 节点 taint 变更 → 重新评估
    })
}
```

### 核心调谐

```go
func (dsc *DaemonSetsController) syncDaemonSet(ctx, key string) error {
    // ← dlv 断点

    namespace, name, _ := cache.SplitMetaNamespaceKey(key)
    ds, _ := dsc.dsLister.DaemonSets(namespace).Get(name)

    // 获取所有节点
    nodeList, _ := dsc.nodeLister.List(labels.Everything())

    // 获取当前 DS 管理的所有 Pod
    podList, _ := dsc.podLister.Pods(ds.Namespace).List(labels.Everything())

    // 计算每个节点的期望状态
    nodeToDaemonPods, _ := dsc.getNodesToDaemonPods(ctx, ds, podList)

    // 决定哪些节点需要创建/删除 Pod
    nodesNeedingDaemonPods, podsToDelete, _ := dsc.nodesToDaemonPods(ctx, ds, nodeList, nodeToDaemonPods)

    // 批量操作
    dsc.syncNodes(ctx, ds, podsToDelete, nodesNeedingDaemonPods, hash)
}
```

### 节点评估：nodeShouldRunDaemonPod

```go
func (dsc *DaemonSetsController) nodeShouldRunDaemonPod(node *v1.Node, ds *apps.DaemonSet) (wantToRun, shouldSchedule, shouldContinueRunning bool, ...) {
    // ← dlv 断点（理解为什么某节点没有 DaemonSet Pod 时）

    pod := NewPod(ds, node.Name)

    // 1. 检查节点是否满足 nodeSelector / nodeAffinity
    fitsNodeName, fitsNodeAffinity, _ := predicates.PodMatchNodeSelector(pod, node)

    // 2. 模拟调度：检查资源、taint、PodFitsHost
    //    注意：这里用的是 scheduler predicates 的子集，但结果仅供参考
    //    最终是 DaemonSet controller 直接绑定，不走真实调度器
    _, reasons, _ := dsc.simulate(pod, node, ds)

    // 3. 判断 taint 是否被 toleration 覆盖
    //    node.kubernetes.io/not-ready taint → DaemonSet Pod 通常有对应 toleration
    fitsNodeTaints := v1helper.TolerationsTolerateTaints(pod.Spec.Tolerations, node.Spec.Taints)

    wantToRun = fitsNodeName && fitsNodeAffinity
    shouldSchedule = wantToRun && fitsNodeTaints
    shouldContinueRunning = wantToRun
    return
}
```

### 跳过 Scheduler：直接绑定 NodeName

```go
func (dsc *DaemonSetsController) syncNodes(ctx, ds, podsToDelete, nodesNeedingDaemonPods, hash string) error {
    createDiff := len(nodesNeedingDaemonPods)
    deleteDiff := len(podsToDelete)

    // 创建 Pod，关键：直接设置 NodeName
    for _, nodeName := range nodesNeedingDaemonPods {
        podTemplate := dsc.createPodTemplate(ds.Spec.Template, hash, nodeName)
        // podTemplate.Spec.NodeName = nodeName  ← 直接绑定，不经过 scheduler
        // podTemplate.Spec.Affinity = 添加 nodeAffinity 确保只运行在目标节点

        dsc.podControl.CreatePods(ctx, ds.Namespace, podTemplate, ds, controllerRef)
    }

    // 删除多余的 Pod
    for _, pod := range podsToDelete {
        dsc.podControl.DeletePod(ctx, pod.Namespace, pod.Name, ds)
    }
}
```

kubelet 收到 `Spec.NodeName` 已设置的 Pod 后，直接进入 `syncPod()`，不会等待 scheduler。

---

## 与滚动更新：DaemonSet updateStrategy

`pkg/controller/daemon/update.go`

```go
func (dsc *DaemonSetsController) rollingUpdate(ctx, ds, nodeList, hash string) error {
    // ← dlv 断点（滚动更新时）

    // 找出所有使用旧 template 的 Pod
    oldPods, newPods, _ := dsc.getAllDaemonSetPods(ds, nodeToDaemonPods, hash)

    // maxUnavailable 控制：同时最多不可用多少个节点
    maxUnavailable, numUnavailable, _ := dsc.getUnavailableNumbers(ds, nodeList, nodeToDaemonPods)

    // 先删旧 Pod（会触发 kubelet 拉起新 Pod）
    oldAvailablePods, oldUnavailablePods := util.SplitByAvailability(oldPods, minReadySeconds)

    // 优先删已不可用的旧 Pod
    if len(oldUnavailablePods) > 0 {
        dsc.podControl.DeletePod(ctx, ...)
    }

    // 在 maxUnavailable 限制内删可用的旧 Pod
    allowedReplacePods := maxUnavailable - numUnavailable
    for i := 0; i < allowedReplacePods; i++ {
        dsc.podControl.DeletePod(ctx, ...)
    }
}
```

DaemonSet 的滚动更新：删旧 → kubelet 重新调协 → 用新 template 创建新 Pod。

---

## ControllerRevision：版本管理

DaemonSet（及 StatefulSet）使用 `ControllerRevision` 存储历史 template：

```go
// pkg/controller/history/controller_history.go
type ControllerRevision struct {
    Data     runtime.RawExtension  // 序列化的 Pod template
    Revision int64                 // 递增版本号
}
```

回滚时将旧 revision 的 Data 恢复到 DaemonSet.Spec.Template，触发新一轮滚动更新。

---

## 与 Deployment 的关键区别

| 维度 | Deployment | DaemonSet |
|------|-----------|-----------|
| 副本管理 | 固定副本数，随意分布 | 每节点一个 |
| Scheduler | 经过 scheduler | 跳过，直接设 NodeName |
| 中间对象 | ReplicaSet | 无中间层 |
| 新节点 | 不感知 | 立即创建 Pod |
| 版本历史 | RS annotation | ControllerRevision |

---

## dlv 断点

```bash
# controller-manager（port 2346）
b k8s.io/kubernetes/pkg/controller/daemon.(*DaemonSetsController).syncDaemonSet

# 节点评估（调试为什么某节点没有 Pod）
b k8s.io/kubernetes/pkg/controller/daemon.(*DaemonSetsController).nodeShouldRunDaemonPod

# 滚动更新
b k8s.io/kubernetes/pkg/controller/daemon.(*DaemonSetsController).rollingUpdate
```

---

## 相关文档

| 文档 | 说明 |
|------|------|
| `01-pod.md` | Pod 创建链路（kubelet 侧） |
| `03-deployment.md` | 对比：Deployment 的滚动更新机制 |
