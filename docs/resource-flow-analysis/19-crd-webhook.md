# CRD + MutatingWebhook + ValidatingWebhook + ValidatingAdmissionPolicy

CRD 允许用户扩展 K8s API，注册自定义资源类型。Webhook 在 admission 阶段拦截请求，ValidatingAdmissionPolicy（VAP）用 CEL 表达式替代 webhook 实现轻量级校验。

**apiserver → etcd 路径（通用）**：见 `00-apiserver-common-flow.md`

---

## CRD 接力图

```
kubectl apply -f crd.yaml
    ↓
apiserver（apiextensions-apiserver）
    → 写入 CRD 对象（/registry/apiextensions.k8s.io/customresourcedefinitions/{name}）
    ↓
CRD controller（apiextensions-apiserver 内部）
    → 动态注册新 API group/version/resource 到 apiserver 路由
    → 设置 CRD.Status.Conditions（NamesAccepted, Established）
    ↓（几秒内）
新 API 可用：kubectl apply -f mycrd-instance.yaml
    → POST /apis/{group}/{version}/{resource}
    → 走标准 apiserver 路径：admission → validation → etcd
```

---

## CRD 注册机制

`vendor/k8s.io/apiextensions-apiserver/pkg/controller/apiapproval/`
`vendor/k8s.io/apiextensions-apiserver/pkg/controller/establish/`

### CRD 对象写入后

```go
// vendor/k8s.io/apiextensions-apiserver/pkg/apiserver/apiserver.go
func (c *CustomResourceDefinitions) Run(ctx) {
    // 三个 controller 并发运行：

    // 1. NamingController：检查 group/version/kind 是否与已有资源冲突
    go c.namingController.Run(ctx, 5)

    // 2. EstablishingController：等待 NamesAccepted 后设置 Established=True
    go c.establishingController.Run(ctx)

    // 3. DiscoveryController：将新资源注册到 /apis/{group} discovery 端点
    go c.discoveryController.Run(ctx)
}
```

### 动态 RESTStorage 注册

```go
// vendor/k8s.io/apiextensions-apiserver/pkg/registry/customresource/registry.go
func (c *crdHandler) ServeHTTP(w http.ResponseWriter, req *http.Request) {
    // 每次请求到 /apis/{group}/{version}/{resource} 时，
    // 动态查找对应的 CRD，构造 REST handler

    crd, _ := c.crdLister.Get(...)
    storage, _ := c.customStorage.Load()

    // 使用 unstructured 存储（不需要预定义 Go struct）
    // CRD 实例存储在 etcd：/registry/{group}/{resource}/{namespace}/{name}
    handler, _ := storage.storageMap[crdInfo.spec.group+"/"+crdInfo.spec.version]
    handler.ServeHTTP(w, req)
}
```

### CRD Validation

```yaml
spec:
  validation:
    openAPIV3Schema:        # OpenAPI v3 Schema 校验
      type: object
      properties:
        spec:
          type: object
          required: ["replicas"]
          properties:
            replicas:
              type: integer
              minimum: 1
              maximum: 10
```

CRD schema 校验在 admission 阶段由 apiextensions-apiserver 内置执行，不需要额外 webhook。

---

## MutatingAdmissionWebhook 接力图

```
任意资源创建/更新请求到达 apiserver
    ↓
MutatingAdmissionWebhook plugin
    → 查找匹配的 MutatingWebhookConfiguration
    → 按 rules（apiGroups/apiVersions/resources/operations）过滤
    → 对匹配的 webhook 依次调用（串行）
    ↓ HTTP POST https://{webhook-service}/mutate
Webhook server（用户部署的 Pod）
    → 处理 AdmissionReview 请求
    → 返回 patch（JSONPatch 或 MergePatch）
    ↓
apiserver 应用 patch，继续后续 webhook
```

### Webhook 调用

`vendor/k8s.io/apiserver/pkg/admission/plugin/webhook/mutating/dispatcher.go`

```go
func (a *mutatingDispatcher) Dispatch(ctx, attr admission.Attributes, o admission.ObjectInterfaces, hooks []webhook.WebhookAccessor) error {
    // ← dlv 断点

    for i, hook := range hooks {
        // 检查 webhook 的 rules 是否匹配当前请求
        if !a.shouldCallHook(hook, attr, o) {
            continue
        }

        // 调用 webhook server
        changed, err := a.callAttrMutatingHook(ctx, hook, attr, o, versionedAttr, relevantHooks)

        if changed {
            // 重新运行所有 webhook（因为对象被修改了，前面的 webhook 可能需要重新评估）
            reinvokeCtx.SetShouldReinvoke()
        }
    }
}

func (a *mutatingDispatcher) callAttrMutatingHook(ctx, hook, attr, ...) (bool, error) {
    // 序列化对象为 AdmissionReview
    request := admissionv1.AdmissionReview{
        Request: &admissionv1.AdmissionRequest{
            UID:       uid,
            Kind:      gvk,
            Resource:  gvr,
            Operation: "CREATE",
            Object:    runtime.RawExtension{Raw: objJSON},
        },
    }

    // HTTP POST 到 webhook endpoint
    response, err := a.webhookInvoker.InvokeHook(ctx, hook, request)
    // 超时：hook.TimeoutSeconds（默认 10s）

    // 应用 patch
    if response.Response.Patch != nil {
        patchObj, _ := jsonpatch.DecodePatch(response.Response.Patch)
        patchObj.Apply(attr.GetObject())
    }
}
```

---

## ValidatingAdmissionWebhook

`vendor/k8s.io/apiserver/pkg/admission/plugin/webhook/validating/dispatcher.go`

流程与 Mutating 相同，但：
- 所有 ValidatingWebhook **并发调用**（Mutating 是串行）
- 只能返回 allow/deny，不能修改对象
- 任一 webhook 返回 deny → 整个请求被拒绝

```go
func (a *validatingDispatcher) Dispatch(ctx, attr, o, hooks) error {
    // 并发调用所有匹配的 webhook
    errs := make(chan error, len(hooks))
    for _, hook := range hooks {
        go func(h webhook.WebhookAccessor) {
            errs <- a.callAttrValidatingHook(ctx, h, attr, ...)
        }(hook)
    }

    // 收集结果，有任何 deny 就返回错误
    for range hooks {
        if err := <-errs; err != nil {
            return err
        }
    }
}
```

---

## ValidatingAdmissionPolicy（VAP）

K8s v1.30 GA。用 CEL 表达式直接在 apiserver 内执行校验，不需要部署额外的 webhook server。

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: "replicas-limit"
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups: ["apps"]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["deployments"]
  validations:
    - expression: "object.spec.replicas <= 5"
      message: "replicas must be <= 5"
    - expression: "has(object.spec.template.spec.containers)"
      message: "must have containers"
---
kind: ValidatingAdmissionPolicyBinding
spec:
  policyName: "replicas-limit"
  validationActions: [Deny]        # 或 Warn（只警告不阻止）
  matchResources:
    namespaceSelector:
      matchLabels:
        environment: production
```

### CEL 执行

`vendor/k8s.io/apiserver/pkg/admission/plugin/policy/validating/`

```go
func (v *validator) Validate(ctx, versionedAttr, versionedParams, namespace, runtimeCELCostBudget) ValidateResult {
    // ← dlv 断点

    for _, validation := range policy.Spec.Validations {
        // 编译并执行 CEL 表达式
        evalResult, _, err := validation.program.ContextEval(ctx, activation)
        // activation 包含：object（新对象）、oldObject、params、request、namespace

        if evalResult.Value != true {
            results = append(results, &PolicyDecisionWithMetadata{
                PolicyDecision: PolicyDecision{
                    Action:  ActionDeny,
                    Message: validation.Message,
                },
            })
        }
    }
}
```

---

## dlv 断点

```bash
# apiserver（port 2345）
# CRD 实例创建
b k8s.io/apiextensions-apiserver/pkg/registry/customresource.(*REST).Create

# MutatingWebhook 调用
b k8s.io/apiserver/pkg/admission/plugin/webhook/mutating.(*mutatingDispatcher).Dispatch

# ValidatingWebhook 调用
b k8s.io/apiserver/pkg/admission/plugin/webhook/validating.(*validatingDispatcher).Dispatch

# VAP CEL 执行
b k8s.io/apiserver/pkg/admission/plugin/policy/validating.(*validator).Validate
```

---

## 相关文档

| 文档 | 说明 |
|------|------|
| `00-apiserver-common-flow.md` | admission 链路总览 |
| `20-lease.md` | Lease：CRD controller 常用 leader election |
