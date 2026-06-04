# Ingress + IngressClass 创建链路

Ingress 提供 HTTP/HTTPS 的 L7 路由规则（按 Host/Path 转发到 Service）。IngressClass 指定使用哪个 Ingress Controller。Ingress Controller 本身是一个独立的 Pod（不是 K8s 内置 controller），watch Ingress 对象后动态更新自身配置。

**apiserver → etcd 路径**：见 `00-apiserver-common-flow.md`

---

## 接力图

```
kubectl apply -f ingress.yaml
    ↓
apiserver.Store.Create()   写入 Ingress 对象
    ↓ watch 事件
Ingress Controller（如 nginx-ingress-controller Pod）
    └── informer watch Ingress + Service + Endpoints
    ↓
generateNginxConfig() / 等价的配置生成逻辑
    ├── 遍历 Ingress.Spec.Rules，生成 upstream + server block
    └── 写入临时文件 → nginx -s reload（或 configmap 热更新）
    ↓ syscall
execve/kill(nginx, SIGHUP) → 内核加载新配置
```

---

## IngressClass

```yaml
apiVersion: networking.k8s.io/v1
kind: IngressClass
metadata:
  name: nginx
  annotations:
    ingressclass.kubernetes.io/is-default-class: "true"  # 默认 IngressClass
spec:
  controller: k8s.io/ingress-nginx   # controller 的标识符
  parameters:                         # 可选的 controller 级参数
    apiGroup: k8s.io
    kind: IngressParameters
    name: nginx-params
```

IngressClass 本身只是一个配置声明，apiserver 写入 etcd 后，对应 controller 通过 `.spec.controller` 字段认领。

---

## Ingress Controller：以 ingress-nginx 为例

`github.com/kubernetes/ingress-nginx/internal/ingress/controller/`

### 启动与 informer

```go
func NewNGINXController(config, mc, fs) *NGINXController {
    n := &NGINXController{
        cfg:  config,
        store: store.New(
            config.Namespace,
            kubeClient,
            resyncPeriod,
            // watch 这些资源：
            // Ingress, Service, Endpoints, Secret（TLS），ConfigMap
        ),
        updateCh: channels.NewRingChannel(1024),
    }
}
```

### watch 回调触发重新配置

```go
func (n *NGINXController) syncIngress(interface{}) {
    // ← 关键函数（ingress-nginx 进程）

    ings := n.store.ListIngresses()

    // 根据所有 Ingress 对象生成 nginx 配置
    pcfg, err := n.store.GetBackendConfiguration()
    upstreams, servers := n.getBackendServers(ings)
    // upstreams：每个 Service/Port 对应一个 upstream 块
    //   upstream default-nginx-svc-80 { server 10.0.0.1:80; server 10.0.0.2:80; }
    // servers：每个 host 对应一个 server 块
    //   server { server_name foo.example.com; location /api { proxy_pass upstream... } }

    cfg := n.store.GetBackendConfiguration()
    n.updateConfiguration(cfg, upstreams, servers)
}
```

### 生成并加载 nginx 配置

```go
func (n *NGINXController) updateConfiguration(cfg, upstreams, servers) {
    // 渲染 nginx.conf 模板
    content, err := n.t.Write(config.TemplateConfig{
        Upstreams: upstreams,
        Servers:   servers,
        ...
    })
    // 写入 /etc/nginx/nginx.conf

    // 测试配置是否合法
    out, err := n.command.Test("/etc/nginx/nginx.conf")
    // syscall: execve("/usr/sbin/nginx", ["-t", "-c", "/etc/nginx/nginx.conf"])

    if err == nil {
        // 热重载：发 HUP 信号
        n.command.ExecCommand("-s", "reload")
        // syscall: kill(nginx_master_pid, SIGHUP)
        // nginx master 收到 SIGHUP 后：启动新 worker → 新 worker 加载配置 →
        //   通知旧 worker 优雅退出（处理完当前请求后退出）
    }
}
```

---

## Ingress 规则解析

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-ingress
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  ingressClassName: nginx
  tls:
    - hosts: [foo.example.com]
      secretName: tls-secret      # TLS 证书存在 Secret 里
  rules:
    - host: foo.example.com
      http:
        paths:
          - path: /api
            pathType: Prefix
            backend:
              service:
                name: api-svc
                port:
                  number: 80
          - path: /
            pathType: Prefix
            backend:
              service:
                name: web-svc
                port:
                  number: 80
```

Controller 解析后生成：
```nginx
upstream default-api-svc-80   { server <pod-ip>:8080; ... }
upstream default-web-svc-80   { server <pod-ip>:3000; ... }

server {
    listen 443 ssl;
    server_name foo.example.com;
    ssl_certificate     /etc/ingress-controller/ssl/default-tls-secret.pem;

    location /api {
        proxy_pass http://default-api-svc-80;
        rewrite ^/api/(.*)$ /$1 break;
    }
    location / {
        proxy_pass http://default-web-svc-80;
    }
}
```

---

## TLS Secret 挂载

Controller 监听 Secret 变更，Secret 包含 `tls.crt` + `tls.key`：

```go
func (s *k8sStore) syncSecret(key string) {
    namespace, name, _ := cache.SplitMetaNamespaceKey(key)
    secret, _ := s.listers.Secret.Secrets(namespace).Get(name)

    if secret.Type == v1.SecretTypeTLS {
        // 写入文件系统，nginx 直接读文件
        cert, key := secret.Data["tls.crt"], secret.Data["tls.key"]
        os.WriteFile("/etc/ingress-controller/ssl/"+namespace+"-"+name+".pem", cert, 0600)
        // 触发 nginx reload
    }
}
```

---

## 与 Gateway API 的关系

Gateway API（`gateway.networking.k8s.io/v1`）是 Ingress 的继任者，提供更精细的控制（HTTPRoute、TCPRoute 等），但核心机制相同：controller watch 路由对象 → 生成代理配置 → reload。

---

## strace（ingress-nginx controller）

```bash
# 观察 nginx reload 触发
strace -p <ingress-controller-PID> -f \
    -e trace=execve,kill,openat \
    -e signal=none \
    2>&1 | grep -E 'nginx|reload|SIGHUP'
```

---

## 相关文档

| 文档 | 说明 |
|------|------|
| `10-service-endpoints.md` | Service：Ingress backend 的实际目标 |
| `12-networkpolicy.md` | 网络访问控制 |
| `15-config-secret.md` | Secret：TLS 证书存储 |
