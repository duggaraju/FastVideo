using System.Text.Json;
using Azure.Messaging.ServiceBus;
using k8s;
using k8s.Models;
using Video.Contracts;

namespace Video.Completion;

public sealed class EncodeJobWatcher(
    ServiceBusClient serviceBus,
    IKubernetes kubernetes,
    IConfiguration configuration,
    ILogger<EncodeJobWatcher> logger) : BackgroundService
{
    private readonly HashSet<string> _loggedFailedPods = [];

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        await using var sender = serviceBus.CreateSender(
            configuration["ServiceBus:VideoResultQueue"] ?? "video-results");

        var targetNamespace = configuration["Kubernetes:Namespace"] ?? "video-servicebus";
        var identity = Environment.GetEnvironmentVariable("POD_NAME") ?? Environment.MachineName;
        var pollInterval = TimeSpan.FromSeconds(configuration.GetValue("Completion:PollSeconds", 10));
        var elector = new LeaseLeaderElector(
            kubernetes,
            targetNamespace,
            "video-completion-leader",
            identity,
            logger,
            leaseDuration: TimeSpan.FromSeconds(Math.Max(30, pollInterval.TotalSeconds * 3)),
            retryPeriod: pollInterval);

        await elector.RunAsync(
            async leaderToken =>
            {
                try
                {
                    await LogFailedPodsAsync(leaderToken);
                    await ReportTerminalVideosAsync(sender, leaderToken);
                }
                catch (OperationCanceledException) when (leaderToken.IsCancellationRequested)
                {
                }
                catch (Exception exception)
                {
                    logger.LogError(exception, "Encode job watcher iteration failed");
                }
            },
            stoppingToken);
    }

    private async Task LogFailedPodsAsync(CancellationToken cancellationToken)
    {
        var targetNamespace = configuration["Kubernetes:Namespace"] ?? "video-servicebus";
        var pods = await kubernetes.CoreV1.ListNamespacedPodAsync(
            targetNamespace,
            labelSelector: "app.kubernetes.io/name=video-encoder",
            cancellationToken: cancellationToken);

        foreach (var pod in pods.Items.Where(pod => pod.Status?.Phase == "Failed"))
        {
            var podId = pod.Metadata.Uid ?? pod.Metadata.Name;
            if (!_loggedFailedPods.Add(podId))
                continue;

            string? index = null;
            pod.Metadata.Annotations?.TryGetValue("batch.kubernetes.io/job-completion-index", out index);
            logger.LogWarning(
                "Encode pod {PodName} for index {SegmentIndex} failed: {Reason} {Message}",
                pod.Metadata.Name,
                index ?? "unknown",
                pod.Status.Reason ?? "Unknown",
                pod.Status.Message ?? string.Empty);
        }
    }

    private async Task ReportTerminalVideosAsync(ServiceBusSender sender, CancellationToken cancellationToken)
    {
        var targetNamespace = configuration["Kubernetes:Namespace"] ?? "video-servicebus";
        var encodeJobs = await kubernetes.BatchV1.ListNamespacedJobAsync(
            targetNamespace,
            labelSelector: "app.kubernetes.io/name=video-encoder",
            cancellationToken: cancellationToken);
        var audioJobs = await kubernetes.BatchV1.ListNamespacedJobAsync(
            targetNamespace,
            labelSelector: "app.kubernetes.io/name=video-audio-encoder",
            cancellationToken: cancellationToken);

        await RebalanceEncodingJobsAsync(encodeJobs.Items, targetNamespace, cancellationToken);

        foreach (var job in encodeJobs.Items.Where(job => HasCondition(job, "Complete")))
        {
            var annotations = job.Metadata.Annotations;
            var audioEncodingRequired = annotations is not null &&
                bool.Parse(OptionalAnnotation(annotations, JobNames.AudioEncodingRequiredAnnotation, "false"));
            if (audioEncodingRequired)
            {
                var jobId = RequiredAnnotation(annotations!, JobNames.JobIdAnnotation);
                var audioJob = audioJobs.Items.SingleOrDefault(candidate =>
                    candidate.Metadata.Annotations?.TryGetValue(JobNames.JobIdAnnotation, out var audioJobId) == true &&
                    audioJobId == jobId);
                if (audioJob is null || !HasCondition(audioJob, "Complete"))
                    continue;
            }
            try
            {
                await SubmitStitchJobAsync(job, targetNamespace, cancellationToken);
            }
            catch (InvalidOperationException exception)
            {
                logger.LogWarning(exception, "Cannot submit stitch job for encode job {JobName}", job.Metadata.Name);
            }
        }

        foreach (var job in encodeJobs.Items.Where(job => HasCondition(job, "Failed")))
        {
            if (job.Metadata.Annotations is null || !job.Metadata.Annotations.TryGetValue(JobNames.JobIdAnnotation, out var jobId))
            {
                logger.LogWarning("Cannot report failed encode job {JobName}: job ID annotation is missing", job.Metadata.Name);
                continue;
            }
            if (audioJobs.Items.Any(audioJob =>
                HasCondition(audioJob, "Failed") &&
                audioJob.Metadata.Annotations?.TryGetValue(JobNames.JobIdAnnotation, out var audioJobId) == true &&
                audioJobId == jobId))
            {
                continue;
            }
            var failedCondition = job.Status?.Conditions?.LastOrDefault(condition => condition.Type == "Failed" && condition.Status == "True");
            await ReportResultAsync(
                sender,
                job,
                targetNamespace,
                jobId,
                succeeded: false,
                terminalStage: "encode",
                job.Status?.FailedIndexes,
                failedCondition?.Message ?? failedCondition?.Reason,
                cancellationToken);
        }

        foreach (var audioJob in audioJobs.Items.Where(job => HasCondition(job, "Failed")))
        {
            if (audioJob.Metadata.Annotations is null ||
                !audioJob.Metadata.Annotations.TryGetValue(JobNames.JobIdAnnotation, out var jobId))
            {
                logger.LogWarning("Cannot report failed audio encode job {JobName}: job ID annotation is missing", audioJob.Metadata.Name);
                continue;
            }
            var failedCondition = audioJob.Status?.Conditions?.LastOrDefault(condition => condition.Type == "Failed" && condition.Status == "True");
            await ReportResultAsync(
                sender,
                audioJob,
                targetNamespace,
                jobId,
                succeeded: false,
                terminalStage: "audio-encode",
                failedIndexes: null,
                failedCondition?.Message ?? failedCondition?.Reason,
                cancellationToken);
        }

        var stitchJobs = await kubernetes.BatchV1.ListNamespacedJobAsync(
            targetNamespace,
            labelSelector: "app.kubernetes.io/name=video-stitcher",
            cancellationToken: cancellationToken);

        foreach (var stitchJob in stitchJobs.Items)
        {
            var succeeded = HasCondition(stitchJob, "Complete");
            var failed = HasCondition(stitchJob, "Failed");
            if (!succeeded && !failed)
                continue;
            if (stitchJob.Metadata.Annotations is null || !stitchJob.Metadata.Annotations.TryGetValue(JobNames.JobIdAnnotation, out var jobId))
                continue;

            var failedCondition = stitchJob.Status?.Conditions?.LastOrDefault(condition => condition.Type == "Failed" && condition.Status == "True");
            await ReportResultAsync(
                sender,
                stitchJob,
                targetNamespace,
                jobId,
                succeeded,
                terminalStage: "stitch",
                failedIndexes: null,
                failedCondition?.Message ?? failedCondition?.Reason,
                cancellationToken);

            if (succeeded)
                await DeleteProducerJobsAsync(jobId, targetNamespace, cancellationToken);
        }
    }

    private async Task RebalanceEncodingJobsAsync(
        IEnumerable<V1Job> jobs,
        string targetNamespace,
        CancellationToken cancellationToken)
    {
        var maxParallelism = configuration.GetValue("Encoding:MaxParallelism", 16);
        if (maxParallelism < 1)
            throw new InvalidOperationException("Encoding:MaxParallelism must be greater than zero");

        var activeJobs = jobs
            .Where(job => !HasCondition(job, "Complete") && !HasCondition(job, "Failed"))
            .ToList();
        var allocations = EncodingJobParallelismAllocator.Allocate(
            activeJobs.Select(job => new EncodingJobDemand(
                job.Metadata.Name,
                Math.Max(0, (job.Spec.Completions ?? 0) - (job.Status?.Succeeded ?? 0)))),
            maxParallelism);

        foreach (var job in activeJobs)
        {
            if (!allocations.TryGetValue(job.Metadata.Name, out var parallelism) ||
                job.Spec.Parallelism == parallelism)
            {
                continue;
            }

            var patchJson = JsonSerializer.Serialize(new { spec = new { parallelism } });
            await kubernetes.BatchV1.PatchNamespacedJobAsync(
                new V1Patch(patchJson, V1Patch.PatchType.MergePatch),
                job.Metadata.Name,
                targetNamespace,
                cancellationToken: cancellationToken);
            logger.LogInformation(
                "Adjusted encode job {JobName} parallelism from {PreviousParallelism} to {Parallelism}; active jobs={ActiveJobCount}, global limit={MaxParallelism}",
                job.Metadata.Name,
                job.Spec.Parallelism,
                parallelism,
                activeJobs.Count,
                maxParallelism);
        }
    }

    private async Task SubmitStitchJobAsync(V1Job encodeJob, string targetNamespace, CancellationToken cancellationToken)
    {
        var annotations = encodeJob.Metadata.Annotations
            ?? throw new InvalidOperationException($"Encode job {encodeJob.Metadata.Name} has no annotations");
        var jobId = RequiredAnnotation(annotations, JobNames.JobIdAnnotation);
        var stitchJobName = JobNames.For("stitch", jobId);
        var encodeNodeSelector = encodeJob.Spec?.Template?.Spec?.NodeSelector;
        var capacityClass = CapacityClasses.Normalize(
            annotations.TryGetValue(CapacityClasses.AnnotationName, out var annotatedCapacityClass)
                ? annotatedCapacityClass
                : null);
        var mediaRuntime = JobTemplateFiles.NormalizeMediaRuntime(OptionalAnnotation(
            annotations,
            JobNames.MediaRuntimeAnnotation,
            configuration["Encoding:MediaRuntimeDefault"] ?? "dotnet"));
        var architecture = encodeNodeSelector?.TryGetValue("kubernetes.io/arch", out var architectureValue) == true
            ? architectureValue
            : string.Empty;
        try
        {
            await kubernetes.BatchV1.ReadNamespacedJobAsync(stitchJobName, targetNamespace, cancellationToken: cancellationToken);
            return;
        }
        catch (Exception exception) when (IsNotFound(exception))
        {
        }

        var stitchJob = await LoadJobTemplateAsync("stitch", mediaRuntime, capacityClass, cancellationToken);
        stitchJob.Metadata ??= new V1ObjectMeta();
        stitchJob.Metadata.Name = stitchJobName;
        var labels = EnsureLabels(stitchJob.Metadata);
        labels["app.kubernetes.io/name"] = "video-stitcher";
        labels["video/job-id"] = JobNames.LabelValue(jobId);
        var jobAnnotations = EnsureAnnotations(stitchJob.Metadata);
        jobAnnotations[JobNames.JobIdAnnotation] = jobId;

        var spec = RequiredSpec(stitchJob);
        spec.ActiveDeadlineSeconds = configuration.GetValue("Encoding:StitchJobActiveDeadlineSeconds", 21600);

        var podLabels = EnsureLabels(spec.Template.Metadata ??= new V1ObjectMeta());
        podLabels["app.kubernetes.io/name"] = "video-stitcher";
        podLabels["video/job-id"] = JobNames.LabelValue(jobId);

        var podSpec = RequiredPodSpec(spec.Template, stitchJobName);
        if (!string.IsNullOrEmpty(architecture))
        {
            podSpec.NodeSelector ??= new Dictionary<string, string>(StringComparer.Ordinal);
            podSpec.NodeSelector["kubernetes.io/arch"] = architecture;
        }

        var container = RequiredContainer(podSpec, "stitcher", stitchJobName);
        SetEnvValue(container, "JOB_ID", jobId);
        SetEnvValue(container, "SEGMENT_COUNT", (encodeJob.Spec?.Completions
            ?? throw new InvalidOperationException($"Encode job {encodeJob.Metadata.Name} has no completion count")).ToString());
        SetEnvValue(container, "AUDIO_BLOB_NAME", RequiredAnnotation(annotations, JobNames.AudioBlobNameAnnotation));
        SetEnvValue(container, "OUTPUT_PATH", RequiredAnnotation(annotations, JobNames.OutputPathAnnotation));
        SetEnvValue(container, "OUTPUT_TYPE", OptionalAnnotation(annotations, JobNames.OutputTypeAnnotation, VideoOutputTypes.Mp4));
        SetEnvValue(container, "CALCULATE_VMAF", OptionalAnnotation(annotations, JobNames.CalculateVmafAnnotation, "false"));
        SetEnvValue(container, "OUTPUT_STORAGE_ACCOUNT_NAME", RequiredConfig("Storage:OutputAccountName"));
        SetEnvValue(container, "OUTPUT_STORAGE_CONTAINER", RequiredConfig("Storage:OutputContainer"));
        SetEnvValue(container, "OUTPUT_MOUNT_PATH", configuration["Storage:OutputMountPath"] ?? "/mnt/output");

        await kubernetes.BatchV1.CreateNamespacedJobAsync(stitchJob, targetNamespace, cancellationToken: cancellationToken);
        logger.LogInformation("Submitted stitch job for {JobId}", jobId);
    }

    private static V1JobSpec RequiredSpec(V1Job job) =>
        job.Spec ?? throw new InvalidOperationException($"Job template '{job.Metadata?.Name ?? "<unnamed>"}' is missing spec");

    private static V1PodSpec RequiredPodSpec(V1PodTemplateSpec template, string jobName) =>
        template.Spec ?? throw new InvalidOperationException($"Job template '{jobName}' is missing pod spec");

    private static V1Container RequiredContainer(V1PodSpec podSpec, string name, string jobName) =>
        podSpec.Containers.SingleOrDefault(container => string.Equals(container.Name, name, StringComparison.Ordinal))
        ?? throw new InvalidOperationException($"Job template '{jobName}' is missing container '{name}'");

    private static IDictionary<string, string> EnsureLabels(V1ObjectMeta metadata)
    {
        metadata.Labels ??= new Dictionary<string, string>(StringComparer.Ordinal);
        return metadata.Labels;
    }

    private static IDictionary<string, string> EnsureAnnotations(V1ObjectMeta metadata)
    {
        metadata.Annotations ??= new Dictionary<string, string>(StringComparer.Ordinal);
        return metadata.Annotations;
    }

    private static void SetEnvValue(V1Container container, string name, string value)
    {
        var env = container.Env ?? throw new InvalidOperationException($"Container '{container.Name}' is missing env vars");
        var entry = env.SingleOrDefault(candidate => string.Equals(candidate.Name, name, StringComparison.Ordinal))
            ?? throw new InvalidOperationException($"Container '{container.Name}' is missing env var '{name}'");
        entry.Value = value;
        entry.ValueFrom = null;
    }

    private static async Task<V1Job> LoadJobTemplateAsync(string role, string mediaRuntime, string? capacityClass, CancellationToken cancellationToken)
    {
        var path = JobTemplateFiles.PathFor(role, mediaRuntime, capacityClass);
        if (!File.Exists(path))
            throw new InvalidOperationException($"Job template '{path}' does not exist");

        var yaml = await File.ReadAllTextAsync(path, cancellationToken);
        return KubernetesYaml.Deserialize<V1Job>(yaml, false)
            ?? throw new InvalidOperationException($"Job template '{path}' is empty");
    }

    private async Task ReportResultAsync(
        ServiceBusSender sender,
        V1Job job,
        string targetNamespace,
        string jobId,
        bool succeeded,
        string terminalStage,
        string? failedIndexes,
        string? failureReason,
        CancellationToken cancellationToken)
    {
        if (job.Metadata.Annotations?.ContainsKey(JobNames.ResultReportedAnnotation) == true)
            return;

        var result = new VideoProcessingResult(
            jobId,
            succeeded,
            terminalStage,
            failedIndexes,
            failureReason,
            DateTimeOffset.UtcNow);
        var message = new ServiceBusMessage(BinaryData.FromObjectAsJson(result))
        {
            MessageId = $"{jobId}:video-result",
            CorrelationId = jobId,
            Subject = nameof(VideoProcessingResult)
        };
        await sender.SendMessageAsync(message, cancellationToken);
        var patchJson = JsonSerializer.Serialize(new
        {
            metadata = new
            {
                annotations = new Dictionary<string, string>
                {
                    [JobNames.ResultReportedAnnotation] = "true"
                }
            }
        });
        await kubernetes.BatchV1.PatchNamespacedJobAsync(
            new V1Patch(patchJson, V1Patch.PatchType.MergePatch),
            job.Metadata.Name,
            targetNamespace,
            cancellationToken: cancellationToken);
        logger.LogInformation(
            "Reported video result for {JobId}: succeeded={Succeeded}, terminal stage={TerminalStage}",
            jobId,
            succeeded,
            terminalStage);
    }

    private async Task DeleteProducerJobsAsync(string jobId, string targetNamespace, CancellationToken cancellationToken)
    {
        foreach (var jobName in new[] { JobNames.For("encode", jobId), JobNames.For("audio", jobId) })
        {
            try
            {
                await kubernetes.BatchV1.DeleteNamespacedJobAsync(
                    jobName,
                    targetNamespace,
                    propagationPolicy: "Background",
                    cancellationToken: cancellationToken);
                logger.LogInformation("Deleted producer job {JobName} after stitch completed", jobName);
            }
            catch (Exception exception) when (IsNotFound(exception))
            {
            }
        }
    }

    private static bool HasCondition(V1Job job, string type) =>
        job.Status?.Conditions?.Any(condition => condition.Type == type && condition.Status == "True") == true;

    private static string RequiredAnnotation(IDictionary<string, string> annotations, string name) =>
        annotations.TryGetValue(name, out var value) && !string.IsNullOrWhiteSpace(value)
            ? value
            : throw new InvalidOperationException($"Required encode job annotation '{name}' is missing");

    private static string OptionalAnnotation(IDictionary<string, string> annotations, string name, string defaultValue) =>
        annotations.TryGetValue(name, out var value) && !string.IsNullOrWhiteSpace(value)
            ? value
            : defaultValue;


    private string RequiredConfig(string key) =>
        configuration[key] ?? throw new InvalidOperationException($"{key} is required");

    private static bool IsNotFound(Exception exception) =>
        exception.ToString().Contains("404", StringComparison.Ordinal) ||
        exception.ToString().Contains("NotFound", StringComparison.OrdinalIgnoreCase);
}
