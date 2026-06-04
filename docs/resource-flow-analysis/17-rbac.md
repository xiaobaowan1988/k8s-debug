# RBAC 创建链路

RBAC（Role-Based Access Control）是 K8s 的权限模型。四个资源：Role（namespace 级）、ClusterRole（集群级）、RoleBinding（namespace 级绑定）、ClusterRoleBinding（集群级绑定）。

**apiserver → etcd 路径**：见 `00-apiserver-common-flow.md`（RBAC 资源没有独立 controller）

---

## 接力图

```
kubectl apply -f role.yaml / rolebinding.yaml
    ↓
apiserver.Store.Create()   写入 RBAC 对象（无 controller 参与）
    ↓
RBAC Authorizer（apiserver 内部，内存缓存）
    → 监听 RBAC 对象变更，实时更新规则缓存
    ↓（每次 API 请求时）
请求到达 apiserver
    → Authentication（谁发的请求）
    → Authorization（有没有权限）
        → RBAC Authorizer.Authorize()
            → 在内存中查找匹配的 RoleBinding/ClusterRoleBinding
            → 返回 Allow / Deny / NoOpinion
```

---

## RBAC 对象结构

```yaml
# Role：namespace 级别，定义一组操作
kind: Role
metadata:
  name: pod-reader
  namespace: default
rules:
  - apiGroups: [""]             # "" 表示 core group
    resources: ["pods"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "list", "update", "patch"]
    resourceNames: ["my-deploy"]  # 可选：限定具体资源名

---
# RoleBinding：把 Role 绑定到 Subject
kind: RoleBinding
metadata:
  name: pod-reader-binding
  namespace: default
subjects:
  - kind: ServiceAccount
    name: my-sa
    namespace: default
  - kind: User
    name: alice
  - kind: Group
    name: developers
roleRef:
  kind: Role        # 或 ClusterRole（跨 namespace 复用）
  name: pod-reader
  apiGroup: rbac.authorization.k8s.io
```

---

## RBAC Authorizer

`plugin/pkg/auth/authorizer/rbac/rbac.go`

### 初始化：监听 RBAC 对象

```go
func New(roles, roleBindings, clusterRoles, clusterRoleBindings) *RBACAuthorizer {
    authorizer := &RBACAuthorizer{
        authorizationRuleResolver: newRBACRuleResolver(
            roles, roleBindings, clusterRoles, clusterRoleBindings,
        ),
    }
    // 通过 informer 实时 watch RBAC 变更，更新内存缓存
    // 无需重启 apiserver
    return authorizer
}
```

### 每次请求的授权检查

```go
func (r *RBACAuthorizer) Authorize(ctx, requestAttributes authorizer.Attributes) (authorizer.Decision, string, error) {
    // ← dlv 断点（每次 API 请求都会经过）

    // ruleCheckingVisitor 遍历规则，找到第一个匹配就停止
    ruleCheckingVisitor := &authorizingVisitor{requestAttributes: requestAttributes}

    r.authorizationRuleResolver.VisitRulesFor(
        requestAttributes.GetUser(),
        requestAttributes.GetNamespace(),
        ruleCheckingVisitor.visit,
    )

    if ruleCheckingVisitor.allowed {
        return authorizer.DecisionAllow, ruleCheckingVisitor.reason, nil
    }
    return authorizer.DecisionNoOpinion, "", nil  // 不允许（交给下一个 authorizer）
}
```

### 规则匹配：VisitRulesFor

```go
func (r *DefaultRuleResolver) VisitRulesFor(user user.Info, namespace string, visitor func(source PolicyRuleOwner, rule *rbacv1.PolicyRule) bool) {
    // 1. 检查 ClusterRoleBinding（不限 namespace）
    clusterRoleBindings, _ := r.clusterRoleBindingLister.ListClusterRoleBindings()
    for _, clusterRoleBinding := range clusterRoleBindings {
        if subjectMatches(clusterRoleBinding.Subjects, user) {
            // 找到绑定到该用户的 ClusterRoleBinding，获取对应 ClusterRole 的规则
            clusterRole, _ := r.clusterRoleLister.GetClusterRole(clusterRoleBinding.RoleRef.Name)
            for _, rule := range clusterRole.Rules {
                if !visitor(clusterRoleBinding, &rule) {
                    return  // 访问者决定停止
                }
            }
        }
    }

    // 2. 检查 RoleBinding（限定 namespace）
    if namespace != "" {
        roleBindings, _ := r.roleBindingLister.ListRoleBindings(namespace)
        for _, roleBinding := range roleBindings {
            if subjectMatches(roleBinding.Subjects, user) {
                // 找到 Role 或 ClusterRole（通过 roleRef.Kind 区分）
                rules, _ := r.GetRoleReferenceRules(roleBinding.RoleRef, namespace)
                for _, rule := range rules {
                    if !visitor(roleBinding, &rule) {
                        return
                    }
                }
            }
        }
    }
}
```

### 规则匹配判断

```go
// vendor/k8s.io/apiserver/pkg/authorization/rbac/rbac.go
func ruleAllows(requestAttributes authorizer.Attributes, rule *rbacv1.PolicyRule) bool {
    // 检查 verbs
    if !verbMatches(rule, requestAttributes.GetVerb()) {
        return false
    }
    // 检查 apiGroups
    if !apiGroupMatches(rule, requestAttributes.GetAPIGroup()) {
        return false
    }
    // 检查 resources
    if !resourceMatches(rule, requestAttributes.GetResource(), requestAttributes.GetSubresource()) {
        return false
    }
    // 检查 resourceNames（如果规则指定了）
    if len(rule.ResourceNames) > 0 && !resourceNameMatches(rule, requestAttributes.GetName()) {
        return false
    }
    return true
}
```

---

## 聚合 ClusterRole

```yaml
# 定义聚合规则：凡是有 rbac.example.com/aggregate-to-admin: "true" label 的 ClusterRole
# 都会自动合并到这个 ClusterRole
kind: ClusterRole
metadata:
  name: admin-aggregated
aggregationRule:
  clusterRoleSelectors:
    - matchLabels:
        rbac.example.com/aggregate-to-admin: "true"
```

`pkg/controller/clusterroleaggregation/clusterroleaggregation_controller.go`

```go
func (c *ClusterRoleAggregationController) syncClusterRole(ctx, key string) error {
    // ← dlv 断点

    clusterRole, _ := c.clusterRoleLister.Get(name)

    // 找到所有匹配 aggregationRule 的 ClusterRole
    var newRules []rbacv1.PolicyRule
    for _, selector := range clusterRole.AggregationRule.ClusterRoleSelectors {
        matchingClusterRoles, _ := c.clusterRoleLister.List(labelSelector)
        for _, matchingRole := range matchingClusterRoles {
            newRules = append(newRules, matchingRole.Rules...)
        }
    }

    // 去重合并，更新 ClusterRole.Rules
    clusterRole.Rules = deduplicate(newRules)
    c.clusterRoleClient.ClusterRoles().Update(ctx, clusterRole, ...)
}
```

---

## 内置 ClusterRole

| ClusterRole | 用途 |
|-------------|------|
| `cluster-admin` | 全部权限（等效 root） |
| `admin` | namespace 内全部权限，不含配额和 namespace 本身 |
| `edit` | 读写大多数资源，不含 RBAC |
| `view` | 只读大多数资源 |
| `system:kube-scheduler` | scheduler 所需权限 |
| `system:node` | kubelet 所需权限 |

---

## Subject 类型

| 类型 | 标识符格式 |
|------|-----------|
| `User` | 任意字符串（由 authenticator 提供） |
| `Group` | 任意字符串（由 authenticator 提供） |
| `ServiceAccount` | `system:serviceaccount:{namespace}:{name}` |

特殊 Group：
- `system:authenticated` — 所有已认证用户
- `system:unauthenticated` — 未认证用户
- `system:masters` — 超级权限（绕过 RBAC，等效 cluster-admin）

---

## dlv 断点

```bash
# apiserver（port 2345）
# 授权检查（每次请求都触发，断点会非常频繁）
b k8s.io/kubernetes/plugin/pkg/auth/authorizer/rbac.(*RBACAuthorizer).Authorize

# ClusterRole 聚合（controller-manager，port 2346）
b k8s.io/kubernetes/pkg/controller/clusterroleaggregation.(*ClusterRoleAggregationController).syncClusterRole
```

> **注意**：对 Authorize 设断点会使 apiserver 极慢，建议添加条件断点：
> ```
> condition 1 requestAttributes.GetUser().GetName() == "system:serviceaccount:default:my-sa"
> ```

---

## 相关文档

| 文档 | 说明 |
|------|------|
| `16-serviceaccount.md` | ServiceAccount：RBAC 的主要 Subject |
| `18-namespace-quota.md` | Namespace：RBAC 的作用域边界 |
| `21-auth-resources.md` | TokenReview / SubjectAccessReview：认证与权限验证 API |
