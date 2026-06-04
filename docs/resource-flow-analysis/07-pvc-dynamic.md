# PVC + StorageClass 动态配置链路

PersistentVolumeClaim（PVC）是 Pod 申请存储的方式。StorageClass 定义动态配置策略。本文覆盖动态配置路径（最常见场景）：PVC 创建 → CSI driver 创建卷 → PV 绑定到 PVC。

**apiserver → etcd 路径**：见 `00-apiserver-common-flow.md`
**CSI driver 侧（CreateVolume）**：见 `../kernel-syscall-verification.md` 中的 StatefulSet 链路

---

## 接力图

```
kubectl apply -f pvc.yaml（或 StatefulSet volumeClaimTemplates 自动创建）
    ↓
apiserver.Store.Create()   写入 PVC（Status.Phase = Pending）
    ↓ watch 事件
PersistentVolumeController.syncUnboundClaim()
    ├── 静态配置路径：findBestMatchForClaim() 找已有 PV → 跳到 bindVolumeToClaim()
    └── 动态配置路径：provisionClaim() → 触发 external-provisioner
    ↓
external-provisioner（独立进程）
    ↓ gRPC CreateVolumeRequest
CSI driver.CreateVolume()
    ↓ 返回 VolumeId
external-provisioner 创建 PV 对象（Status.Phase = Available）
    ↓ watch 事件
PersistentVolumeController.syncBoundClaim() / bindVolumeToClaim()
    ↓ 双向绑定
PVC.Status.Phase = Bound
PV.Status.Phase = Bound
    ↓ Pod 可以被 scheduler 调度
```

---

## PersistentVolumeController

`pkg/controller/volume/persistentvolume/pv_controller.go`

### 两个核心工作队列

```go
type PersistentVolumeController struct {
    // claimQueue：处理 PVC 变更
    claimQueue  workqueue.RateLimitingInterface
    // volumeQueue：处理 PV 变更
    volumeQueue workqueue.RateLimitingInterface
}

func (ctrl *PersistentVolumeController) Run(ctx) {
    go wait.UntilWithContext(ctx, ctrl.runClaimWorker, time.Second)
    go wait.UntilWithContext(ctx, ctrl.runVolumeWorker, time.Second)
}
```

### syncUnboundClaim：处理未绑定的 PVC

```go
func (ctrl *PersistentVolumeController) syncUnboundClaim(ctx, claim *v1.PersistentVolumeClaim) error {
    // ← dlv 断点

    // 判断 claim 是否已指定 VolumeName（预绑定）
    if claim.Spec.VolumeName == "" {
        // 没有预绑定，走自动配置流程

        // 1. 先找已有的 PV（静态配置路径）
        volume, err := ctrl.volumes.findBestMatchForClaim(claim, false)
        if volume != nil {
            // 找到合适的 PV，执行绑定
            return ctrl.bind(ctx, volume, claim)
        }

        // 2. 没有可用 PV，走动态配置
        if storageClass := getStorageClass(claim); storageClass != nil {
            if storageClass.VolumeBindingMode == storagev1.VolumeBindingImmediate {
                // 立即配置（Immediate 模式）
                return ctrl.provisionClaim(ctx, claim)
            }
            // WaitForFirstConsumer：等 Pod 被调度到节点后再配置（延迟绑定）
            // scheduler 的 VolumeBinding plugin 负责触发
        }
    } else {
        // 有预绑定 VolumeName，直接尝试绑定该 PV
        return ctrl.syncBoundClaim(ctx, claim)
    }
}
```

### provisionClaim：触发动态配置

```go
func (ctrl *PersistentVolumeController) provisionClaim(ctx, claim *v1.PersistentVolumeClaim) error {
    // 记录 annotation，告诉 external-provisioner 需要配置
    // annotation: volume.beta.kubernetes.io/storage-provisioner = storageClass.Provisioner
    metav1.SetMetaDataAnnotation(&claim.ObjectMeta,
        storagehelper.AnnStorageProvisioner, storageClass.Provisioner)

    ctrl.kubeClient.CoreV1().PersistentVolumeClaims(claim.Namespace).Update(ctx, claim, ...)
    // external-provisioner watch 到这个 annotation 后开始工作
}
```

---

## external-provisioner（独立进程）

`github.com/kubernetes-sigs/sig-storage-lib-external-provisioner/`（库）

external-provisioner 是一个 sidecar，与 CSI driver 一起部署：

```go
// controller.go
func (p *csiProvisioner) Provision(ctx, options controller.ProvisionOptions) (*v1.PersistentVolume, controller.ProvisioningState, error) {
    // ← dlv 断点（external-provisioner 进程）

    // 构造 CSI gRPC 请求
    req := &csi.CreateVolumeRequest{
        Name:               pvName,
        CapacityRange:      &csi.CapacityRange{RequiredBytes: capacityBytes},
        VolumeCapabilities: volumeCaps,
        Parameters:         storageClass.Parameters,    // 透传 StorageClass 参数
        Secrets:            provisionerSecrets,
        AccessibilityRequirements: topologyReq,         // WaitForFirstConsumer 时包含节点拓扑
    }

    // 调用 CSI driver gRPC（Unix socket）
    rep, err := p.csiClient.CreateVolume(ctx, req)

    // 用返回的 VolumeId 构造 PV 对象
    pv := &v1.PersistentVolume{
        Spec: v1.PersistentVolumeSpec{
            PersistentVolumeSource: v1.PersistentVolumeSource{
                CSI: &v1.CSIPersistentVolumeSource{
                    Driver:       p.driverName,
                    VolumeHandle: rep.Volume.VolumeId,  // CSI driver 返回的唯一 ID
                    VolumeAttributes: rep.Volume.VolumeContext,
                },
            },
            ClaimRef: ...,  // 指向 PVC
            StorageClassName: storageClass.Name,
        },
    }

    // 写入 PV 对象到 apiserver
    p.client.CoreV1().PersistentVolumes().Create(ctx, pv, ...)
    return pv, controller.ProvisioningFinished, nil
}
```

---

## CSI driver：CreateVolume

以 hostpath driver 为例（`github.com/kubernetes-csi/csi-driver-host-path`）：

```go
func (hp *hostPath) CreateVolume(ctx, req *csi.CreateVolumeRequest) (*csi.CreateVolumeResponse, error) {
    // ← dlv 断点（CSI driver 进程，port 2353）

    volumeID := uuid.New().String()
    volumePath := filepath.Join(hp.config.StateDir, volumeID)

    // 在宿主机创建目录
    os.MkdirAll(volumePath, 0750)

    // 记录 volume 元数据（JSON 文件）
    hostPathVolume := hostPathVolume{
        VolID:   volumeID,
        VolName: req.GetName(),
        VolSize: capacity,
        VolPath: volumePath,
    }
    hp.updateVolume(volumeID, hostPathVolume)

    return &csi.CreateVolumeResponse{
        Volume: &csi.Volume{
            VolumeId:      volumeID,
            CapacityBytes: capacity,
        },
    }, nil
}
```

---

## bindVolumeToClaim：完成绑定

```go
func (ctrl *PersistentVolumeController) bindVolumeToClaim(ctx, volume *v1.PersistentVolume, claim *v1.PersistentVolumeClaim) error {
    // ← dlv 断点

    // 更新 PV：设置 ClaimRef 指向 PVC
    volumeCopy := volume.DeepCopy()
    volumeCopy.Spec.ClaimRef = &v1.ObjectReference{
        Namespace: claim.Namespace,
        Name:      claim.Name,
        UID:       claim.UID,
    }
    volumeCopy.Status.Phase = v1.VolumeBound

    // 更新 PVC：设置 VolumeName + 状态
    claimCopy := claim.DeepCopy()
    claimCopy.Spec.VolumeName = volume.Name
    claimCopy.Status.Phase = v1.ClaimBound
    claimCopy.Status.AccessModes = volume.Spec.AccessModes
    claimCopy.Status.Capacity = volume.Spec.Capacity

    ctrl.kubeClient.CoreV1().PersistentVolumes().Update(ctx, volumeCopy, ...)
    ctrl.kubeClient.CoreV1().PersistentVolumeClaims(claim.Namespace).UpdateStatus(ctx, claimCopy, ...)
}
```

绑定完成后，scheduler 的 `VolumeBinding` plugin 检测到 PVC.Status.Phase = Bound，允许 Pod 进入调度流程。

---

## WaitForFirstConsumer（延迟绑定）

当 `StorageClass.VolumeBindingMode = WaitForFirstConsumer` 时，流程不同：

```
PVC 创建 → Pending（不立即触发 external-provisioner）
    ↓
Pod 创建，引用该 PVC
    ↓
scheduler.VolumeBinding plugin（pkg/scheduler/framework/plugins/volumebinding/）
    → 把节点拓扑信息注入 PVC annotation
    → 通知 external-provisioner 可以配置了
    ↓
external-provisioner 收到拓扑信息后才调用 CSI CreateVolume
    （确保卷在 Pod 所在节点的可用区创建）
```

---

## StorageClass 关键字段

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: fast-ssd
provisioner: pd.csi.storage.gke.io      # CSI driver 名字
volumeBindingMode: WaitForFirstConsumer  # 或 Immediate
reclaimPolicy: Delete                    # PVC 删除后 PV 也删除；Retain 则保留
allowVolumeExpansion: true               # 允许扩容
parameters:
  type: pd-ssd                           # 透传给 CSI driver 的参数
```

---

## Volume 生命周期状态机

```
PVC:  Pending → Bound → (Released → Available → Bound 循环，仅 Retain 策略)
PV:   Available → Bound → Released → (Reclaimed / Deleted)

Reclaim Policy:
  Delete:  PVC 删除 → PV 删除 → CSI DeleteVolume 调用 → 物理存储释放
  Retain:  PVC 删除 → PV 变 Released → 需要手动处理（清空数据后手动设为 Available）
  Recycle: 已废弃
```

---

## dlv 断点

```bash
# controller-manager（port 2346）
b k8s.io/kubernetes/pkg/controller/volume/persistentvolume.(*PersistentVolumeController).syncUnboundClaim
b k8s.io/kubernetes/pkg/controller/volume/persistentvolume.(*PersistentVolumeController).bindVolumeToClaim
b k8s.io/kubernetes/pkg/controller/volume/persistentvolume.(*PersistentVolumeController).provisionClaim

# CSI hostpath driver（port 2353）
b github.com/kubernetes-csi/csi-driver-host-path/pkg/hostpath.(*hostPath).CreateVolume
b github.com/kubernetes-csi/csi-driver-host-path/pkg/hostpath.(*hostPath).DeleteVolume
```

---

## 相关文档

| 文档 | 说明 |
|------|------|
| `08-pv-static.md` | 静态配置路径 + CSI NodeStage/NodePublish |
| `09-csi-objects.md` | CSIDriver/CSINode 注册机制 |
| `01-pod.md` | Volume 挂载在 kubelet syncPod 中的位置 |
