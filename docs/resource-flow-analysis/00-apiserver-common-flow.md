# apiserver 通用处理路径

所有资源的 `kubectl create/apply` 都经过本文描述的路径。后续各资源文档的"第①步"均引用此处，不再重复。

## 环境

| 项目 | 版本 |
|------|------|
| Kubernetes | v1.32.0 |
| 源码路径前缀 | `vendor/k8s.io/apiserver/` 或 `pkg/` |

---

## 触发：kubectl 发出请求

`staging/src/k8s.io/kubectl/pkg/cmd/apply/apply.go`

```
RunApply()
  → resource.NewHelper(mapping, client)
  → helper.Create(namespace, obj)        // POST
  → helper.Replace(namespace, name, obj) // PUT（已存在时）
```

构造 HTTP 请求：
```
POST /apis/apps/v1/namespaces/{ns}/{resource}
Content-Type: application/json
Body: 序列化后的 Go struct
```

---

## apiserver 内部处理链

### 1. 路由匹配

`vendor/k8s.io/apiserver/pkg/endpoints/installer.go` → `registerResourceHandlers()`

启动时为每种资源注册路由，POST 方法绑定到 `restfulCreateResource()`：

```go
// vendor/k8s.io/apiserver/pkg/endpoints/handlers/create.go
func createHandler(r rest.NamedCreater, scope *RequestScope, ...) http.HandlerFunc {
    return func(w http.ResponseWriter, req *http.Request) {
        // 读取 body
        body, err := limitedReadBodyWithRecovery(req, ...)

        // 反序列化
        obj, err := decoder.Decode(body, &schema.GroupVersionKind{}, nil)

        // ① 准入控制
        admit(ctx, admissionAttributes, scope)

        // ② 写入存储
        result, err := r.Create(ctx, name, obj, createValidation, options)
    }
}
```

### 2. 准入控制（admit）

`vendor/k8s.io/apiserver/pkg/admission/`

两个阶段串行执行：

```
MutatingAdmissionWebhook    ← 可修改对象（注入 sidecar、设默认值）
        ↓
ValidatingAdmissionWebhook  ← 只能拒绝，不能修改
        ↓
ValidatingAdmissionPolicy   ← CEL 表达式校验（v1.30+ GA）
```

内置 admission plugin 在 webhook 之前执行，包括：
- `NamespaceLifecycle` — 拒绝写入 Terminating 状态的 namespace
- `LimitRanger` — 注入 LimitRange 默认值
- `ResourceQuota` — 检查配额（写入时扣减）
- `ServiceAccount` — 注入 serviceAccountName
- `PodSecurity` — 检查 Pod Security Standards

### 3. 验证（validation）

`pkg/apis/{group}/validation/validation.go`

每种资源有独立的 `Validate*()` 函数，例如：
```go
// pkg/apis/apps/validation/validation.go
func ValidateStatefulSet(set *apps.StatefulSet, ...) field.ErrorList
func ValidateDeployment(obj *apps.Deployment, ...) field.ErrorList
```

### 4. 写入 etcd

`vendor/k8s.io/apiserver/pkg/registry/generic/registry/store.go`

```go
func (e *Store) Create(ctx, name, obj, createValidation, options) (runtime.Object, error) {
    // ← dlv 断点位置（所有资源共用）

    // 生成 key：/registry/{group}/{resource}/{namespace}/{name}
    key, err := e.KeyFunc(ctx, name)

    // 序列化为 protobuf
    // 写入 etcd
    err = e.Storage.Create(ctx, key, obj, out, ttl, ...)
}
```

etcd 内部路径示例：
```
/registry/deployments/default/nginx-deploy
/registry/statefulsets/default/nginx
/registry/pods/default/nginx-0
/registry/services/default/my-svc
```

### 5. etcd 持久化

`vendor/go.etcd.io/etcd/client/v3/`（客户端）
`vendor/go.etcd.io/etcd/server/v3/etcdserver/` → `(*EtcdServer).Put()`（服务端）

etcd 通过 Raft 协议在多副本间达成一致后写入 BoltDB/bbolt。

### 6. watch 事件广播

etcd 写入成功后，apiserver 的 watch cache（`WatchCache`）检测到变更，将事件推送给所有注册了 watch 的客户端：

```go
// vendor/k8s.io/apiserver/pkg/storage/cacher/cacher.go
func (c *Cacher) processEvent(event *watchCacheEvent) {
    c.watchCache.updateCache(event)
    c.dispatchEvent(event)   // 广播给所有 watcher
}
```

controller-manager、scheduler、kubelet 的 informer 都通过 `ListWatch` 机制接收这些事件，各自进入自己的处理队列。

---

## API Priority and Fairness（APF）

`pkg/util/flowcontrol/` + `vendor/k8s.io/apiserver/pkg/util/flowcontrol/`

每个请求在路由匹配后立即经过 APF 分类：

```
请求
  → FlowSchema 匹配（按 distinguisher 规则）
  → 分配到 PriorityLevelConfiguration（队列）
  → 令牌桶限流
  → 超限时排队或拒绝（429 Too Many Requests）
```

`FlowSchema` 和 `PriorityLevelConfiguration` 本身也是 API 资源，见 `20-flowcontrol.md`（待写）。

---

## dlv 断点（所有资源通用）

```bash
# apiserver：所有资源写入的统一入口
b k8s.io/apiserver/pkg/registry/generic/registry.(*Store).Create

# etcd 服务端持久化
b go.etcd.io/etcd/server/v3/etcdserver.(*EtcdServer).Put

# 准入控制入口
b k8s.io/apiserver/pkg/admission.(*chainAdmissionHandler).Admit
```

---

## 完整处理链路图

```
kubectl apply
    │ POST /apis/{group}/{version}/{resource}
    ▼
apiserver.createHandler()
    │ decoder.Decode()              反序列化 JSON/YAML → Go struct
    │ admit()
    │   ├── MutatingWebhook        修改对象
    │   ├── ValidatingWebhook      验证对象
    │   └── 内置 plugin            ResourceQuota / LimitRanger / ...
    │ Validate*()                  字段合法性校验
    ▼
registry.(*Store).Create()         ← dlv 断点
    │ e.Storage.Create()
    ▼
etcd3.(*store).Create()
    │ clientv3.Put(key, protobuf)
    ▼
(*EtcdServer).Put()                ← dlv 断点（etcd 进程）
    │ Raft 共识 → BoltDB 落盘
    ▼
WatchCache.dispatchEvent()
    │ 广播 watch 事件
    ▼
各 controller informer 收到事件 → 各自处理队列（见后续各文档）
```

---

## 相关文档

| 文档 | 说明 |
|------|------|
| `01-pod.md` | Pod 创建（kubelet 接力） |
| `03-deployment.md` | Deployment → ReplicaSet → Pod |
| `19-crd-webhook.md` | CRD 注册 + Webhook 机制详解 |
