# HorizontalPodAutoscaler 创建链路

HPA 根据指标（CPU、内存、自定义指标）自动调整工作负载的副本数。它依赖 metrics-server（或 Prometheus Adapter）提供指标，通过 scale subresource 修改 Deployment/StatefulSet 的副本数。

**apiserver → etcd 路径**：见 `00-apiserver-common-flow.md`

---

## 接力图

```
kubectl apply -f hpa.yaml
    ↓
apiserver.Store.Create()   写入 HPA 对象
    ↓（每 15s 触发，默认 --horizontal-pod-autoscaler-sync-period）
HPAController.reconcileAutoscaler()
    ├── 获取当前副本数（通过 scale subresource）
    ├── 拉取指标（metrics.k8s.io API → metrics-server）
    ├── 计算期望副本数
    └── 更新副本数（PATCH scale subresource）
    ↓
Deployment/StatefulSet controller 检测到 replicas 变更
    ↓
创建/删除 Pod（见 02-replicaset.md / 04-statefulset.md）
```

---

## HPAController

`pkg/controller/podautoscaler/horizontal.go`

### 调度循环

```go
func (a *HorizontalController) Run(ctx) {
    // 每 syncPeriod（默认 15s）触发全量调谐
    go wait.UntilWithContext(ctx, a.worker, time.Second)
}

func (a *HorizontalController) reconcileAutoscaler(ctx, hpaShared, key) error {
    // ← dlv 断点

    hpa := hpaShared.DeepCopy()

    // 获取 scale 对象（当前副本数）
    scale, targetGR, _ := a.scaleForResourceMappings(ctx, hpa.Namespace, hpa.Spec.ScaleTargetRef)
    currentReplicas := scale.Spec.Replicas

    // 计算期望副本数（综合所有指标）
    desiredReplicas, metricStatuses, _ := a.computeReplicasForMetrics(ctx, hpa, scale)

    // 应用缩放冷却时间（防止频繁伸缩）
    desiredReplicas = a.normalizeDesiredReplicas(hpa, currentReplicas, desiredReplicas)

    // 更新副本数
    if desiredReplicas != currentReplicas {
        scale.Spec.Replicas = desiredReplicas
        _, err = scaleClient.Scales(hpa.Namespace).Update(ctx, targetGR, scale, metav1.UpdateOptions{})
        // PATCH /apis/apps/v1/namespaces/{ns}/deployments/{name}/scale
    }
}
```

### 指标计算

```go
func (a *HorizontalController) computeReplicasForMetrics(ctx, hpa, scale) (int32, []autoscalingv2.MetricStatus, time.Time, error) {
    // 遍历所有指标规则，取最大值（保守策略）
    for _, metricSpec := range hpa.Spec.Metrics {
        var replicaCountProposal int32

        switch metricSpec.Type {
        case autoscalingv2.ResourceMetricSourceType:
            // CPU / Memory
            replicaCountProposal, _ = a.computeStatusForResourceMetric(ctx, scale.Spec.Replicas, metricSpec)

        case autoscalingv2.PodsMetricSourceType:
            // 自定义 Pod 级别指标（每个 Pod 一个值）
            replicaCountProposal, _ = a.computeStatusForPodsMetric(scale.Spec.Replicas, metricSpec)

        case autoscalingv2.ObjectMetricSourceType:
            // K8s 对象级别指标（如 Ingress 的 RPS）
            replicaCountProposal, _ = a.computeStatusForObjectMetric(scale.Spec.Replicas, metricSpec)

        case autoscalingv2.ExternalMetricSourceType:
            // 外部指标（Prometheus、Datadog 等）
            replicaCountProposal, _ = a.computeStatusForExternalMetric(scale.Spec.Replicas, metricSpec)
        }

        if replicaCountProposal > replicas {
            replicas = replicaCountProposal  // 取所有指标建议的最大值
        }
    }
    return replicas, statuses, timestamp, nil
}
```

### CPU 利用率计算

```go
// pkg/controller/podautoscaler/metrics/rest_metrics_client.go
func (c *restMetricsClient) GetResourceMetric(ctx, resource, namespace, selector, container) (PodMetricsInfo, time.Time, error) {
    // 调用 metrics.k8s.io/v1beta1 API（由 metrics-server 实现）
    metrics, _ := c.metricsClient.MetricsV1beta1().PodMetricses(namespace).List(ctx, metav1.ListOptions{
        LabelSelector: selector.String(),
    })
    // 返回每个 Pod 的 CPU/Memory 使用量
}

// 计算期望副本数
func calcDesiredReplicas(currentReplicas int32, currentUtilization, targetUtilization int32) int32 {
    // 公式：desiredReplicas = ceil(currentReplicas × (currentUtil / targetUtil))
    // 例：currentReplicas=3, currentUtil=90%, targetUtil=50%
    //   → desiredReplicas = ceil(3 × 90/50) = ceil(5.4) = 6
    return int32(math.Ceil(float64(currentReplicas) * float64(currentUtilization) / float64(targetUtilization)))
}
```

---

## metrics-server

`github.com/kubernetes-sigs/metrics-server/`

metrics-server 实现 `metrics.k8s.io/v1beta1` API（通过 APIServer Aggregation），从 kubelet 的 Summary API 拉取数据：

```go
// pkg/scraper/scraper.go
func (s *scraper) Scrape(ctx) (*storage.MetricsBatch, error) {
    // 并发请求所有节点的 kubelet metrics
    for _, node := range nodes {
        go func(node *v1.Node) {
            // GET https://{node-ip}:10250/stats/summary
            summary, _ := s.kubeletClient.GetSummary(ctx, node)
            // summary 包含：节点 CPU/内存 + 每个 Pod 的 CPU/内存
        }(node)
    }
}
```

kubelet Summary API 的数据来源：
```
kubelet
    → cadvisor（嵌入 kubelet 内，通过 cgroups 读取容器资源）
        → /sys/fs/cgroup/cpu/kubepods/.../{containerId}/cpuacct.usage
        → /sys/fs/cgroup/memory/kubepods/.../{containerId}/memory.usage_in_bytes
```

---

## 缩放冷却（Stabilization Window）

```go
func (a *HorizontalController) normalizeDesiredReplicas(hpa, currentReplicas, desiredReplicas int32) int32 {
    // scaleUp 冷却：默认 0s（立即扩容）
    // scaleDown 冷却：默认 300s（5分钟内不缩容）
    // 防止指标抖动导致频繁伸缩

    stabilizationWindowSeconds := 300
    if hpa.Spec.Behavior.ScaleDown.StabilizationWindowSeconds != nil {
        stabilizationWindowSeconds = *hpa.Spec.Behavior.ScaleDown.StabilizationWindowSeconds
    }

    // 查看过去 stabilizationWindowSeconds 内的所有建议值，取最大值
    // 确保只有持续超负荷时才缩容
    return a.recommendations.getStabilizedRecommendation(hpa.Key(), isScaleDown, desiredReplicas)
}
```

---

## scale subresource

HPA 通过 scale subresource 更新目标资源，这是一个标准接口：

```go
// vendor/k8s.io/api/autoscaling/v1/types.go
type Scale struct {
    Spec   ScaleSpec   { Replicas int32 }
    Status ScaleStatus { Replicas int32; Selector string }
}
```

所有支持自动伸缩的资源（Deployment、ReplicaSet、StatefulSet、ReplicationController）都实现了 scale subresource：
```
GET  /apis/apps/v1/namespaces/{ns}/deployments/{name}/scale
PUT  /apis/apps/v1/namespaces/{ns}/deployments/{name}/scale
```

---

## dlv 断点

```bash
# controller-manager（port 2346）
b k8s.io/kubernetes/pkg/controller/podautoscaler.(*HorizontalController).reconcileAutoscaler
b k8s.io/kubernetes/pkg/controller/podautoscaler.(*HorizontalController).computeReplicasForMetrics
b k8s.io/kubernetes/pkg/controller/podautoscaler/metrics.(*restMetricsClient).GetResourceMetric
```

---

## 相关文档

| 文档 | 说明 |
|------|------|
| `03-deployment.md` | HPA 修改的目标 Deployment |
| `04-statefulset.md` | HPA 也支持 StatefulSet |
| `14-scheduling.md` | PriorityClass：HPA 扩容时新 Pod 的调度优先级 |
