# K8s 全资源创建链路代码分析计划

基于 `kubectl api-resources -o wide` 列出的所有资源，按照与 StatefulSet 相同的分析方式（代码函数级 + dlv 断点 + strace syscall）逐一记录每种资源的创建全链路。

## 参考文档

- `../kernel-syscall-verification.md` — StatefulSet 全链路内核 syscall 验证（已完成，作为基准）

## 分析框架

每份文档覆盖：
1. **资源定义** — 是什么，解决什么问题
2. **触发路径** — 谁创建它，如何产生
3. **接力图** — 哪些组件参与，顺序如何
4. **关键代码函数** — 精确到源码文件 + 函数名
5. **dlv 断点** — 可直接使用的断点列表
6. **strace 关键 syscall** — 有内核操作时列出
7. **调试方法小结**

## 执行顺序与状态

### 阶段 0：通用基础
| 文档 | 资源 | 状态 |
|------|------|------|
| `00-apiserver-common-flow.md` | apiserver 通用处理路径 | ✅ |

### 阶段 1：核心工作负载
| 文档 | 资源 | 状态 |
|------|------|------|
| `01-pod.md` | Pod | ✅ |
| `02-replicaset.md` | ReplicaSet | ✅ |
| `03-deployment.md` | Deployment | ✅ |
| `04-statefulset.md` | StatefulSet | ✅ 见 `../kernel-syscall-verification.md` |
| `05-daemonset.md` | DaemonSet | ✅ |
| `06-job-cronjob.md` | Job + CronJob | ✅ |

### 阶段 2：存储链路
| 文档 | 资源 | 状态 |
|------|------|------|
| `07-pvc-dynamic.md` | PVC + StorageClass（动态配置） | ✅ |
| `08-pv-static.md` | PV + VolumeAttachment（静态 + CSI attach） | ✅ |
| `09-csi-objects.md` | CSIDriver, CSINode, CSIStorageCapacity | ✅ |

### 阶段 3：网络链路
| 文档 | 资源 | 状态 |
|------|------|------|
| `10-service-endpoints.md` | Service + Endpoints + EndpointSlice | ✅ |
| `11-ingress.md` | Ingress + IngressClass | ✅ |
| `12-networkpolicy.md` | NetworkPolicy | ✅ |

### 阶段 4：弹性与调度
| 文档 | 资源 | 状态 |
|------|------|------|
| `13-hpa.md` | HorizontalPodAutoscaler | ⬜ |
| `14-scheduling.md` | PriorityClass + PodDisruptionBudget + RuntimeClass | ⬜ |

### 阶段 5：配置与认证
| 文档 | 资源 | 状态 |
|------|------|------|
| `15-config-secret.md` | ConfigMap + Secret | ⬜ |
| `16-serviceaccount.md` | ServiceAccount + TokenRequest | ⬜ |
| `17-rbac.md` | Role / RoleBinding / ClusterRole / ClusterRoleBinding | ⬜ |

### 阶段 6：命名空间与配额
| 文档 | 资源 | 状态 |
|------|------|------|
| `18-namespace-quota.md` | Namespace + ResourceQuota + LimitRange | ⬜ |

### 阶段 7：API 扩展机制
| 文档 | 资源 | 状态 |
|------|------|------|
| `19-crd-webhook.md` | CRD + MutatingWebhook + ValidatingWebhook + ValidatingAdmissionPolicy | ⬜ |
| `20-lease.md` | Lease | ⬜ |

### 阶段 8：安全与访问控制
| 文档 | 资源 | 状态 |
|------|------|------|
| `21-auth-resources.md` | CertificateSigningRequest + TokenReview + SubjectAccessReview | ⬜ |

## 版本信息

| 项目 | 版本 |
|------|------|
| Kubernetes | v1.32.0 |
| containerd | v2.0.1 |
| runc | v1.3.4 |
| 分析基准 | StatefulSet 全链路（kernel-syscall-verification.md） |
