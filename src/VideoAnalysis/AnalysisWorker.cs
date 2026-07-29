using System.Text.Json;
using Azure;
using Azure.Core;
using Azure.Messaging.ServiceBus;
using Azure.Storage.Blobs;
using FFMpegCore;
using k8s;
using k8s.Models;
using SpotVideo.Contracts;

namespace SpotVideo.Analysis;

public sealed class AnalysisWorker(
    ServiceBusClient serviceBus,
    BlobServiceClient storage,
    TokenCredential credential,
    IKubernetes kubernetes,
    IParallelizationStrategy parallelizationStrategy,
    IConfiguration configuration,
    ILogger<AnalysisWorker> logger) : BackgroundService
{
    private ServiceBusProcessor? _processor;

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        _processor = serviceBus.CreateProcessor(
            configuration["ServiceBus:InputQueue"] ?? "video-submitted",
            new ServiceBusProcessorOptions { AutoCompleteMessages = false, MaxConcurrentCalls = 1 });
        _processor.ProcessMessageAsync += ProcessMessageAsync;
        _processor.ProcessErrorAsync += args =>
        {
            logger.LogError(args.Exception, "Service Bus analysis processor failed at {Source}", args.ErrorSource);
            return Task.CompletedTask;
        };
        await _processor.StartProcessingAsync(stoppingToken);
        await Task.Delay(Timeout.Infinite, stoppingToken);
    }

    private async Task ProcessMessageAsync(ProcessMessageEventArgs args)
    {
        try
        {
            var request = args.Message.Body.ToObjectFromJson<VideoSubmitted>()
                ?? throw new InvalidOperationException("Message body is empty");
            Validate(request);
            var workingContainer = configuration["Storage:WorkingContainer"] ?? "videos";
            var audioBlobName = $"{request.JobId}/audio.m4a";

            var inputPath = Path.Combine(Path.GetTempPath(), $"{request.JobId}-source");
            var audioPath = Path.Combine(Path.GetTempPath(), $"{request.JobId}-audio.m4a");
            try
            {
                await CreateSourceClient(request.InputVideoUri).DownloadToAsync(inputPath, args.CancellationToken);
                var media = await FFProbe.AnalyseAsync(inputPath, cancellationToken: args.CancellationToken);
                if (media.Duration <= TimeSpan.Zero)
                {
                    throw new InvalidOperationException("FFprobe returned an invalid duration");
                }

                await ExtractAudioAsync(inputPath, audioPath, request.AudioCodec);
                await storage.GetBlobContainerClient(workingContainer)
                    .GetBlobClient(audioBlobName)
                    .UploadAsync(audioPath, overwrite: true, args.CancellationToken);

                var segments = await parallelizationStrategy.CreateSegmentsAsync(
                    inputPath,
                    media.Duration,
                    request.SegmentDurationSeconds,
                    args.CancellationToken);
                if (segments.Count == 0)
                    throw new InvalidOperationException("Parallelization strategy produced no segments");

                var manifest = new VideoManifest(
                    request.JobId, request.InputVideoUri, request.OutputVideoUri, workingContainer, audioBlobName, media.Duration,
                    request.SegmentDurationSeconds, segments.Count, segments, request.VideoCodec,
                    request.AudioCodec, request.Preset, request.Crf);
                await WriteManifestAsync(manifest, args.CancellationToken);
                await SubmitEncodingJobAsync(manifest, args.CancellationToken);
                await args.CompleteMessageAsync(args.Message, args.CancellationToken);
                logger.LogInformation(
                    "Submitted {SegmentCount} encoding indexes for {JobId} using {ParallelizationStrategy}",
                    segments.Count,
                    request.JobId,
                    parallelizationStrategy.Name);
            }
            finally
            {
                File.Delete(inputPath);
                File.Delete(audioPath);
            }
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

    private BlobClient CreateSourceClient(Uri sourceUri) =>
        string.IsNullOrEmpty(sourceUri.Query) ? new BlobClient(sourceUri, credential) : new BlobClient(sourceUri);

    private static Task ExtractAudioAsync(string inputPath, string audioPath, string audioCodec) =>
        FFMpegArguments
            .FromFileInput(inputPath)
            .OutputToFile(audioPath, true, options =>
            {
                options.WithCustomArgument("-map 0:a:0 -vn -sn -dn");
                if (string.Equals(audioCodec, "copy", StringComparison.OrdinalIgnoreCase))
                    options.WithCustomArgument("-c:a copy");
                else
                    options.WithAudioCodec(audioCodec);
            })
            .ProcessAsynchronously();

    private async Task WriteManifestAsync(VideoManifest manifest, CancellationToken cancellationToken)
    {
        var container = storage.GetBlobContainerClient(manifest.WorkingContainer);
        var content = BinaryData.FromObjectAsJson(manifest);
        await container.GetBlobClient($"{manifest.JobId}/manifest.json")
            .UploadAsync(content, overwrite: true, cancellationToken);
    }

    private async Task SubmitEncodingJobAsync(VideoManifest manifest, CancellationToken cancellationToken)
    {
        var jobName = JobNames.For("encode", manifest.JobId);
        var targetNamespace = configuration["Kubernetes:Namespace"] ?? "spotvideo";
        try
        {
            await kubernetes.BatchV1.ReadNamespacedJobAsync(jobName, targetNamespace, cancellationToken: cancellationToken);
            return;
        }
        catch (Exception exception) when (IsNotFound(exception))
        {
        }

        var environment = new List<V1EnvVar>
        {
            new() { Name = "JOB_COMPLETION_INDEX", ValueFrom = new V1EnvVarSource { FieldRef = new V1ObjectFieldSelector { FieldPath = "metadata.annotations['batch.kubernetes.io/job-completion-index']" } } },
            Env("JOB_ID", manifest.JobId),
            Env("SOURCE_VIDEO_URI", manifest.InputVideoUri.ToString()),
            Env("OUTPUT_CONTAINER", manifest.WorkingContainer),
            Env("AUDIO_BLOB_NAME", manifest.AudioBlobName),
            Env("OUTPUT_VIDEO_URI", manifest.OutputVideoUri.ToString()),
            Env("VIDEO_CODEC", manifest.VideoCodec),
            Env("PRESET", manifest.Preset),
            Env("CRF", manifest.Crf.ToString()),
            Env("STORAGE_SERVICE_URI", configuration["Storage:ServiceUri"]!),
            Env("SERVICE_BUS_NAMESPACE", configuration["ServiceBus:Namespace"]!),
            Env("COMPLETION_QUEUE", configuration["ServiceBus:CompletionQueue"] ?? "segment-completed")
        };
        var labels = new Dictionary<string, string>
        {
            ["app.kubernetes.io/name"] = "spotvideo-encoder",
            ["spotvideo/job-id"] = JobNames.LabelValue(manifest.JobId),
            ["azure.workload.identity/use"] = "true"
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
                        Name = "encoder",
                        Image = configuration["Images:Encoder"] ?? throw new InvalidOperationException("Images:Encoder is required"),
                        Env = environment,
                        Resources = new V1ResourceRequirements
                        {
                            Requests = new Dictionary<string, ResourceQuantity> { ["cpu"] = new("2"), ["memory"] = new("4Gi") },
                            Limits = new Dictionary<string, ResourceQuantity> { ["cpu"] = new("4"), ["memory"] = new("8Gi") }
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
            Spec = new V1JobSpec
            {
                Template = pod,
                CompletionMode = "Indexed",
                Completions = manifest.SegmentCount,
                Parallelism = Math.Min(manifest.SegmentCount, configuration.GetValue("Encoding:MaxParallelism", 16)),
                BackoffLimit = 6,
                TtlSecondsAfterFinished = 3600
            }
        };
        await kubernetes.BatchV1.CreateNamespacedJobAsync(job, targetNamespace, cancellationToken: cancellationToken);
    }

    private static V1EnvVar Env(string name, string value) => new() { Name = name, Value = value };

    private static bool IsNotFound(Exception exception) =>
        exception.ToString().Contains("404", StringComparison.Ordinal) ||
        exception.ToString().Contains("NotFound", StringComparison.OrdinalIgnoreCase);

    private static void Validate(VideoSubmitted request)
    {
        if (string.IsNullOrWhiteSpace(request.JobId) || request.JobId.Length > 128)
            throw new ArgumentException("JobId must contain 1-128 characters");
        if (request.InputVideoUri.Scheme != Uri.UriSchemeHttps)
            throw new ArgumentException("InputVideoUri must use HTTPS");
        if (request.OutputVideoUri.Scheme != Uri.UriSchemeHttps)
            throw new ArgumentException("OutputVideoUri must use HTTPS");
        if (request.SegmentDurationSeconds is < 5 or > 3600)
            throw new ArgumentException("SegmentDurationSeconds must be between 5 and 3600");
        if (request.Crf is < 0 or > 51)
            throw new ArgumentException("Crf must be between 0 and 51");
        if (string.IsNullOrWhiteSpace(request.AudioCodec))
            throw new ArgumentException("AudioCodec is required");
    }

    public override async Task StopAsync(CancellationToken cancellationToken)
    {
        if (_processor is not null)
            await _processor.StopProcessingAsync(cancellationToken);
        await base.StopAsync(cancellationToken);
    }
}