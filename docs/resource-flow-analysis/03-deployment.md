# Deployment 创建链路

Deployment 在 ReplicaSet 之上增加了滚动更新、回滚、暂停/恢复能力。它管理 ReplicaSet，ReplicaSet 再管理 Pod。

**apiserver → etcd 路径**：见 `00-apiserver-common-flow.md`
**ReplicaSet → Pod 路径**：见 `02-replicaset.md` + `01-pod.md`

---

## 接力图

```
kubectl apply -f deployment.yaml
    ↓
apiserver.Store.Create()   写入 Deployment 对象
    ↓ watch 事件
DeploymentController.syncDeployment()
    ├── 首次创建：newReplicaSet() → 创建 RS（replicas=N）
    └── 滚动更新：newRS（replicas 递增）+ oldRS（replicas 递减）
    ↓ 写入 ReplicaSet 对象
ReplicaSetController.syncReplicaSet()
    ↓ 创建 Pod
Scheduler → Kubelet → CRI → kernel（见 01-pod.md）
```

---

## DeploymentController

`pkg/controller/deployment/deployment_controller.go`

### 启动

```go
func NewDeploymentController(ctx, dInformer, rsInformer, podInformer, client) (*DeploymentController, error) {
    dc := &DeploymentController{
        client: client,
        queue:  workqueue.NewRateLimitingQueue(...),
    }

    dInformer.Informer().AddEventHandler(cache.ResourceEventHandlerFuncs{
        AddFunc:    dc.addDeployment,
        UpdateFunc: dc.updateDeployment,   // 触发滚动更新
        DeleteFunc: dc.deleteDeployment,
    })

    rsInformer.Informer().AddEventHandler(...)
    // RS 状态变更时（Pod 数量变化），重新触发 Deployment 调谐
}
```

### 核心调谐

```go
func (dc *DeploymentController) syncDeployment(ctx, key string) error {
    // ← dlv 断点

    namespace, name, _ := cache.SplitMetaNamespaceKey(key)
    deployment, _ := dc.dLister.Deployments(namespace).Get(name)

    // 获取该 Deployment 下的所有 RS
    rsList, _ := dc.getReplicaSetsForDeployment(ctx, deployment)
    podMap, _ := dc.getPodMapForDeployment(deployment, rsList)

    // 按 Deployment 策略分发
    switch deployment.Spec.Strategy.Type {
    case apps.RecreateDeploymentStrategyType:
        return dc.rolloutRecreate(ctx, deployment, rsList, podMap)
    case apps.RollingUpdateDeploymentStrategyType:
        return dc.rolloutRolling(ctx, deployment, rsList, podMap)
    }
}
```

---

## 首次创建

`pkg/controller/deployment/sync.go`

```go
func (dc *DeploymentController) sync(ctx, deployment, rsList) error {
    newRS, oldRSs, _ := dc.getAllReplicaSetsAndSyncRevision(ctx, deployment, rsList, false)

    if newRS == nil {
        // 还没有对应的 RS，创建一个
        newRS, _ = dc.getNewReplicaSet(ctx, deployment, rsList)
            → dc.client.AppsV1().ReplicaSets(namespace).Create(ctx, newRS, ...)
            // RS.Spec.Replicas = deployment.Spec.Replicas
            // RS 名字：{deployment-name}-{podTemplateHash}
    }

    dc.scale(ctx, deployment, newRS, oldRSs)
    dc.cleanupDeployment(ctx, oldRSs, deployment)
    dc.syncDeploymentStatus(ctx, allRSs, newRS, deployment)
}
```

RS 名字中的 `podTemplateHash` 是 Pod template 的哈希值，template 不变则 RS 不变，这是滚动更新的基础。

---

## 滚动更新

`pkg/controller/deployment/rolling.go`

```go
func (dc *DeploymentController) rolloutRolling(ctx, deployment, rsList, podMap) error {
    newRS, oldRSs, _ := dc.getAllReplicaSetsAndSyncRevision(ctx, deployment, rsList, true)

    // scale up 新 RS
    scaledUp, _ := dc.reconcileNewReplicaSet(ctx, allRSs, newRS, deployment)

    // scale down 旧 RS
    scaledDown, _ := dc.reconcileOldReplicaSets(ctx, allRSs, controller.FilterActiveReplicaSets(oldRSs), newRS, deployment)
}
```

`reconcileNewReplicaSet` 按 `maxSurge` 控制新 RS 扩容速度：

```go
func (dc *DeploymentController) reconcileNewReplicaSet(ctx, allRSs, newRS, deployment) (bool, error) {
    // maxSurge：允许超出期望副本数的最大数量
    // 例如 replicas=10, maxSurge=2 → 最多同时存在 12 个 Pod
    maxTotalPods := *(deployment.Spec.Replicas) + deploymentutil.MaxSurge(*deployment)

    currentPodCount := deploymentutil.GetReplicaCountForReplicaSets(allRSs)
    scaleUpCount := maxTotalPods - currentPodCount

    // 逐步增加新 RS 的副本数
    newReplicasCount := *(newRS.Spec.Replicas) + scaleUpCount
    dc.scaleReplicaSetAndRecordEvent(ctx, newRS, newReplicasCount, deployment)
}
```

`reconcileOldReplicaSets` 按 `maxUnavailable` 控制旧 RS 缩容速度：

```go
func (dc *DeploymentController) reconcileOldReplicaSets(ctx, allRSs, oldRSs, newRS, deployment) (bool, error) {
    // maxUnavailable：允许不可用的最大 Pod 数
    // 例如 replicas=10, maxUnavailable=1 → 最少保持 9 个可用 Pod
    minAvailable := *(deployment.Spec.Replicas) - deploymentutil.MaxUnavailable(*deployment)
    newRSAvailablePodCount := deploymentutil.GetAvailableReplicaCountForReplicaSets([]*apps.ReplicaSet{newRS})

    // 只有新 RS 的可用 Pod 足够多，才缩减旧 RS
    maxScaledDown := currentPodCount - minAvailable - newRSAvailablePodCount
    // 逐步减少旧 RS 的副本数
}
```

### 滚动更新过程示意

```
初始状态：old-rs(3), new-rs(0)  → replicas=3, maxSurge=1, maxUnavailable=1

step1: new-rs(1) old-rs(3)  → 先创建 1 个新 Pod（maxSurge=1 允许临时 4 个）
step2: new-rs(1) old-rs(2)  → 1 个新 Pod Ready 后，删 1 个旧 Pod
step3: new-rs(2) old-rs(2)  → 再创建 1 个新 Pod
step4: new-rs(2) old-rs(1)  → 再删 1 个旧 Pod
step5: new-rs(3) old-rs(1)
step6: new-rs(3) old-rs(0)  → 完成
```

---

## 回滚

```go
// pkg/controller/deployment/rollback.go
func (dc *DeploymentController) rollback(ctx, deployment, rsList) error {
    // 找到目标 revision 对应的旧 RS
    rollbackTo := getRollbackTo(deployment)
    for _, rs := range rsList {
        if rs.Annotations[RevisionAnnotation] == strconv.FormatInt(rollbackTo.Revision, 10) {
            // 将旧 RS 的 Pod template 复制到 Deployment
            // 这会触发一次新的 rolloutRolling，方向反转
            dc.updateDeploymentAndClearRollbackTo(ctx, deployment)
        }
    }
}
```

每次 RS 都保存有 `deployment.kubernetes.io/revision` annotation，`kubectl rollout history` 就是读这个。

---

## Recreate 策略

`pkg/controller/deployment/recreate.go`

```go
func (dc *DeploymentController) rolloutRecreate(ctx, deployment, rsList, podMap) error {
    // 1. 把所有旧 RS 缩减到 0
    for _, rs := range oldRSs {
        dc.scaleReplicaSetAndRecordEvent(ctx, rs, 0, deployment)
    }
    // 2. 等待所有旧 Pod 消失
    // 3. 创建新 RS，replica = 期望数量
    // 期间有完全不可用窗口
}
```

---

## Deployment 状态机

```
Available conditions:
  Progressing = True    滚动更新进行中（或刚完成）
  Available   = True    至少 minAvailable 个 Pod 处于 Ready

异常状态：
  Progressing = False, reason = ProgressDeadlineExceeded
  → 超过 spec.progressDeadlineSeconds（默认 600s）仍未完成
```

---

## dlv 断点

```bash
# controller-manager（port 2346）
b k8s.io/kubernetes/pkg/controller/deployment.(*DeploymentController).syncDeployment

# 滚动更新路径
b k8s.io/kubernetes/pkg/controller/deployment.(*DeploymentController).rolloutRolling
b k8s.io/kubernetes/pkg/controller/deployment.(*DeploymentController).reconcileNewReplicaSet
b k8s.io/kubernetes/pkg/controller/deployment.(*DeploymentController).reconcileOldReplicaSets

# 首次创建
b k8s.io/kubernetes/pkg/controller/deployment/sync.(*DeploymentController).sync
```

---

## 相关文档

| 文档 | 说明 |
|------|------|
| `02-replicaset.md` | ReplicaSet controller 详情 |
| `01-pod.md` | Pod 创建链路 |
