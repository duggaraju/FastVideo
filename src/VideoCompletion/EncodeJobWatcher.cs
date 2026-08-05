using Azure;
using Azure.Data.Tables;
using Azure.Messaging.ServiceBus;
using k8s;
using k8s.Models;
using SpotVideo.Contracts;

namespace SpotVideo.Completion;

public sealed class EncodeJobWatcher(
    ServiceBusClient serviceBus,
    TableClient state,
    IKubernetes kubernetes,
    IConfiguration configuration,
    ILogger<EncodeJobWatcher> logger) : BackgroundService
{
    private const string JobIdAnnotation = "spotvideo/job-id";
    private const string ResultRowKey = "video-result";
    private readonly HashSet<string> _loggedFailedPods = [];

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        await state.CreateIfNotExistsAsync(stoppingToken);
        await using var sender = serviceBus.CreateSender(
            configuration["ServiceBus:VideoResultQueue"] ?? "video-results");

        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(10));
        do
        {
            try
            {
                await LogFailedPodsAsync(stoppingToken);
                await ReportTerminalVideosAsync(sender, stoppingToken);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                break;
            }
            catch (Exception exception)
            {
                logger.LogError(exception, "Encode job watcher iteration failed");
            }
        }
        while (await timer.WaitForNextTickAsync(stoppingToken));
    }

    private async Task LogFailedPodsAsync(CancellationToken cancellationToken)
    {
        var targetNamespace = configuration["Kubernetes:Namespace"] ?? "spotvideo";
        var pods = await kubernetes.CoreV1.ListNamespacedPodAsync(
            targetNamespace,
            labelSelector: "app.kubernetes.io/name=spotvideo-encoder",
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
        var targetNamespace = configuration["Kubernetes:Namespace"] ?? "spotvideo";
        var encodeJobs = await kubernetes.BatchV1.ListNamespacedJobAsync(
            targetNamespace,
            labelSelector: "app.kubernetes.io/name=spotvideo-encoder",
            cancellationToken: cancellationToken);

        foreach (var job in encodeJobs.Items.Where(job => HasCondition(job, "Failed")))
        {
            if (job.Metadata.Annotations is null || !job.Metadata.Annotations.TryGetValue(JobIdAnnotation, out var jobId))
            {
                logger.LogWarning("Cannot report failed encode job {JobName}: job ID annotation is missing", job.Metadata.Name);
                continue;
            }
            var failedCondition = job.Status?.Conditions?.LastOrDefault(condition => condition.Type == "Failed" && condition.Status == "True");
            await ReportResultAsync(
                sender,
                jobId,
                succeeded: false,
                terminalStage: "encode",
                job.Status?.FailedIndexes,
                failedCondition?.Message ?? failedCondition?.Reason,
                cancellationToken);
        }

        var stitchJobs = await kubernetes.BatchV1.ListNamespacedJobAsync(
            targetNamespace,
            labelSelector: "app.kubernetes.io/name=spotvideo-stitcher",
            cancellationToken: cancellationToken);

        foreach (var stitchJob in stitchJobs.Items)
        {
            var succeeded = HasCondition(stitchJob, "Complete");
            var failed = HasCondition(stitchJob, "Failed");
            if (!succeeded && !failed)
                continue;
            if (stitchJob.Metadata.Annotations is null || !stitchJob.Metadata.Annotations.TryGetValue(JobIdAnnotation, out var jobId))
                continue;

            var failedCondition = stitchJob.Status?.Conditions?.LastOrDefault(condition => condition.Type == "Failed" && condition.Status == "True");
            await ReportResultAsync(
                sender,
                jobId,
                succeeded,
                terminalStage: "stitch",
                failedIndexes: null,
                failedCondition?.Message ?? failedCondition?.Reason,
                cancellationToken);

            if (succeeded)
                await DeleteEncodeJobAsync(jobId, targetNamespace, cancellationToken);
        }
    }

    private async Task ReportResultAsync(
        ServiceBusSender sender,
        string jobId,
        bool succeeded,
        string terminalStage,
        string? failedIndexes,
        string? failureReason,
        CancellationToken cancellationToken)
    {
        if (await ResultWasReportedAsync(jobId, cancellationToken))
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
        await state.AddEntityAsync(new TableEntity(jobId, ResultRowKey)
        {
            ["Succeeded"] = succeeded,
            ["TerminalStage"] = terminalStage,
            ["FailedIndexes"] = failedIndexes ?? string.Empty,
            ["FailureReason"] = failureReason ?? string.Empty,
            ["ReportedAt"] = result.CompletedAt
        }, cancellationToken);
        logger.LogInformation(
            "Reported video result for {JobId}: succeeded={Succeeded}, terminal stage={TerminalStage}",
            jobId,
            succeeded,
            terminalStage);
    }

    private async Task DeleteEncodeJobAsync(string jobId, string targetNamespace, CancellationToken cancellationToken)
    {
        var encodeJobName = JobNames.For("encode", jobId);
        try
        {
            await kubernetes.BatchV1.DeleteNamespacedJobAsync(
                encodeJobName,
                targetNamespace,
                propagationPolicy: "Background",
                cancellationToken: cancellationToken);
            logger.LogInformation("Deleted encode job {EncodeJobName} after stitch completed", encodeJobName);
        }
        catch (Exception exception) when (IsNotFound(exception))
        {
        }
    }

    private async Task<bool> ResultWasReportedAsync(string jobId, CancellationToken cancellationToken)
    {
        var response = await state.GetEntityIfExistsAsync<TableEntity>(jobId, ResultRowKey, cancellationToken: cancellationToken);
        return response.HasValue;
    }

    private static bool HasCondition(V1Job job, string type) =>
        job.Status?.Conditions?.Any(condition => condition.Type == type && condition.Status == "True") == true;

    private static bool IsNotFound(Exception exception) =>
        exception.ToString().Contains("404", StringComparison.Ordinal) ||
        exception.ToString().Contains("NotFound", StringComparison.OrdinalIgnoreCase);
}
