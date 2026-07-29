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
            ["WorkingContainer"] = completion.WorkingContainer,
            ["BlobName"] = completion.BlobName,
            ["AudioBlobName"] = completion.AudioBlobName,
            ["OutputVideoUri"] = completion.OutputVideoUri.ToString(),
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
            Env("OUTPUT_CONTAINER", completion.WorkingContainer),
            Env("AUDIO_BLOB_NAME", completion.AudioBlobName),
            Env("OUTPUT_VIDEO_URI", completion.OutputVideoUri.ToString()),
            Env("TABLE_SERVICE_URI", configuration["Storage:TableServiceUri"]!),
            Env("STATE_TABLE", configuration["Storage:StateTable"] ?? "encodingstate"),
            Env("OUTPUT_STORAGE_ACCOUNT_NAME", RequiredConfig("Storage:OutputAccountName")),
            Env("OUTPUT_STORAGE_CONTAINER", RequiredConfig("Storage:OutputContainer")),
            Env("OUTPUT_MOUNT_PATH", configuration["Storage:OutputMountPath"] ?? "/mnt/output"),
            Env("SERVICE_BUS_NAMESPACE", configuration["ServiceBus:Namespace"]!),
            Env("STITCHED_QUEUE", configuration["ServiceBus:StitchedQueue"] ?? "video-stitched")
        };
        var outputVolumeName = "output-storage";
        var outputMountPath = configuration["Storage:OutputMountPath"] ?? "/mnt/output";
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
                        VolumeMounts = [new V1VolumeMount { Name = outputVolumeName, MountPath = outputMountPath }],
                        Resources = new V1ResourceRequirements
                        {
                            Requests = new Dictionary<string, ResourceQuantity> { ["cpu"] = new("1"), ["memory"] = new("2Gi") },
                            Limits = new Dictionary<string, ResourceQuantity> { ["cpu"] = new("2"), ["memory"] = new("4Gi") }
                        }
                    }
                ],
                Volumes =
                [
                    BlobFuseVolume(
                        outputVolumeName,
                        RequiredConfig("Storage:OutputAccountName"),
                        RequiredConfig("Storage:OutputContainer"),
                        RequiredConfig("WorkloadIdentity:ClientId"),
                        readOnly: false)
                ],
                RestartPolicy = "Never",
                ServiceAccountName = "spotvideo-worker",
                NodeSelector = new Dictionary<string, string> { ["kubernetes.azure.com/mode"] = "system", ["kubernetes.io/os"] = "linux" },
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

    private static V1Volume BlobFuseVolume(string name, string storageAccount, string containerName, string clientId, bool readOnly) =>
        new()
        {
            Name = name,
            Csi = new V1CSIVolumeSource
            {
                Driver = "blob.csi.azure.com",
                ReadOnlyProperty = readOnly,
                VolumeAttributes = new Dictionary<string, string>
                {
                    ["protocol"] = "fuse2",
                    ["storageAccount"] = storageAccount,
                    ["containerName"] = containerName,
                    ["AzureStorageAuthType"] = "MSI",
                    ["AzureStorageIdentityClientID"] = clientId,
                    ["mountOptions"] = "--use-attr-cache=true --file-cache-timeout-in-seconds=30 --disable-writeback-cache=true"
                }
            }
        };

    private string RequiredConfig(string key) =>
        configuration[key] ?? throw new InvalidOperationException($"{key} is required");

    private static bool IsNotFound(Exception exception) =>
        exception.ToString().Contains("404", StringComparison.Ordinal) ||
        exception.ToString().Contains("NotFound", StringComparison.OrdinalIgnoreCase);

    private static void Validate(SegmentEncoded completion)
    {
        if (string.IsNullOrWhiteSpace(completion.JobId))
            throw new ArgumentException("JobId is required");
        if (completion.SegmentCount <= 0 || completion.SegmentIndex < 0 || completion.SegmentIndex >= completion.SegmentCount)
            throw new ArgumentException("Segment index/count is invalid");
        if (string.IsNullOrWhiteSpace(completion.WorkingContainer))
            throw new ArgumentException("WorkingContainer is required");
        if (string.IsNullOrWhiteSpace(completion.BlobName))
            throw new ArgumentException("BlobName is required");
        if (string.IsNullOrWhiteSpace(completion.AudioBlobName))
            throw new ArgumentException("AudioBlobName is required");
        if (completion.OutputVideoUri.Scheme != Uri.UriSchemeHttps)
            throw new ArgumentException("OutputVideoUri must use HTTPS");
    }

    public override async Task StopAsync(CancellationToken cancellationToken)
    {
        if (_processor is not null)
            await _processor.StopProcessingAsync(cancellationToken);
        await base.StopAsync(cancellationToken);
    }
}