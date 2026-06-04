# PV 静态配置 + VolumeAttachment（CSI Attach）链路

本文覆盖两个场景：
1. **静态配置**：管理员预先创建 PV，PVC 直接绑定已有 PV
2. **VolumeAttachment**：CSI driver 的 ControllerPublishVolume（将卷挂载到节点的 attach 阶段）

**动态配置路径**：见 `07-pvc-dynamic.md`
**kubelet 侧 NodeStage/NodePublish**：见 `01-pod.md` ③ Volume 挂载

---

## 静态配置接力图

```
管理员 kubectl apply -f pv.yaml
    ↓
apiserver.Store.Create()   写入 PV（Status.Phase = Available）
    ↓
kubectl apply -f pvc.yaml（或 Pod volumeClaimTemplates）
    ↓
apiserver 写入 PVC（Status.Phase = Pending）
    ↓ watch 事件
PersistentVolumeController.syncUnboundClaim()
    → findBestMatchForClaim()    匹配 capacity / accessModes / storageClassName
    → bind(volume, claim)        双向绑定
    ↓
PVC.Status.Phase = Bound
PV.Status.Phase  = Bound
```

---

## findBestMatchForClaim：PV 选择算法

`pkg/controller/volume/persistentvolume/pv_controller.go`

```go
func (ctrl *PersistentVolumeController) syncUnboundClaim(ctx, claim) error {
    volume, err := ctrl.volumes.findBestMatchForClaim(claim, false)
    // ← dlv 断点（静态配置路径）
}
```

`pkg/controller/volume/persistentvolume/volume_index.go`

```go
func (pvIndex *persistentVolumeOrderedIndex) findBestMatchForClaim(
    claim *v1.PersistentVolumeClaim, delayBinding bool) (*v1.PersistentVolume, error) {

    // 筛选条件（按顺序，全部满足才考虑）：
    // 1. PV.Status.Phase = Available
    // 2. PV.Spec.AccessModes 包含 claim.Spec.AccessModes 中的所有模式
    // 3. PV.Spec.Capacity >= claim.Spec.Resources.Requests.storage
    // 4. PV.Spec.StorageClassName == claim.Spec.StorageClassName
    // 5. PV 没有 ClaimRef（未被绑定）
    // 6. VolumeMode 匹配（Block or Filesystem）
    // 7. NodeAffinity 兼容（如果 PV 有 nodeAffinity）

    // 选择策略：选容量最小但满足需求的 PV（Best Fit）
    // 避免用大 PV 满足小 PVC，浪费存储
    var bestMatch *v1.PersistentVolume
    for _, pv := range pvIndex.store.List() {
        if pvSatisfiesClaim(pv, claim) {
            if bestMatch == nil || pv.Spec.Capacity.Storage().Cmp(*bestMatch.Spec.Capacity.Storage()) < 0 {
                bestMatch = pv
            }
        }
    }
    return bestMatch, nil
}
```

---

## VolumeAttachment：CSI Attach 流程

某些 CSI driver 需要在节点上使用卷之前先执行 **Attach**（例如云盘挂载到 VM）。这通过 `VolumeAttachment` 对象协调。

### 接力图

```
scheduler 选定节点后，kubelet.volumeManager 发现卷需要 Attach
    ↓
AttachDetachController.syncAttachVolume()
    → 创建 VolumeAttachment 对象
    ↓
CSI external-attacher（sidecar）watch VolumeAttachment
    → 调用 CSI driver gRPC: ControllerPublishVolume()
    ↓
CSI driver 执行 attach（例如：调用云 API 将磁盘挂载到 VM）
    ↓
VolumeAttachment.Status.Attached = true
    ↓
kubelet 检测到 Attached，继续执行 NodeStageVolume / NodePublishVolume
```

### AttachDetachController

`pkg/controller/volume/attachdetach/attach_detach_controller.go`

```go
func (adc *attachDetachController) syncAttachVolume(ctx) error {
    // 遍历所有需要 attach 的 (volume, node) 对
    for _, volumeToAttach := range adc.desiredStateOfWorld.GetVolumesToAttach() {
        if !adc.actualStateOfWorld.VolumeNodeExists(volumeToAttach.VolumeName, volumeToAttach.NodeName) {
            // 创建 VolumeAttachment 对象
            va := &storagev1.VolumeAttachment{
                ObjectMeta: metav1.ObjectMeta{
                    Name: generateAttachmentName(volumeToAttach.VolumeName, volumeToAttach.NodeName),
                },
                Spec: storagev1.VolumeAttachmentSpec{
                    Attacher: csiDriverName,
                    Source:   storagev1.VolumeAttachmentSource{PersistentVolumeName: &pvName},
                    NodeName: volumeToAttach.NodeName,
                },
            }
            adc.kubeClient.StorageV1().VolumeAttachments().Create(ctx, va, ...)
        }
    }
}
```

### CSI external-attacher

`github.com/kubernetes-csi/external-attacher/`

```go
func (h *handler) ReconcileVA(ctx, va *storagev1.VolumeAttachment) error {
    if !va.Status.Attached {
        // 调用 CSI ControllerPublishVolume
        publishContext, err := h.csiClient.ControllerPublishVolume(ctx,
            &csi.ControllerPublishVolumeRequest{
                VolumeId: pvSource.VolumeHandle,
                NodeId:   va.Spec.NodeName,
                VolumeCapability: ...,
                Readonly: false,
            })

        // 更新 VolumeAttachment 状态
        va.Status.Attached = true
        va.Status.AttachmentMetadata = publishContext
        h.client.StorageV1().VolumeAttachments().UpdateStatus(ctx, va, ...)
    }
}
```

### kubelet NodeStageVolume / NodePublishVolume

attach 完成后，kubelet 的 volumeManager 执行两步挂载：

```go
// pkg/kubelet/volumemanager/reconciler/reconciler.go

// NodeStageVolume：格式化磁盘，全局挂载到 staging 目录（一个节点只挂一次）
operationExecutor.MountVolume(waitForAttachTimeout, volumeToMount, ...)
    → csiPlugin.SetUpAt(dir, mounterArgs)
        → nodeStager.NodeStageVolume(ctx, &csi.NodeStageVolumeRequest{
            VolumeId:          pvSource.VolumeHandle,
            StagingTargetPath: "/var/lib/kubelet/plugins/kubernetes.io/csi/pv/{pvName}/globalmount",
            VolumeCapability:  ...,
            Secrets:           nodeStageSecrets,
            PublishContext:    va.Status.AttachmentMetadata,  // attach 阶段的上下文
          })
        // CSI driver 在此格式化磁盘（如果需要）并 mount 到 stagingPath

// NodePublishVolume：从 staging bind mount 到 Pod 目录（每个 Pod 各一次）
    → nodeMounter.NodePublishVolume(ctx, &csi.NodePublishVolumeRequest{
        VolumeId:         pvSource.VolumeHandle,
        StagingTargetPath: stagingPath,
        TargetPath:       "/var/lib/kubelet/pods/{podUID}/volumes/kubernetes.io~csi/{pvName}/mount",
        VolumeCapability: ...,
      })
      // syscall: mount(stagingPath, targetPath, MS_BIND)
```

---

## 是否需要 Attach：CSIDriver.Spec.AttachRequired

```yaml
apiVersion: storage.k8s.io/v1
kind: CSIDriver
metadata:
  name: hostpath.csi.k8s.io
spec:
  attachRequired: false    # hostpath 不需要 attach（本地存储）
  podInfoOnMount: true
  volumeLifecycleModes:
    - Persistent
```

`attachRequired: false` 时，AttachDetachController 跳过创建 VolumeAttachment，kubelet 直接调用 NodeStageVolume。

---

## 静态 vs 动态配置对比

| 维度 | 静态配置 | 动态配置 |
|------|---------|---------|
| PV 创建者 | 管理员手动创建 | external-provisioner 自动创建 |
| PV 来源 | 预先存在 | CSI CreateVolume 创建 |
| StorageClass | 可有可无 | 必须有，指定 provisioner |
| 绑定时机 | findBestMatchForClaim 匹配 | CSI 返回 VolumeId 后 |
| 删除行为 | reclaimPolicy 决定 | 通常 Delete（自动删除卷） |

---

## dlv 断点

```bash
# controller-manager：PV 匹配与绑定
b k8s.io/kubernetes/pkg/controller/volume/persistentvolume.(*PersistentVolumeController).syncUnboundClaim
b k8s.io/kubernetes/pkg/controller/volume/persistentvolume.(*PersistentVolumeController).bindVolumeToClaim

# controller-manager：Attach/Detach
b k8s.io/kubernetes/pkg/controller/volume/attachdetach.(*attachDetachController).syncAttachVolume

# kubelet：NodeStage/NodePublish（port 2348）
b k8s.io/kubernetes/pkg/kubelet/volumemanager/reconciler.(*reconciler).reconcile
```

---

## 相关文档

| 文档 | 说明 |
|------|------|
| `07-pvc-dynamic.md` | PVC 动态配置路径 |
| `09-csi-objects.md` | CSIDriver/CSINode 注册 |
| `01-pod.md` | kubelet syncPod 中的 Volume 挂载 |
