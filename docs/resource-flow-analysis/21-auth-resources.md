# CertificateSigningRequest + TokenReview + SubjectAccessReview

三个安全相关资源，用于证书签发、身份验证、权限验证。它们都是"即时操作"型资源——创建即执行，结果写回 Status，**不持久化到 etcd**（除 CSR 外）。

---

## CertificateSigningRequest（CSR）

### 接力图

```
kubectl certificate approve my-csr（或自动审批）
    ↓
CSR 对象写入 etcd（/registry/certificatesigningrequests/{name}）
    ↓
CertificateSigningRequestController（controller-manager）
    → 监听 CSR 对象变更
    → 自动审批特定类型（kubelet client cert、node serving cert）
    ↓（或管理员手动 kubectl certificate approve）
apiserver SigningController
    → 调用 signer（内置 CA 或 外部 CA）签发证书
    → 写入 CSR.Status.Certificate
```

### CSR 使用场景

主要场景：kubelet 首次启动时的 TLS bootstrapping：

```
新节点启动 kubelet
    ↓ 使用 bootstrap token（临时凭证）连接 apiserver
kubelet 生成密钥对，提交 CSR
    ↓
NodeCSRApprover（controller-manager）自动审批
    ↓
apiserver 签发客户端证书
    ↓
kubelet 使用新证书替换 bootstrap token，建立正式 TLS 连接
```

### CertificateSigningRequestController

`pkg/controller/certificates/`

```go
// pkg/controller/certificates/approver/sarapprover.go
func (cc *sarApprover) handle(ctx, csr *capi.CertificateSigningRequest) error {
    // ← dlv 断点

    // 检查 CSR 是否是 kubelet client cert 请求
    if csr.Spec.SignerName != capi.KubeAPIServerClientKubeletSignerName {
        return nil  // 不是 kubelet cert，跳过
    }

    // 解析 CSR 中的证书请求
    x509cr, err := parseCSR(csr.Spec.Request)

    // 通过 SubjectAccessReview 检查 CSR 发起者是否有权限申请该证书
    ok, reason, err := cc.recognize(ctx, csr, x509cr)

    if ok {
        // 审批 CSR
        csr.Status.Conditions = append(csr.Status.Conditions, capi.CertificateSigningRequestCondition{
            Type:               capi.CertificateApproved,
            Status:             v1.ConditionTrue,
            Reason:             "AutoApproved",
        })
        cc.client.CertificatesV1().CertificateSigningRequests().UpdateApproval(ctx, csr.Name, csr, ...)
    }
}
```

### 签发证书

`pkg/controller/certificates/signer/`

```go
func (signer *signer) sign(ctx, csr *capi.CertificateSigningRequest) error {
    // 解析 CSR
    x509cr, _ := parseCSR(csr.Spec.Request)

    // 用集群 CA 签发证书
    certDER, err := ca.Sign(x509cr.Raw, authority.SigningRequestedInfo{
        PublicKey:    x509cr.PublicKey,
        Subject:      x509cr.Subject,
        DNSNames:     x509cr.DNSNames,
        IPAddresses:  x509cr.IPAddresses,
        Usages:       csr.Spec.Usages,
        NotBefore:    now,
        NotAfter:     now.Add(expirationDuration),
    })

    // 将证书写入 Status.Certificate
    csr.Status.Certificate = pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: certDER})
    cc.client.CertificatesV1().CertificateSigningRequests().UpdateStatus(ctx, csr, ...)
}
```

---

## TokenReview

TokenReview 是一个"即时查询"：提交一个 token，apiserver 验证其有效性并返回用户信息。**不写入 etcd**。

### 使用场景

- kubelet 的 webhook token authenticator
- 其他服务验证 K8s ServiceAccount token

### 处理路径

`pkg/registry/authentication/tokenreview/rest.go`

```go
func (r *REST) Create(ctx, obj, createValidation, options) (runtime.Object, error) {
    // ← dlv 断点

    tokenReview := obj.(*authentication.TokenReview)

    // 调用认证链（多个 authenticator 串联）
    response, ok, err := r.tokenAuthenticator.AuthenticateToken(ctx, tokenReview.Spec.Token)

    if ok {
        tokenReview.Status = authentication.TokenReviewStatus{
            Authenticated: true,
            User: authentication.UserInfo{
                Username: response.User.GetName(),
                UID:      response.User.GetUID(),
                Groups:   response.User.GetGroups(),
                Extra:    response.User.GetExtra(),
            },
            Audiences: response.Audiences,
        }
    } else {
        tokenReview.Status.Authenticated = false
        tokenReview.Status.Error = "token failed to authenticate"
    }

    return tokenReview, nil
    // 注意：不调用 registry.Store.Create()，不写 etcd
}
```

### Token 认证链

`vendor/k8s.io/apiserver/pkg/authentication/request/union/union.go`

```go
func (authHandler *unionAuthRequestHandler) AuthenticateRequest(req) (info, ok, err) {
    // 依次尝试每个 authenticator，第一个成功的返回
    for _, handler := range authHandler.Handlers {
        resp, ok, err := handler.AuthenticateToken(ctx, token)
        if err != nil {
            continue
        }
        if ok {
            return resp, true, nil  // 认证成功
        }
    }
    return nil, false, utilerrors.NewAggregate(errlist)
}

// 认证链包含（按顺序）：
// 1. BearerToken authenticator（JWT）   ← ServiceAccount token
// 2. OIDC authenticator                ← 外部 OIDC provider
// 3. X509 authenticator                ← 客户端证书
// 4. Webhook token authenticator       ← 外部 webhook
// 5. Bootstrap token authenticator     ← kubelet bootstrapping
```

---

## SubjectAccessReview（SAR）

SAR 查询"某个用户对某资源是否有某操作权限"。不写 etcd，即时返回。

### 两种 SAR

| 类型 | 用途 |
|------|------|
| `SubjectAccessReview` | 查询任意用户的权限（需要 admin 权限） |
| `SelfSubjectAccessReview` | 查询当前用户自己的权限 |
| `LocalSubjectAccessReview` | 在特定 namespace 内查询 |
| `SelfSubjectRulesReview` | 返回当前用户在 namespace 内的全部权限列表 |

### 处理路径

`pkg/registry/authorization/subjectaccessreview/rest.go`

```go
func (r *REST) Create(ctx, obj, createValidation, options) (runtime.Object, error) {
    // ← dlv 断点

    subjectAccessReview := obj.(*authorizationapi.SubjectAccessReview)

    // 调用 authorizer 链（与正常请求授权相同的路径）
    authorized, reason, err := r.authorizer.Authorize(ctx, authorizationattributes)

    subjectAccessReview.Status = authorizationapi.SubjectAccessReviewStatus{
        Allowed:         authorized == authorizer.DecisionAllow,
        Denied:          authorized == authorizer.DecisionDeny,
        Reason:          reason,
        EvaluationError: evaluationErr,
    }

    return subjectAccessReview, nil
    // 不写 etcd
}
```

### kubectl auth can-i 的底层

```bash
kubectl auth can-i get pods --as=system:serviceaccount:default:my-sa
# 底层：POST /apis/authorization.k8s.io/v1/subjectaccessreviews
# Body: {spec: {user: "system:serviceaccount:default:my-sa", verb: "get", resource: "pods"}}
```

---

## 三者对比

| 资源 | 写 etcd | 触发者 | 用途 |
|------|---------|--------|------|
| CSR | ✅ | 节点/用户 | 申请 TLS 证书 |
| TokenReview | ❌ | 外部服务 | 验证 JWT token |
| SubjectAccessReview | ❌ | controller / 外部服务 | 检查权限 |

---

## dlv 断点

```bash
# apiserver（port 2345）
# CSR 自动审批
b k8s.io/kubernetes/pkg/controller/certificates/approver.(*sarApprover).handle

# TokenReview
b k8s.io/kubernetes/pkg/registry/authentication/tokenreview.(*REST).Create

# SubjectAccessReview
b k8s.io/kubernetes/pkg/registry/authorization/subjectaccessreview.(*REST).Create

# Token 认证链
b k8s.io/apiserver/pkg/authentication/request/union.(*unionAuthRequestHandler).AuthenticateRequest
```

---

## 相关文档

| 文档 | 说明 |
|------|------|
| `16-serviceaccount.md` | ServiceAccount token 的生成与挂载 |
| `17-rbac.md` | RBAC Authorizer：SAR 的底层实现 |
