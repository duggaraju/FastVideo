using System.Text.Json;
using Azure;
using Azure.Data.Tables;
using Azure.Messaging.ServiceBus;
using k8s;
using k8s.Models;
using SpotVideo.Contracts;

namespace SpotVideo.Completion;

public sealed class CompletionWorker(
    ServiceBusClient serviceBus,
    TableClient state,
    IKubernetes kubernetes,
    IConfiguration configuration,
    ILogger<CompletionWorker> logger) : BackgroundService
{
    private ServiceBusProcessor? _processor;

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        await state.CreateIfNotExistsAsync(stoppingToken);
        _processor = serviceBus.CreateProcessor(
            configuration["ServiceBus:CompletionQueue"] ?? "segment-completed",
            new ServiceBusProcessorOptions { AutoCompleteMessages = false, MaxConcurrentCalls = 16 });
        _processor.ProcessMessageAsync += ProcessMessageAsync;
        _processor.ProcessErrorAsync += args =>
        {
            logger.LogError(args.Exception, "Completion processor failed at {Source}", args.ErrorSource);
            return Task.CompletedTask;
        };
        await _processor.StartProcessingAsync(stoppingToken);
        await Task.Delay(Timeout.Infinite, stoppingToken);
    }

    private async Task ProcessMessageAsync(ProcessMessageEventArgs args)
    {
        try
        {
            var completion = args.Message.Body.ToObjectFromJson<SegmentEncoded>()
                ?? throw new InvalidOperationException("Message body is empty");
            Validate(completion);
            await RecordSegmentAsync(completion, args.CancellationToken);
            var completed = await CountSegmentsAsync(completion.JobId, args.CancellationToken);
            if (completed == completion.SegmentCount)
                await SubmitStitchJobAsync(completion, args.CancellationToken);
            await args.CompleteMessageAsync(args.Message, args.CancellationToken);
        }
        catch (JsonException exception)
        {
            await args.DeadLetterMessageAsync(args.Message, "InvalidMessage", exception.Message, args.CancellationToken);
        }
        catch (ArgumentException exception)
        {
            await args.DeadLetterMessageAsync(args.Message, "InvalidMessage", exception.Message, args.CancellationToken);
        }
    }

    private async Task RecordSegmentAsync(SegmentEncoded completion, CancellationToken cancellationToken)
    {
        var entity = new TableEntity(completion.JobId, $"segment-{completion.SegmentIndex:D6}")
        {
            ["SegmentIndex"] = completion.SegmentIndex,
            ["SegmentCount"] = completion.SegmentCount,
            ["OutputContainer"] = completion.OutputContainer,
            ["BlobName"] = completion.BlobName,
            ["Length"] = completion.Length,
            ["Sha256"] = completion.Sha256,
            ["CompletedAt"] = completion.CompletedAt
        };
        try
        {
            await state.AddEntityAsync(entity, cancellationToken);
        }
        catch (RequestFailedException exception) when (exception.Status == 409)
        {
            logger.LogDebug("Ignoring duplicate completion for {JobId}/{Index}", completion.JobId, completion.SegmentIndex);
        }
    }

    private async Task<int> CountSegmentsAsync(string jobId, CancellationToken cancellationToken)
    {
        var count = 0;
        var filter = TableClient.CreateQueryFilter($"PartitionKey eq {jobId} and RowKey ge {"segment-"} and RowKey lt {"segment."}");
        await foreach (var _ in state.QueryAsync<TableEntity>(filter, select: ["RowKey"], cancellationToken: cancellationToken))
            count++;
        return count;
    }

    private async Task SubmitStitchJobAsync(SegmentEncoded completion, CancellationToken cancellationToken)
    {
        var jobName = JobNames.For("stitch", completion.JobId);
        var targetNamespace = configuration["Kubernetes:Namespace"] ?? "spotvideo";
        try
        {
            await kubernetes.BatchV1.ReadNamespacedJobAsync(jobName, targetNamespace, cancellationToken: cancellationToken);
            return;
        }
        catch (Exception exception) when (IsNotFound(exception))
        {
        }

        var labels = new Dictionary<string, string>
        {
            ["app.kubernetes.io/name"] = "spotvideo-stitcher",
            ["spotvideo/job-id"] = JobNames.LabelValue(completion.JobId),
            ["azure.workload.identity/use"] = "true"
        };
        var environment = new List<V1EnvVar>
        {
            Env("JOB_ID", completion.JobId),
            Env("SEGMENT_COUNT", completion.SegmentCount.ToString()),
            Env("OUTPUT_CONTAINER", completion.OutputContainer),
            Env("STORAGE_SERVICE_URI", configuration["Storage:ServiceUri"]!),
            Env("TABLE_SERVICE_URI", configuration["Storage:TableServiceUri"]!),
            Env("STATE_TABLE", configuration["Storage:StateTable"] ?? "encodingstate"),
            Env("SERVICE_BUS_NAMESPACE", configuration["ServiceBus:Namespace"]!),
            Env("STITCHED_QUEUE", configuration["ServiceBus:StitchedQueue"] ?? "video-stitched")
        };
        var pod = new V1PodTemplateSpec
        {
            Metadata = new V1ObjectMeta { Labels = labels },
            Spec = new V1PodSpec
            {
                Containers =
                [
                    new V1Container
                    {
                        Name = "stitcher",
                        Image = configuration["Images:Stitcher"] ?? throw new InvalidOperationException("Images:Stitcher is required"),
                        Env = environment,
                        Resources = new V1ResourceRequirements
                        {
                            Requests = new Dictionary<string, ResourceQuantity> { ["cpu"] = new("1"), ["memory"] = new("2Gi") },
                            Limits = new Dictionary<string, ResourceQuantity> { ["cpu"] = new("2"), ["memory"] = new("4Gi") }
                        }
                    }
                ],
                RestartPolicy = "Never",
                ServiceAccountName = "spotvideo-worker",
                Tolerations = [new V1Toleration { Effect = "NoSchedule", OperatorProperty = "Equal", Key = "kubernetes.azure.com/scalesetpriority", Value = "spot" }],
                NodeSelector = new Dictionary<string, string> { ["kubernetes.azure.com/scalesetpriority"] = "spot" },
                TerminationGracePeriodSeconds = 120
            }
        };
        var job = new V1Job
        {
            Metadata = new V1ObjectMeta { Name = jobName, Labels = labels },
            Spec = new V1JobSpec { Template = pod, BackoffLimit = 6, TtlSecondsAfterFinished = 3600 }
        };
        await kubernetes.BatchV1.CreateNamespacedJobAsync(job, targetNamespace, cancellationToken: cancellationToken);
        logger.LogInformation("Submitted stitch job for {JobId}", completion.JobId);
    }

    private static V1EnvVar Env(string name, string value) => new() { Name = name, Value = value };

    private static bool IsNotFound(Exception exception) =>
        exception.ToString().Contains("404", StringComparison.Ordinal) ||
        exception.ToString().Contains("NotFound", StringComparison.OrdinalIgnoreCase);

    private static void Validate(SegmentEncoded completion)
    {
        if (string.IsNullOrWhiteSpace(completion.JobId))
            throw new ArgumentException("JobId is required");
        if (completion.SegmentCount <= 0 || completion.SegmentIndex < 0 || completion.SegmentIndex >= completion.SegmentCount)
            throw new ArgumentException("Segment index/count is invalid");
        if (string.IsNullOrWhiteSpace(completion.OutputContainer))
            throw new ArgumentException("OutputContainer is required");
        if (string.IsNullOrWhiteSpace(completion.BlobName))
            throw new ArgumentException("BlobName is required");
    }

    public override async Task StopAsync(CancellationToken cancellationToken)
    {
        if (_processor is not null)
            await _processor.StopProcessingAsync(cancellationToken);
        await base.StopAsync(cancellationToken);
    }
}