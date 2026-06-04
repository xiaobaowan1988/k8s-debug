# Namespace + ResourceQuota + LimitRange

Namespace 提供资源隔离边界，ResourceQuota 限制 namespace 内资源总量，LimitRange 为每个 Pod/Container 设置默认值和上下限。

**apiserver → etcd 路径**：见 `00-apiserver-common-flow.md`

---

## Namespace 接力图

```
kubectl create namespace my-ns
    ↓
apiserver.Store.Create()   写入 Namespace
    ↓ watch 事件（两路）
    ├── NamespaceController（controller-manager）
    │     → 监听 Namespace 删除事件，清理内部所有资源
    └── apiserver 内置初始化
          → 自动创建 default ServiceAccount
          → 自动创建 kube-root-ca.crt ConfigMap
```

### NamespaceController：级联删除

`pkg/controller/namespace/namespace_controller.go`

```go
func (nm *NamespaceController) syncNamespaceFromKey(ctx, key string) error {
    namespace, _ := nm.namespaceLister.Get(key)

    if namespace.DeletionTimestamp == nil {
        return nil  // 未被删除
    }

    // Namespace 被删除时，逐一删除内部所有资源
    // 调用 discoveryclient 获取所有 namespace-scoped 资源类型
    resources, _ := nm.discoverResourcesFn()

    estimate, err := nm.deleteAllContent(ctx, resources, namespace.Name, *namespace.Spec.FinalizeTime)
    // 对每种资源类型调用：
    //   client.Resource(gvr).Namespace(ns).DeleteCollection(ctx, ...)
    // 包括 Pods, Deployments, Services, Secrets, ConfigMaps, PVCs 等
}
```

删除顺序：Namespace 进入 `Terminating` 状态 → NamespaceController 删除所有资源 → Finalizer 移除 → Namespace 对象从 etcd 删除。

---

## ResourceQuota 接力图

```
kubectl apply -f resourcequota.yaml
    ↓
apiserver.Store.Create()   写入 ResourceQuota
    ↓
ResourceQuotaController（controller-manager）
    → 定期（每 5 分钟）或事件驱动 syncResourceQuota()
    → 统计 namespace 内各资源当前使用量
    → 更新 ResourceQuota.Status.Used
    ↓（每次 Pod/PVC 等创建时）
ResourceQuota Admission Plugin（apiserver 内）
    → 检查 namespace 配额是否足够
    → 足够：允许，扣减配额计数
    → 不够：拒绝（403 Forbidden，quota exceeded）
```

### ResourceQuota Admission Plugin

`plugin/pkg/admission/resourcequota/admission.go`

```go
func (a *quotaAdmission) Admit(ctx, attr admission.Attributes, o admission.ObjectInterfaces) error {
    // ← dlv 断点

    // 获取该 namespace 的所有 ResourceQuota
    quotas, _ := a.quotaAccessor.GetQuotas(attr.GetNamespace())

    for _, quota := range quotas {
        // 计算本次请求需要消耗的资源量
        deltaUsage, err := a.registry.Usage(attr.GetObject())
        // deltaUsage: {pods: 1, requests.cpu: 500m, requests.memory: 256Mi, ...}

        // 检查是否超限
        for resource, requested := range deltaUsage {
            if hardLimit, exists := quota.Spec.Hard[resource]; exists {
                newUsage := quota.Status.Used[resource] + requested
                if newUsage > hardLimit {
                    return admission.NewForbidden(attr,
                        fmt.Errorf("exceeded quota: %s, requested: %s=%s, used: %s=%s, limited: %s=%s",
                            quota.Name, resource, requested, resource, quota.Status.Used[resource], resource, hardLimit))
                }
            }
        }

        // 乐观锁更新：更新 quota.Status.Used
        // 用 resourceVersion 保证并发安全
        a.quotaAccessor.UpdateQuotaStatus(quota)
    }
}
```

### ResourceQuotaController

`pkg/controller/resourcequota/resource_quota_controller.go`

```go
func (rq *Controller) syncResourceQuota(ctx, key string) error {
    // ← dlv 断点

    quota, _ := rq.rqLister.ResourceQuotas(namespace).Get(name)

    // 统计 namespace 内各资源实际使用量
    newUsage, err := quota.CalculateUsage(...)
    // 遍历所有资源类型，计算实际数量/用量
    // 例如：统计 namespace 内的 Pod 数、PVC 总容量等

    // 更新 Status.Used
    rq.kubeClient.CoreV1().ResourceQuotas(namespace).UpdateStatus(ctx, quota, ...)
}
```

### ResourceQuota 常用字段

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: compute-resources
  namespace: default
spec:
  hard:
    pods: "10"                        # Pod 数量上限
    requests.cpu: "4"                 # CPU request 总量
    requests.memory: 4Gi              # Memory request 总量
    limits.cpu: "8"                   # CPU limit 总量
    limits.memory: 8Gi                # Memory limit 总量
    persistentvolumeclaims: "4"       # PVC 数量
    requests.storage: 40Gi            # 存储总量
    count/deployments.apps: "5"       # 自定义计数（任意资源）
```

---

## LimitRange 接力图

```
kubectl apply -f limitrange.yaml
    ↓
apiserver.Store.Create()   写入 LimitRange
    ↓（Pod/Container 创建时）
LimitRanger Admission Plugin（apiserver 内）
    → 注入默认 requests/limits
    → 校验 requests <= limits <= max，min <= requests
```

### LimitRanger Admission Plugin

`plugin/pkg/admission/limitranger/admission.go`

```go
func (l *LimitRanger) Admit(ctx, a admission.Attributes, o admission.ObjectInterfaces) error {
    // ← dlv 断点

    // 获取该 namespace 的所有 LimitRange
    items, _ := l.lister.LimitRanges(a.GetNamespace()).List(labels.Everything())

    for _, limitRange := range items {
        err := l.admitPod(a.GetObject(), limitRange)
    }
}

func (l *LimitRanger) admitPod(obj runtime.Object, limitRange *v1.LimitRange) error {
    pod := obj.(*v1.Pod)

    for _, limit := range limitRange.Spec.Limits {
        switch limit.Type {
        case v1.LimitTypeContainer:
            for i := range pod.Spec.Containers {
                container := &pod.Spec.Containers[i]

                // 注入默认值（如果 container 没有设置）
                if container.Resources.Requests == nil {
                    container.Resources.Requests = limit.DefaultRequest.DeepCopy()
                }
                if container.Resources.Limits == nil {
                    container.Resources.Limits = limit.Default.DeepCopy()
                }

                // 校验范围
                if limit.Max != nil && container.Resources.Limits[v1.ResourceCPU] > limit.Max[v1.ResourceCPU] {
                    return fmt.Errorf("maximum cpu usage per Container is %s, but limit is %s",
                        limit.Max[v1.ResourceCPU], container.Resources.Limits[v1.ResourceCPU])
                }
            }

        case v1.LimitTypePod:
            // 检查 Pod 级别限制（所有 container 之和）
        case v1.LimitTypePersistentVolumeClaim:
            // 检查 PVC 容量范围
        }
    }
}
```

---

## LimitRange 常用配置

```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: default-limits
  namespace: default
spec:
  limits:
    - type: Container
      default:           # 没有设置 limits 时的默认值
        cpu: 500m
        memory: 256Mi
      defaultRequest:    # 没有设置 requests 时的默认值
        cpu: 100m
        memory: 64Mi
      max:              # requests/limits 的上限
        cpu: "2"
        memory: 1Gi
      min:              # requests/limits 的下限
        cpu: 50m
        memory: 32Mi
    - type: PersistentVolumeClaim
      max:
        storage: 10Gi
      min:
        storage: 1Gi
```

---

## dlv 断点

```bash
# apiserver（port 2345）
# ResourceQuota 配额检查
b k8s.io/kubernetes/plugin/pkg/admission/resourcequota.(*quotaAdmission).Admit

# LimitRange 默认值注入
b k8s.io/kubernetes/plugin/pkg/admission/limitranger.(*LimitRanger).Admit

# controller-manager（port 2346）
# ResourceQuota 统计
b k8s.io/kubernetes/pkg/controller/resourcequota.(*Controller).syncResourceQuota

# Namespace 清理
b k8s.io/kubernetes/pkg/controller/namespace.(*NamespaceController).syncNamespaceFromKey
```

---

## 相关文档

| 文档 | 说明 |
|------|------|
| `16-serviceaccount.md` | ServiceAccount：Namespace 创建时自动初始化 |
| `17-rbac.md` | RBAC Role 的 namespace 作用域 |
