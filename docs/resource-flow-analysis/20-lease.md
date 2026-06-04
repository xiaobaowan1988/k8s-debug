# Lease 创建链路

Lease 是轻量级的租约对象（仅包含一个 holder 字符串和时间戳），K8s 内部用于两个场景：**Leader Election**（controller-manager/scheduler 的高可用）和 **Node heartbeat**（kubelet 心跳）。

**apiserver → etcd 路径**：见 `00-apiserver-common-flow.md`

---

## 两种使用场景

```
场景一：Leader Election
    多副本 controller-manager / scheduler 竞争 Lease
    → 获得 Lease 的成为 leader，执行调谐逻辑
    → 其他副本作为 follower，持续尝试更新 Lease

场景二：Node Heartbeat（kubelet）
    每个节点的 kubelet 每 10s 更新一次 Lease
    → node-lifecycle-controller 监控 Lease 更新时间
    → 超过 40s 未更新 → 节点 NotReady → Pod 被驱逐
```

---

## Leader Election

`vendor/k8s.io/client-go/tools/leaderelection/leaderelection.go`

### 竞争 Lease

```go
func (le *LeaderElector) Run(ctx) {
    // 1. 尝试获取 leader 身份
    le.acquire(ctx)

    // 2. 成为 leader 后执行业务逻辑
    go le.config.Callbacks.OnStartedLeading(ctx)

    // 3. 持续续租（renew），失去续租能力时退出
    le.renew(ctx)
}

func (le *LeaderElector) tryAcquireOrRenew(ctx) bool {
    // ← dlv 断点

    now := metav1.NewTime(le.clock.Now())

    // 读取当前 Lease
    leaderElectionRecord, _, err := le.config.Lock.Get(ctx)

    if err != nil {
        // Lease 不存在，尝试创建（Create 成功则成为 leader）
        leaderElectionRecord = &rl.LeaderElectionRecord{
            HolderIdentity:       le.config.Identity,  // "pod-name_uuid"
            LeaseDurationSeconds: int(le.config.LeaseDuration / time.Second),
            AcquireTime:          now,
            RenewTime:            now,
        }
        return le.config.Lock.Create(ctx, leaderElectionRecord)
    }

    // Lease 已存在
    if leaderElectionRecord.HolderIdentity == le.config.Identity {
        // 我已经是 leader，续租
        leaderElectionRecord.RenewTime = now
        return le.config.Lock.Update(ctx, leaderElectionRecord)
    }

    // 别人是 leader，检查是否超时
    if now.Time.Before(leaderElectionRecord.RenewTime.Add(le.config.LeaseDuration)) {
        return false  // leader 还活着，我保持 follower
    }

    // leader 超时，尝试抢占（乐观锁：resourceVersion 不匹配则失败）
    leaderElectionRecord.HolderIdentity = le.config.Identity
    leaderElectionRecord.AcquireTime = now
    leaderElectionRecord.RenewTime = now
    leaderElectionRecord.LeaderTransitions++
    return le.config.Lock.Update(ctx, leaderElectionRecord)
    // 使用 resourceVersion 确保只有一个副本能抢占成功
}
```

### Lease 对象

```yaml
apiVersion: coordination.k8s.io/v1
kind: Lease
metadata:
  name: kube-controller-manager
  namespace: kube-system
spec:
  holderIdentity: "kube-controller-manager-pod-abc_uuid"
  leaseDurationSeconds: 15     # leader 有效期
  acquireTime: "2024-01-01T00:00:00Z"
  renewTime: "2024-01-01T00:05:00Z"   # 每 renewDeadline（默认 10s）更新一次
  leaderTransitions: 3
```

默认参数（`pkg/controller/util/leader_election_config.go`）：
- `leaseDuration`：15s（leader 有效期）
- `renewDeadline`：10s（renew 超时时间）
- `retryPeriod`：2s（follower 重试间隔）

---

## Node Heartbeat（kubelet）

`pkg/kubelet/nodestatus.go` + `pkg/kubelet/node_lifecycle_controller.go`

### kubelet 更新 Lease

```go
// pkg/kubelet/kubelet_node_status.go
func (kl *Kubelet) syncNodeStatus(ctx) {
    // 每 nodeStatusUpdateFrequency（默认 10s）调用一次

    // 1. 更新 Node 对象（资源使用量、条件等，较重）
    kl.updateNodeStatus(ctx)

    // 2. 更新 Lease（轻量，只更新时间戳）
    kl.updateNodeLease(ctx)
}

func (kl *Kubelet) updateNodeLease(ctx) {
    lease := &coordinationv1.Lease{
        ObjectMeta: metav1.ObjectMeta{
            Name:      kl.nodeName,
            Namespace: v1.NamespaceNodeLease,  // kube-node-lease namespace
        },
        Spec: coordinationv1.LeaseSpec{
            HolderIdentity:       pointer.String(kl.nodeName),
            LeaseDurationSeconds: pointer.Int32(int32(kl.nodeLeaseController.leaseDuration.Seconds())),
            RenewTime:            &metav1.MicroTime{Time: kl.clock.Now()},
        },
    }
    // 尝试 Update，失败则 Create（节点重启后 Lease 可能已过期被删）
    kl.kubeClient.CoordinationV1().Leases(v1.NamespaceNodeLease).Update(ctx, lease, ...)
}
```

### node-lifecycle-controller 检测节点失联

`pkg/controller/nodelifecycle/node_lifecycle_controller.go`

```go
func (nc *Controller) monitorNodeHealth(ctx) {
    // ← dlv 断点（节点失联时）

    for _, node := range nodes {
        // 读取节点对应的 Lease
        observedLease, _ := nc.leaseLister.Leases(v1.NamespaceNodeLease).Get(node.Name)

        gracePeriod := nc.nodeMonitorGracePeriod  // 默认 40s

        if observedLease != nil {
            // 以 Lease.RenewTime 为准（比 Node.Status 更新更频繁）
            lastObservedTime = observedLease.Spec.RenewTime.Time
        }

        if nc.now().After(lastObservedTime.Add(gracePeriod)) {
            // 节点 40s 未更新 Lease
            // 标记 Node.Status.Conditions[Ready] = Unknown
            node.Status.Conditions = setNodeCondition(node.Status.Conditions,
                v1.NodeCondition{Type: v1.NodeReady, Status: v1.ConditionUnknown, ...})

            // 添加 taint：node.kubernetes.io/not-ready
            // 超过 pod-eviction-timeout（默认 5min）→ 驱逐 Pod
        }
    }
}
```

---

## Lease vs 旧版 Node heartbeat

| 方式 | 对象 | 更新内容 | 大小 |
|------|------|---------|------|
| 旧版（K8s <1.13） | Node.Status | 全量 Status | 大（几KB） |
| 新版（K8s 1.17+ GA） | Lease | 只有 RenewTime | 极小（<1KB） |

Lease 大幅减少 apiserver/etcd 的写入压力，尤其在大规模集群（>5000 节点）。

---

## dlv 断点

```bash
# controller-manager（port 2346）
# Leader election 竞争
b k8s.io/client-go/tools/leaderelection.(*LeaderElector).tryAcquireOrRenew

# 节点失联检测
b k8s.io/kubernetes/pkg/controller/nodelifecycle.(*Controller).monitorNodeHealth

# kubelet（port 2348）
b k8s.io/kubernetes/pkg/kubelet.(*Kubelet).updateNodeLease
```

---

## 相关文档

| 文档 | 说明 |
|------|------|
| `21-auth-resources.md` | 认证机制（节点身份验证） |
| `01-pod.md` | Pod 驱逐：节点失联后的处理 |
