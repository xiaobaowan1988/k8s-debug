# ConfigMap + Secret 创建链路

ConfigMap 存储非敏感配置，Secret 存储敏感数据（密码、证书、令牌）。两者 API 结构相似，但 Secret 有额外的加密和 RBAC 控制。注入到 Pod 的方式相同：环境变量或挂载为文件。

**apiserver → etcd 路径**：见 `00-apiserver-common-flow.md`（两者均无独立 controller）

---

## 接力图

```
kubectl create configmap / kubectl create secret
    ↓
apiserver.Store.Create()
    ├── Secret 额外步骤：EncryptionConfiguration（静态加密）
    │     → AES-GCM / AES-CBC 加密 data 字段后再写 etcd
    └── 写入 etcd（/registry/configmaps/{ns}/{name} 或 /registry/secrets/{ns}/{name}）
    ↓（没有 controller，直接到消费方）
两路消费：
    ├── 环境变量：kubelet syncPod 启动容器前注入
    └── Volume 挂载：kubelet configmap/secret volume plugin 写文件
```

---

## 静态加密（Secret at Rest）

`vendor/k8s.io/apiserver/pkg/storage/value/encrypt/`

如果配置了 `EncryptionConfiguration`（`--encryption-provider-config`）：

```go
// vendor/k8s.io/apiserver/pkg/storage/value/encrypt/aes/aes.go
func (t *aesgcm) TransformToStorage(ctx, data []byte, dataCtx value.Context) ([]byte, bool, error) {
    // 生成随机 nonce
    nonce := make([]byte, t.block.Overhead())
    rand.Read(nonce)

    // AES-GCM 加密
    ciphertext := t.block.Seal(nonce, nonce, data, dataCtx.AuthenticatedData())
    return ciphertext, false, nil
}
```

etcd 里存的是密文，只有 apiserver 有密钥解密。`kubectl get secret -o yaml` 看到的是 base64 编码的原文（apiserver 解密后返回）。

---

## kubelet：环境变量注入

`pkg/kubelet/kubelet_pods.go`

```go
func (kl *Kubelet) makeEnvironmentVariables(pod, container, podIP) ([]v1.EnvVar, error) {
    // 处理 envFrom（整个 ConfigMap/Secret 作为环境变量）
    for _, envFrom := range container.EnvFrom {
        if envFrom.ConfigMapRef != nil {
            cm, _ := kl.configMapManager.GetConfigMap(pod.Namespace, envFrom.ConfigMapRef.Name)
            for k, v := range cm.Data {
                result = append(result, v1.EnvVar{Name: prefix + k, Value: v})
            }
        }
        if envFrom.SecretRef != nil {
            secret, _ := kl.secretManager.GetSecret(pod.Namespace, envFrom.SecretRef.Name)
            for k, v := range secret.Data {
                result = append(result, v1.EnvVar{Name: prefix + k, Value: string(v)})
            }
        }
    }

    // 处理单个 env.valueFrom
    for _, envVar := range container.Env {
        if envVar.ValueFrom != nil {
            switch {
            case envVar.ValueFrom.ConfigMapKeyRef != nil:
                cm, _ := kl.configMapManager.GetConfigMap(...)
                result = append(result, v1.EnvVar{Name: envVar.Name, Value: cm.Data[key]})
            case envVar.ValueFrom.SecretKeyRef != nil:
                secret, _ := kl.secretManager.GetSecret(...)
                result = append(result, v1.EnvVar{Name: envVar.Name, Value: string(secret.Data[key])})
            }
        }
    }
    return result, nil
}
```

环境变量**启动时注入一次，不会自动更新**。ConfigMap/Secret 变更后需要重启容器。

---

## kubelet：Volume 挂载（热更新路径）

`pkg/kubelet/volumemanager/` + `pkg/volume/configmap/configmap.go`

```go
// pkg/volume/configmap/configmap.go
func (b *configMapVolumeMounter) SetUp(mounterArgs volume.MounterArgs) error {
    // 获取 ConfigMap 最新内容
    configMap, _ := b.plugin.getConfigMap(b.pod.Namespace, b.source.Name)

    // 在 Pod volume 目录写文件
    // /var/lib/kubelet/pods/{UID}/volumes/kubernetes.io~configmap/{volName}/
    for key, value := range configMap.Data {
        filePath := filepath.Join(volumePath, key)
        os.WriteFile(filePath, []byte(value), 0644)
    }

    // 使用 atomic 写（先写临时目录，再 rename）保证一致性
    // 实际实现：写到 ..data_tmp/，然后 rename → ..data（symlink 切换）
}
```

**热更新机制**：kubelet 定期（默认 60s，`--sync-frequency`）重新同步 volume：

```go
// pkg/kubelet/volumemanager/reconciler/reconciler.go
func (rc *reconciler) reconcile(ctx) {
    for _, mountedVolume := range rc.actualStateOfWorld.GetMountedVolumes() {
        // 检查 ConfigMap/Secret 是否有更新
        // 有更新则重新调用 SetUp，原子替换文件
    }
}
```

容器内挂载的文件通过 **symlink**（`..data → ..2024_01_01_12_00_00.000000000`）实现原子切换，内核在 `rename()` 系统调用完成后立即生效，正在读取的进程不受影响。

---

## Secret 类型

| 类型 | 用途 |
|------|------|
| `Opaque` | 通用（默认） |
| `kubernetes.io/service-account-token` | ServiceAccount token（自动创建） |
| `kubernetes.io/tls` | TLS 证书（`tls.crt` + `tls.key`） |
| `kubernetes.io/dockerconfigjson` | 镜像仓库认证 |
| `kubernetes.io/basic-auth` | 用户名/密码 |
| `kubernetes.io/ssh-auth` | SSH 私钥 |

kubelet 拉取镜像时会查找 `imagePullSecrets`：

```go
// pkg/kubelet/images/image_manager.go
func (m *imageManager) EnsureImageExists(ctx, pod, pullSecrets) (string, string, error) {
    // 从 imagePullSecrets 解析 docker auth
    keyring, _ := credentialprovider.MakeDockerKeyring(pullSecrets, m.puller.defaultKeyring)
    // 调用 CRI PullImage，传入 auth 信息
    m.runtimeService.PullImage(ctx, imageRef, authConfig, podSandboxConfig)
}
```

---

## configMapManager / secretManager 缓存

kubelet 不直接每次调用 apiserver，而是用带 watch 的缓存：

```go
// pkg/kubelet/configmap/configmap_manager.go
type cacheBasedManager struct {
    objectStore     *objectStore    // 本地缓存
    getObjectFunc   GetObjectFunc   // 从 apiserver 拉取的函数
}

// 两种实现：
// 1. WatchBasedManager：watch apiserver，实时感知变更（默认）
// 2. TTLBasedManager：按 TTL 过期刷新
```

---

## dlv 断点

```bash
# kubelet（port 2348）
# 环境变量注入
b k8s.io/kubernetes/pkg/kubelet.(*Kubelet).makeEnvironmentVariables

# Volume 挂载
b k8s.io/kubernetes/pkg/volume/configmap.(*configMapVolumeMounter).SetUp
b k8s.io/kubernetes/pkg/volume/secret.(*secretVolumeMounter).SetUp
```

---

## strace（文件原子切换）

```bash
# 观察 ConfigMap/Secret volume 热更新时的 rename 操作
strace -p <kubelet-PID> -f -e trace=rename,symlink,openat \
    2>&1 | grep -E 'configmap|secret|\.\.data'
```

---

## 相关文档

| 文档 | 说明 |
|------|------|
| `16-serviceaccount.md` | ServiceAccount 关联的 Secret（token） |
| `11-ingress.md` | Ingress TLS Secret 挂载 |
| `01-pod.md` | kubelet syncPod：环境变量注入和 volume 挂载时机 |
