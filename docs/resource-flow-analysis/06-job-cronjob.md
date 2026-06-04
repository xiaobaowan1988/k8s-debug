# Job + CronJob 创建链路

Job 运行一个或多个 Pod 直到完成（成功退出）。CronJob 按 cron 表达式定期创建 Job。两者都是批处理场景的核心资源。

**apiserver → etcd 路径**：见 `00-apiserver-common-flow.md`
**Pod 创建尾部**：见 `01-pod.md`

---

## 接力图

### Job

```
kubectl apply -f job.yaml
    ↓
apiserver.Store.Create()   写入 Job 对象
    ↓ watch 事件
JobController.syncJob()
    ├── 计算需要创建的 Pod 数量（completions - succeeded）
    ├── 按 completionMode 和 parallelism 创建 Pod
    └── 监听 Pod 完成事件 → 更新 Job.Status
    ↓
Scheduler → Kubelet → CRI → kernel（见 01-pod.md）
```

### CronJob

```
CronJobController 定时轮询（每 10s）
    ↓
到达调度时间
    ↓
CronJobController.syncCronJob()
    ├── 检查 concurrencyPolicy（Forbid/Allow/Replace）
    ├── 创建 Job 对象（从 jobTemplate 生成）
    └── 清理超出 successfulJobsHistoryLimit 的旧 Job
    ↓
JobController.syncJob()（接上）
```

---

## JobController

`pkg/controller/job/job_controller.go`

### 启动

```go
func NewController(ctx, podInformer, jobInformer, kubeClient) (*Controller, error) {
    jm := &Controller{
        kubeClient: kubeClient,
        queue:      workqueue.NewRateLimitingQueue(...),
        // 专用于 Job 完成结果统计的队列
        orphanQueue: workqueue.NewRateLimitingQueue(...),
    }

    jobInformer.Informer().AddEventHandler(cache.ResourceEventHandlerFuncs{
        AddFunc:    jm.addJob,
        UpdateFunc: jm.updateJob,
        DeleteFunc: jm.deleteJob,
    })

    // Pod 状态变更触发 Job 重新调谐（Pod 成功/失败时）
    podInformer.Informer().AddEventHandler(cache.ResourceEventHandlerFuncs{
        AddFunc:    jm.addPod,
        UpdateFunc: jm.updatePod,
        DeleteFunc: jm.deletePod,
    })
}
```

### 核心调谐

```go
func (jm *Controller) syncJob(ctx, key string) (forget bool, rErr error) {
    // ← dlv 断点

    namespace, name, _ := cache.SplitMetaNamespaceKey(key)
    job, _ := jm.jobLister.Jobs(namespace).Get(name)

    // 获取当前属于该 Job 的所有 Pod
    pods, _ := jm.getPodsForJob(ctx, job)
    activePods := controller.FilterActivePods(pods)
    succeededPods := getStatus(pods, v1.PodSucceeded)
    failedPods := getStatus(pods, v1.PodFailed)

    // 判断 Job 是否完成
    jobHasNewFailure := failed > job.Status.Failed
    exceedsBackoffLimit := job.Status.Failed+int32(len(failedPods)) >= *job.Spec.BackoffLimit

    if jm.jobFinished(job) {
        return // 已完成，不再操作
    }

    // 计算需要创建/删除多少个 Pod
    active := int32(len(activePods))
    succeeded := int32(len(succeededPods))
    parallelism := *job.Spec.Parallelism

    // 按 completionMode 决策
    if isIndexedJob(job) {
        // Indexed 模式：每个 Pod 有唯一 index（环境变量 JOB_COMPLETION_INDEX）
        jm.syncIndexedJob(ctx, job, activePods, succeededPods)
    } else {
        // NonIndexed 模式（默认）
        activePods, err = jm.manageJob(ctx, job, activePods, succeededPods, failedPods)
    }
}
```

### 创建 Pod（manageJob）

```go
func (jm *Controller) manageJob(ctx, job, activePods, succeededPods, failedPods) ([]*v1.Pod, error) {
    active := int32(len(activePods))
    parallelism := *job.Spec.Parallelism

    // 需要运行的最大并发数
    wantActive := parallelism
    if job.Spec.Completions != nil {
        // 不需要超过 completions - succeeded 数量
        wantActive = min(*job.Spec.Completions-succeeded, parallelism)
    }

    diff := wantActive - active

    if diff > 0 {
        // 创建 diff 个 Pod（使用 slowStartBatch 防止雪崩）
        jm.podControl.CreatePodsWithGenerateName(ctx, job.Namespace,
            &job.Spec.Template, job, metav1.NewControllerRef(job, ...))
    } else if diff < 0 {
        // 删除多余的 Pod（Job 被 scale down 时）
        jm.deleteJobPods(ctx, job, activePods[:int(-diff)], ...)
    }
}
```

### Pod 完成处理

```go
func (jm *Controller) updatePod(logger, old, cur interface{}) {
    curPod := cur.(*v1.Pod)
    if curPod.Status.Phase == v1.PodSucceeded || curPod.Status.Phase == v1.PodFailed {
        // Pod 结束，触发对应 Job 的调谐
        jm.enqueueControllerPodUpdate(curPod, immediate)
    }
}
```

当所有 Pod 的成功数达到 `completions` 时：

```go
// syncJob 中
if succeeded >= *job.Spec.Completions {
    // Job 完成
    jm.recordJobStatusUpdate(ctx, job, v1.JobComplete, "")
    // Job.Status.CompletionTime = now
    // Job.Status.Conditions 添加 Complete=True
}
```

---

## Job 失败与重试

```go
// BackoffLimit：Pod 失败重试次数上限（默认 6）
if exceedsBackoffLimit || pastActiveDeadline {
    // 删除所有 active Pod，标记 Job 为 Failed
    jm.deleteActivePods(ctx, job, activePods)
    jm.recordJobFailed(ctx, job, reason, message)
}
```

失败 Pod 的退避策略（exponential backoff）：
- 第 1 次重启：等 10s
- 第 2 次：20s
- 第 3 次：40s
- 最长 6 分钟

`restartPolicy: OnFailure` vs `Never` 决定容器是在同一 Pod 内重启还是创建新 Pod。

---

## CronJobController

`pkg/controller/cronjob/cronjob_controller.go`

### 调度循环

```go
func (jm *ControllerV2) syncCronJob(ctx, cronJob, jobList) (*batchv1.CronJob, error) {
    // ← dlv 断点

    now := jm.now()

    // 计算上次调度时间到现在需要触发几次
    scheduledTimes, _ := getRecentUnmetScheduleTimes(cronJob, now)

    // 检查 concurrencyPolicy
    if cronJob.Spec.ConcurrencyPolicy == batchv1.ForbidConcurrent && len(cronJob.Status.Active) > 0 {
        // 上一个 Job 还在运行，跳过本次
        return cronJob, nil
    }
    if cronJob.Spec.ConcurrencyPolicy == batchv1.ReplaceConcurrent {
        // 删除旧 Job 再创建新的
        for _, activeJob := range cronJob.Status.Active {
            jm.deleteJob(ctx, activeJob, cronJob)
        }
    }

    // 用 jobTemplate 生成新 Job
    jobReq, _ := getJobFromTemplate(cronJob, scheduledTime)
    // jobReq.Name = cronJob.Name + "-" + timestamp
    job, _ := jm.kubeClient.BatchV1().Jobs(cronJob.Namespace).Create(ctx, jobReq, ...)

    // 更新 CronJob.Status.Active 和 LastScheduleTime
    cronJob.Status.Active = append(cronJob.Status.Active, v1.ObjectReference{...})
    cronJob.Status.LastScheduleTime = &metav1.Time{Time: scheduledTime}
}
```

### 历史清理

```go
func (jm *ControllerV2) cleanupFinishedJobs(ctx, cj, jobs) {
    // 只保留最近 successfulJobsHistoryLimit（默认 3）个成功 Job
    // 只保留最近 failedJobsHistoryLimit（默认 1）个失败 Job
    jm.removeOldestJobs(ctx, cj, successfulJobs, *cj.Spec.SuccessfulJobsHistoryLimit)
    jm.removeOldestJobs(ctx, cj, failedJobs, *cj.Spec.FailedJobsHistoryLimit)
}
```

---

## completionMode: Indexed

Kubernetes v1.24+ 稳定特性，每个 Pod 有唯一序号：

```go
// pkg/controller/job/indexed_job_utils.go
func (jm *Controller) createPodsForJob(ctx, job, missingIndices []int) {
    for _, idx := range missingIndices {
        pod := jm.podControl.CreatePodsWithGenerateName(...)
        // 注入环境变量：JOB_COMPLETION_INDEX = strconv.Itoa(idx)
        // Pod 名：{job-name}-{idx}
    }
}
```

适合 MapReduce、数据库迁移等需要分片的场景。

---

## Pod 完成后的容器资源回收

Job Pod 完成后，kubelet 保留容器日志供查询，但释放容器资源。垃圾回收由 kubelet 的 `containerGC` 负责（`pkg/kubelet/container/container_gc.go`）：
- 已终止超过 `terminated-pod-gc-threshold` 秒的 Pod 容器会被 GC
- Job Pod 默认由 TTL Controller（`pkg/controller/ttlafterfinished/`）在 `ttlSecondsAfterFinished` 后删除整个 Pod 对象

---

## dlv 断点

```bash
# controller-manager（port 2346）
# Job
b k8s.io/kubernetes/pkg/controller/job.(*Controller).syncJob
b k8s.io/kubernetes/pkg/controller/job.(*Controller).manageJob

# CronJob
b k8s.io/kubernetes/pkg/controller/cronjob.(*ControllerV2).syncCronJob
```

---

## 相关文档

| 文档 | 说明 |
|------|------|
| `01-pod.md` | Pod 创建链路 |
| `02-replicaset.md` | 对比：长期运行的副本管理 |
