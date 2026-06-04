# ServiceAccount + TokenRequest 创建链路

ServiceAccount 是 Pod 在集群内的身份标识。kubelet 自动为 Pod 挂载 ServiceAccount token，Pod 内的进程用这个 token 调用 apiserver。

**apiserver → etcd 路径**：见 `00-apiserver-common-flow.md`

---

## 接力图

```
kubectl create serviceaccount my-sa（或 Namespace 创建时自动创建 default SA）
    ↓
apiserver.Store.Create()   写入 ServiceAccount
    ↓（两路并行）
    ├── ServiceAccount admission plugin
    │     → Pod 创建时自动注入 serviceAccountName: default
    └── TokenController（controller-manager，旧版）
          → 为每个 SA 创建 Secret（kubernetes.io/service-account-token 类型）
          （K8s 1.24+ 默认不再自动创建 long-lived token Secret）
    ↓
Pod 创建时，kubelet 通过 TokenRequest API 申请短期 token
    ↓
ServiceAccountToken volume plugin 挂载 projected volume
    → /var/run/secrets/kubernetes.io/serviceaccount/token（自动轮换）
```

---

## ServiceAccount Admission Plugin

`plugin/pkg/admission/serviceaccount/admission.go`

```go
func (s *Plugin) Admit(ctx, a admission.Attributes, o admission.ObjectInterfaces) error {
    pod := a.GetObject().(*api.Pod)

    // 1. 注入默认 serviceAccountName
    if pod.Spec.ServiceAccountName == "" {
        pod.Spec.ServiceAccountName = "default"
    }

    // 2. 验证 ServiceAccount 存在
    serviceAccount, _ := s.getServiceAccount(pod.Namespace, pod.Spec.ServiceAccountName)

    // 3. 注入 imagePullSecrets（ServiceAccount.ImagePullSecrets → Pod.Spec.ImagePullSecrets）
    for _, reference := range serviceAccount.ImagePullSecrets {
        pod.Spec.ImagePullSecrets = append(pod.Spec.ImagePullSecrets, v1.LocalObjectReference{Name: reference.Name})
    }

    // 4. 注入 projected volume（token + ca.crt + namespace）
    pod.Spec.Volumes = append(pod.Spec.Volumes, s.getServiceAccountVolume(serviceAccount))
}
```

注入的 projected volume 定义：

```go
func (s *Plugin) getServiceAccountVolume(serviceAccount *v1.ServiceAccount) v1.Volume {
    return v1.Volume{
        Name: serviceAccountVolumeName,
        VolumeSource: v1.VolumeSource{
            Projected: &v1.ProjectedVolumeSource{
                Sources: []v1.VolumeProjection{
                    {
                        ServiceAccountToken: &v1.ServiceAccountTokenProjection{
                            Path:              "token",
                            ExpirationSeconds: &expirationSeconds,  // 默认 3600s（1小时）
                        },
                    },
                    {
                        ConfigMap: &v1.ConfigMapProjection{
                            LocalObjectReference: v1.LocalObjectReference{Name: "kube-root-ca.crt"},
                            Items: []v1.KeyToPath{{Key: "ca.crt", Path: "ca.crt"}},
                        },
                    },
                    {
                        DownwardAPI: &v1.DownwardAPIProjection{
                            Items: []v1.DownwardAPIVolumeFile{
                                {Path: "namespace", FieldRef: &v1.ObjectFieldSelector{FieldPath: "metadata.namespace"}},
                            },
                        },
                    },
                },
            },
        },
    }
}
```

---

## TokenRequest API

`pkg/registry/core/serviceaccount/token/rest.go`

kubelet 在 syncPod 时调用 TokenRequest API 为每个 Pod 申请短期 token：

```go
func (r *REST) Create(ctx, name, obj, createValidation, options) (runtime.Object, error) {
    // ← dlv 断点

    tokenRequest := obj.(*authenticationv1.TokenRequest)
    sa, _ := r.svcaccts.GetServiceAccount(ctx, name, ...)

    // 生成 JWT token
    // JWT payload 包含：
    //   iss: kubernetes/serviceaccount
    //   sub: system:serviceaccount:{namespace}:{name}
    //   aud: [api（或自定义 audience）]
    //   exp: now + expirationSeconds
    //   kubernetes.io/pod.name: {pod-name}
    //   kubernetes.io/pod.uid:  {pod-uid}  ← 绑定到特定 Pod（失效时机）

    token, _ := r.issuer.GenerateToken(ctx, claims)
    return &authenticationv1.TokenRequest{
        Status: authenticationv1.TokenRequestStatus{
            Token:               token,
            ExpirationTimestamp: expiration,
        },
    }, nil
}
```

Token 是有时效的 JWT，kubelet 在到期前（默认提前 80% 时间）自动轮换，容器内文件内容自动更新。

---

## kubelet：projected volume 挂载

`pkg/volume/projected/projected.go`

```go
func (b *projectedVolumeMounter) SetUp(mounterArgs volume.MounterArgs) error {
    // 对每个 source 分别处理
    for _, source := range b.source.Sources {
        if source.ServiceAccountToken != nil {
            // 调用 TokenRequest API 获取 token
            token, _ := b.plugin.getServiceAccountToken(b.pod, source.ServiceAccountToken)
            // 写入文件
            os.WriteFile(filepath.Join(mountPath, source.ServiceAccountToken.Path), []byte(token.Status.Token), 0600)
        }
        if source.ConfigMap != nil {
            // 写入 ca.crt
        }
        if source.DownwardAPI != nil {
            // 写入 namespace 文件
        }
    }
}
```

挂载后容器内的路径：
```
/var/run/secrets/kubernetes.io/serviceaccount/
├── token      # JWT，1小时到期，自动轮换
├── ca.crt     # 集群 CA 证书，验证 apiserver TLS
└── namespace  # Pod 所在 namespace 名称
```

---

## Token 轮换机制

`pkg/kubelet/token/token_manager.go`

```go
func (m *Manager) GetServiceAccountToken(namespace, name string, tr *authenticationv1.TokenRequest) (*authenticationv1.TokenRequest, error) {
    // 检查缓存中的 token 是否即将到期
    if cached != nil && !m.requiresRefresh(cached) {
        return cached, nil
    }

    // 向 apiserver 申请新 token
    token, _ := m.kubeClient.CoreV1().ServiceAccounts(namespace).CreateToken(ctx, name, tr, ...)

    // 缓存并返回
    m.cache[key] = token
    return token, nil
}

func (m *Manager) requiresRefresh(tr *authenticationv1.TokenRequest) bool {
    // 已过到期时间 80% 就刷新
    // 例如 1 小时的 token，48 分钟后开始刷新
    lifetime := tr.Status.ExpirationTimestamp.Time.Sub(tr.CreationTimestamp.Time)
    return time.Now().After(tr.CreationTimestamp.Time.Add(lifetime * 80 / 100))
}
```

---

## RBAC 与 ServiceAccount

ServiceAccount 通过 RBAC 绑定权限：

```yaml
# 创建 RoleBinding 把权限授予 ServiceAccount
kind: RoleBinding
subjects:
  - kind: ServiceAccount
    name: my-sa
    namespace: default
roleRef:
  kind: Role
  name: pod-reader
```

apiserver 收到 Pod 内的请求时（Bearer token），通过 TokenReview 验证 JWT，提取 `system:serviceaccount:default:my-sa` 作为用户名，再经过 RBAC authorizer 检查权限（见 `17-rbac.md`）。

---

## dlv 断点

```bash
# apiserver（port 2345）
# ServiceAccount admission（Pod 创建时）
b k8s.io/kubernetes/plugin/pkg/admission/serviceaccount.(*Plugin).Admit

# TokenRequest API
b k8s.io/kubernetes/pkg/registry/core/serviceaccount/token.(*REST).Create

# kubelet（port 2348）
b k8s.io/kubernetes/pkg/kubelet/token.(*Manager).GetServiceAccountToken
b k8s.io/kubernetes/pkg/volume/projected.(*projectedVolumeMounter).SetUp
```

---

## 相关文档

| 文档 | 说明 |
|------|------|
| `17-rbac.md` | RBAC：ServiceAccount 的权限授予 |
| `15-config-secret.md` | Secret：旧版 long-lived token Secret |
| `21-auth-resources.md` | TokenReview：验证 JWT token |
