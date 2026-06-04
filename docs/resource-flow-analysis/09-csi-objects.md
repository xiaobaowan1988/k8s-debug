# CSIDriver / CSINode / CSIStorageCapacity

这三个对象是 CSI 插件注册和拓扑感知的基础设施，不直接参与卷的创建/挂载操作，但决定了调度器和 kubelet 如何发现和选择 CSI driver。

---

## 三个对象的职责

| 对象 | 创建者 | 职责 |
|------|--------|------|
| `CSIDriver` | CSI driver 部署时（DaemonSet/Deployment） | 声明 driver 的能力（是否需要 attach、是否支持扩容等） |
| `CSINode` | kubelet（通过 node-driver-registrar sidecar） | 记录每个节点上已注册的 CSI driver 及其拓扑标签 |
| `CSIStorageCapacity` | external-provisioner（可选） | 报告每个拓扑区域的可用存储容量，供调度器使用 |

---

## CSIDriver 注册流程

`pkg/controller/volume/csistoragecapacity/` +
`vendor/k8s.io/csi-translation-lib/`

### 创建时机

CSI driver 部署（通常是 DaemonSet + Deployment）时，驱动的安装脚本或 Helm chart 会创建 CSIDriver 对象：

```bash
kubectl apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: CSIDriver
metadata:
  name: hostpath.csi.k8s.io
spec:
  attachRequired: false          # 是否需要 ControllerPublishVolume
  podInfoOnMount: true           # 挂载时把 Pod 信息传给 driver
  volumeLifecycleModes:
    - Persistent                 # 支持持久卷（也可以 Ephemeral）
  storageCapacity: false         # 是否上报容量信息
  fsGroupPolicy: File            # fsGroup 如何应用到挂载点
  requiresRepublish: false       # 是否需要 NodePublishVolume 幂等重试
EOF
```

### apiserver 处理

与普通对象相同：`registry.(*Store).Create()` → etcd。

### kubelet 如何使用 CSIDriver

`pkg/volume/csi/csi_plugin.go`

```go
func (p *csiPlugin) NewMounter(spec, pod, opts) (volume.Mounter, error) {
    // 查询 CSIDriver 对象，决定行为
    csiDriver, _ := p.csiDriverLister.Get(driverName)

    if csiDriver.Spec.PodInfoOnMount {
        // 在 NodePublishVolumeRequest 中注入 Pod 信息
        publishContext["csi.storage.k8s.io/pod.name"] = pod.Name
        publishContext["csi.storage.k8s.io/pod.namespace"] = pod.Namespace
    }

    if csiDriver.Spec.AttachRequired != nil && !*csiDriver.Spec.AttachRequired {
        // 跳过 VolumeAttachment，直接调用 NodeStageVolume
    }
}
```

---

## CSINode 注册流程

每个节点上的 `node-driver-registrar` sidecar 负责将 CSI driver 信息写入 CSINode 对象。

### node-driver-registrar 工作原理

`github.com/kubernetes-csi/node-driver-registrar/`

```go
// 1. 调用 CSI Identity gRPC 获取 driver 信息
nodeID, topology, _ := csiClient.NodeGetInfo(ctx, &csi.NodeGetInfoRequest{})
// nodeID:   driver 分配给本节点的唯一 ID
// topology: 本节点的拓扑标签（如 {topology.kubernetes.io/zone: us-east1-a}）

// 2. 将信息写入 CSINode 对象
csiNode := &storagev1.CSINode{
    ObjectMeta: metav1.ObjectMeta{Name: nodeName},
    Spec: storagev1.CSINodeSpec{
        Drivers: []storagev1.CSINodeDriver{
            {
                Name:         driverName,
                NodeID:       nodeID,
                TopologyKeys: topologyKeys,   // 拓扑维度列表
                Allocatable: &storagev1.VolumeNodeResources{
                    Count: maxVolumesPerNode,  // 本节点最多能挂载多少卷
                },
            },
        },
    },
}
kubeClient.StorageV1().CSINodes().Create(ctx, csiNode, ...)
```

### scheduler 如何使用 CSINode

`pkg/scheduler/framework/plugins/volumebinding/binder.go`

```go
func (b *VolumeBinder) FindPodVolumes(pod, boundClaims, unboundClaims, node) (podVolumes, reasons, err) {
    // 查询该节点的 CSINode，获取最大卷挂载数
    csiNode, _ := b.csiNodeLister.Get(node.Name)
    maxAttachLimit := getMaxAttachLimit(csiNode, driverName)
    currentAttachCount := getAttachedVolumesCount(node, driverName)

    if currentAttachCount >= maxAttachLimit {
        // 节点卷已满，过滤掉这个节点
        reasons = append(reasons, ErrReasonMaxVolumeCount)
    }

    // 检查 PVC 的拓扑要求是否与节点拓扑兼容
    // CSINode 上的 TopologyKeys 对应 PV 的 nodeAffinity
}
```

---

## CSIStorageCapacity 上报流程

当 `CSIDriver.Spec.StorageCapacity = true` 时，external-provisioner 会定期上报容量信息：

`github.com/kubernetes-sigs/sig-storage-lib-external-provisioner/controller/`

```go
func (c *capacityController) syncCapacity(ctx) error {
    // 调用 CSI driver gRPC 获取可用容量
    resp, _ := c.csiClient.GetCapacity(ctx, &csi.GetCapacityRequest{
        VolumeCapabilities: caps,
        Parameters:         storageClass.Parameters,
        AccessibleTopology: topology,  // 按拓扑区域查询
    })

    // 创建/更新 CSIStorageCapacity 对象
    capacity := &storagev1.CSIStorageCapacity{
        NodeTopology:    topology,           // 适用的拓扑区域
        StorageClassName: storageClass.Name,
        Capacity:        resource.NewQuantity(resp.AvailableCapacity, resource.BinarySI),
    }
    kubeClient.StorageV1().CSIStorageCapacities(namespace).Create(ctx, capacity, ...)
}
```

### scheduler 如何使用 CSIStorageCapacity

`pkg/scheduler/framework/plugins/volumebinding/binder.go`

```go
// WaitForFirstConsumer 模式下，调度时检查目标节点的可用容量
func (b *VolumeBinder) checkVolumeProvisions(pod, claimsToProvision, node) (sufficientStorage, reasons, err) {
    for _, claim := range claimsToProvision {
        storageClass, _ := b.classLister.Get(*claim.Spec.StorageClassName)

        if storageClass.VolumeBindingMode == storagev1.VolumeBindingWaitForFirstConsumer {
            // 查询该节点拓扑的 CSIStorageCapacity
            capacities, _ := b.csiStorageCapacityLister.List(selector)

            sufficientCapacity := false
            for _, cap := range capacities {
                if cap.NodeTopology 与 node 拓扑兼容 &&
                   cap.Capacity >= claim.Spec.Resources.Requests.Storage {
                    sufficientCapacity = true
                }
            }
            if !sufficientCapacity {
                reasons = append(reasons, "insufficient storage capacity")
            }
        }
    }
}
```

---

## 三者关系图

```
CSI driver 部署
    ├── 创建 CSIDriver 对象        ← 全局，描述 driver 能力
    └── 每个节点 node-driver-registrar
            ├── 调用 CSI NodeGetInfo gRPC
            └── 创建/更新 CSINode 对象   ← 每节点，记录拓扑 + 最大卷数

external-provisioner（可选）
    ├── 定期调用 CSI GetCapacity gRPC
    └── 创建/更新 CSIStorageCapacity    ← 每(拓扑区域 × StorageClass)，记录可用容量

scheduler VolumeBinding plugin
    ├── 读 CSINode.Spec.Allocatable    → 检查节点卷挂载上限
    ├── 读 CSINode.Spec.TopologyKeys   → 检查拓扑兼容性
    └── 读 CSIStorageCapacity          → 检查容量是否足够（WaitForFirstConsumer）

kubelet
    └── 读 CSIDriver.Spec              → 决定是否 attach、是否注入 Pod 信息
```

---

## dlv 断点

```bash
# scheduler VolumeBinding plugin（port 2347）
b k8s.io/kubernetes/pkg/scheduler/framework/plugins/volumebinding.(*VolumeBinding).Filter
b k8s.io/kubernetes/pkg/scheduler/framework/plugins/volumebinding.(*VolumeBinder).FindPodVolumes

# kubelet CSI plugin（port 2348）
b k8s.io/kubernetes/pkg/volume/csi.(*csiPlugin).NewMounter
```

---

## 相关文档

| 文档 | 说明 |
|------|------|
| `07-pvc-dynamic.md` | PVC 动态配置：CSIDriver 影响 external-provisioner 行为 |
| `08-pv-static.md` | VolumeAttachment：attachRequired 字段的影响 |
| `01-pod.md` | kubelet NodeStageVolume / NodePublishVolume |
