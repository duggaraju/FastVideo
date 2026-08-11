using System.Text.Json;
using Azure.Messaging.ServiceBus;
using FFMpegCore;
using k8s;
using k8s.Models;
using SpotVideo.Contracts;

namespace SpotVideo.Analysis;

public sealed class AnalysisWorker(
    ServiceBusClient serviceBus,
    IKubernetes kubernetes,
    IParallelizationStrategyFactory parallelizationStrategyFactory,
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
            var request = args.Message.Body.ToObjectFromJson<VideoSubmitted>(JsonSerializerOptions.Web)
                ?? throw new InvalidOperationException("Message body is empty");
            Validate(request);
            var analysisStageId = JobNames.For("analysis", request.JobId);
            logger.LogInformation("Started analysis stage {AnalysisStageId} for {JobId}", analysisStageId, request.JobId);
            var parallelizationStrategy = parallelizationStrategyFactory.GetStrategy(request.ParallelizationStrategy);
            var workingContainer = configuration["Storage:WorkingContainer"] ?? "videos";
            var inputAccount = RequiredConfig("Storage:InputAccountName");
            var inputContainer = RequiredConfig("Storage:InputContainer");
            var outputAccount = RequiredConfig("Storage:OutputAccountName");
            var outputContainer = RequiredConfig("Storage:OutputContainer");
            var inputMountPath = configuration["Storage:InputMountPath"] ?? "/mnt/input";
            var outputMountPath = configuration["Storage:OutputMountPath"] ?? "/mnt/output";
            var audioBlobName = $"{request.JobId}/segments/audio.m4a";
            var videoCodec = string.IsNullOrWhiteSpace(request.VideoCodec) ? "libsvtav1" : request.VideoCodec;
            var architecture = GetBenchmarkArchitecture(args.Message);

            var inputPath = BlobMountPaths.FromUri(request.InputVideoUri, inputAccount, inputContainer, inputMountPath);
            var audioPath = BlobMountPaths.FromBlobName(audioBlobName, outputMountPath);
            Directory.CreateDirectory(Path.GetDirectoryName(audioPath)!);

            var media = await FFProbe.AnalyseAsync(inputPath, cancellationToken: args.CancellationToken);
            if (media.Duration <= TimeSpan.Zero)
            {
                throw new InvalidOperationException("FFprobe returned an invalid duration");
            }
            var maxParallelism = configuration.GetValue("Encoding:MaxParallelism", 16);
            if (maxParallelism < 1)
            {
                throw new InvalidOperationException("Encoding:MaxParallelism must be greater than zero");
            }
            var minParallelismPerJob = configuration.GetValue("Encoding:MinParallelismPerJob", 2);
            if (minParallelismPerJob < 1 || minParallelismPerJob > maxParallelism)
            {
                throw new InvalidOperationException(
                    "Encoding:MinParallelismPerJob must be between 1 and Encoding:MaxParallelism");
            }
            var segmentDurationSeconds = CalculateSegmentDurationSeconds(
                media.Duration,
                maxParallelism,
                request.SegmentDurationSeconds);
            var sourceVideo = media.PrimaryVideoStream
                ?? throw new InvalidOperationException("Input does not contain a video stream");
            var encodingProfile = EncodingProfileSelector.Select(
                sourceVideo,
                videoCodec,
                request.Preset,
                request.Crf,
                request.MaxVideoBitrateKbps);

            await ExtractAudioAsync(inputPath, audioPath, request.AudioCodec);

            var segments = await parallelizationStrategy.CreateSegmentsAsync(
                inputPath,
                media.Duration,
                segmentDurationSeconds,
                args.CancellationToken);
            if (segments.Count == 0)
                throw new InvalidOperationException("Parallelization strategy produced no segments");

            var manifest = new VideoManifest(
                request.JobId,
                request.InputVideoUri,
                request.OutputVideoUri,
                workingContainer,
                audioBlobName,
                media.Duration,
                segmentDurationSeconds,
                segments.Count,
                segments,
                videoCodec,
                request.AudioCodec,
                encodingProfile.Preset,
                encodingProfile.Crf,
                encodingProfile.MaxVideoBitrateKbps,
                request.UseSpot,
                request.CalculateVmaf);
            await WriteManifestAsync(manifest, outputMountPath, args.CancellationToken);
            await SubmitEncodingJobAsync(manifest, minParallelismPerJob, outputAccount, outputContainer, inputAccount, inputContainer, outputMountPath, inputMountPath, architecture, args.CancellationToken);
            await args.CompleteMessageAsync(args.Message, args.CancellationToken);
            logger.LogInformation(
                "Submitted {SegmentCount} encoding indexes for {JobId} using {ParallelizationStrategy}; segment duration={SegmentDurationSeconds}s, initial parallelism={InitialParallelism}, max parallelism={MaxParallelism}, source={Width}x{Height} {SourceBitrateKbps}kbps, preset={Preset}, crf={Crf}, maxrate={MaxVideoBitrateKbps}kbps",
                segments.Count,
                request.JobId,
                parallelizationStrategy.Name,
                segmentDurationSeconds,
                Math.Min(segments.Count, minParallelismPerJob),
                maxParallelism,
                sourceVideo.Width,
                sourceVideo.Height,
                sourceVideo.BitRate / 1000,
                encodingProfile.Preset,
                encodingProfile.Crf,
                encodingProfile.MaxVideoBitrateKbps);
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

    private static async Task WriteManifestAsync(VideoManifest manifest, string outputMountPath, CancellationToken cancellationToken)
    {
        var manifestPath = BlobMountPaths.FromBlobName($"{manifest.JobId}/manifest.json", outputMountPath);
        Directory.CreateDirectory(Path.GetDirectoryName(manifestPath)!);
        var content = JsonSerializer.SerializeToUtf8Bytes(manifest);
        await File.WriteAllBytesAsync(manifestPath, content, cancellationToken);
    }

    private async Task SubmitEncodingJobAsync(
        VideoManifest manifest,
        int minParallelismPerJob,
        string outputAccount,
        string outputContainer,
        string inputAccount,
        string inputContainer,
        string outputMountPath,
        string inputMountPath,
        string? architecture,
        CancellationToken cancellationToken)
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
            Env("VIDEO_CODEC", manifest.VideoCodec),
            Env("PRESET", manifest.Preset),
            Env("CRF", manifest.Crf.ToString()),
            Env("MAX_VIDEO_BITRATE_KBPS", manifest.MaxVideoBitrateKbps.ToString()),
            Env("CALCULATE_VMAF", manifest.CalculateVmaf.ToString()),
            Env("INPUT_STORAGE_ACCOUNT_NAME", inputAccount),
            Env("INPUT_STORAGE_CONTAINER", inputContainer),
            Env("INPUT_MOUNT_PATH", inputMountPath),
            Env("OUTPUT_STORAGE_ACCOUNT_NAME", outputAccount),
            Env("OUTPUT_STORAGE_CONTAINER", outputContainer),
            Env("OUTPUT_MOUNT_PATH", outputMountPath)
        };
        var inputVolumeName = "input-storage";
        var outputVolumeName = "output-storage";
        var labels = new Dictionary<string, string>
        {
            ["app.kubernetes.io/name"] = "spotvideo-encoder",
            ["spotvideo/job-id"] = JobNames.LabelValue(manifest.JobId),
            ["azure.workload.identity/use"] = "true"
        };
        var nodeSelector = new Dictionary<string, string>
        {
            ["workload"] = "video-encoding",
            ["kubernetes.azure.com/scalesetpriority"] = manifest.UseSpot ? "spot" : "regular"
        };
        if (architecture is not null)
            nodeSelector["kubernetes.io/arch"] = architecture;

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
                        VolumeMounts =
                        [
                            new V1VolumeMount { Name = inputVolumeName, MountPath = inputMountPath, ReadOnlyProperty = true },
                            new V1VolumeMount { Name = outputVolumeName, MountPath = outputMountPath }
                        ],
                        Resources = new V1ResourceRequirements
                        {
                            Requests = new Dictionary<string, ResourceQuantity> { ["cpu"] = new("1750m"), ["memory"] = new("4Gi") },
                            Limits = new Dictionary<string, ResourceQuantity> { ["cpu"] = new("4"), ["memory"] = new("8Gi") }
                        }
                    }
                ],
                Volumes =
                [
                    BlobFuseVolume(inputVolumeName, inputAccount, inputContainer, RequiredConfig("WorkloadIdentity:ClientId"), readOnly: true),
                    BlobFuseVolume(outputVolumeName, outputAccount, outputContainer, RequiredConfig("WorkloadIdentity:ClientId"), readOnly: false)
                ],
                RestartPolicy = "Never",
                ServiceAccountName = "spotvideo-worker",
                Tolerations = manifest.UseSpot
                    ? [new V1Toleration { Effect = "NoSchedule", OperatorProperty = "Equal", Key = "kubernetes.azure.com/scalesetpriority", Value = "spot" }]
                    : null,
                NodeSelector = nodeSelector,
                TerminationGracePeriodSeconds = 120
            }
        };
        var job = new V1Job
        {
            Metadata = new V1ObjectMeta
            {
                Name = jobName,
                Labels = labels,
                Annotations = new Dictionary<string, string>
                {
                    [JobNames.JobIdAnnotation] = manifest.JobId,
                    [JobNames.StageIdAnnotation] = jobName,
                    [JobNames.UseSpotAnnotation] = manifest.UseSpot.ToString(),
                    [JobNames.SegmentCountAnnotation] = manifest.SegmentCount.ToString(),
                    [JobNames.AudioBlobNameAnnotation] = manifest.AudioBlobName,
                    [JobNames.OutputVideoUriAnnotation] = manifest.OutputVideoUri.ToString(),
                    [JobNames.CalculateVmafAnnotation] = manifest.CalculateVmaf.ToString()
                }
            },
            Spec = new V1JobSpec
            {
                Template = pod,
                CompletionMode = "Indexed",
                Completions = manifest.SegmentCount,
                Parallelism = Math.Min(manifest.SegmentCount, minParallelismPerJob),
                BackoffLimitPerIndex = 5,
                TtlSecondsAfterFinished = 86400
            }
        };
        if (architecture is not null)
            job.Metadata.Annotations[JobNames.ArchitectureAnnotation] = architecture;
        await kubernetes.BatchV1.CreateNamespacedJobAsync(job, targetNamespace, cancellationToken: cancellationToken);
    }

    private static string? GetBenchmarkArchitecture(ServiceBusReceivedMessage message)
    {
        if (!message.ApplicationProperties.TryGetValue(JobNames.BenchmarkArchitectureProperty, out var value))
            return null;

        var architecture = Convert.ToString(value);
        return architecture is "amd64" or "arm64"
            ? architecture
            : throw new ArgumentException($"{JobNames.BenchmarkArchitectureProperty} must be amd64 or arm64");
    }

    private static V1EnvVar Env(string name, string value) => new() { Name = name, Value = value };

    private static int CalculateSegmentDurationSeconds(TimeSpan duration, int maxParallelism, int minimumSegmentDurationSeconds)
    {
        var durationPerWorker = (int)Math.Ceiling(duration.TotalSeconds / maxParallelism);
        var maximumSegmentDurationSeconds = Math.Max(180, minimumSegmentDurationSeconds);
        return Math.Clamp(durationPerWorker, minimumSegmentDurationSeconds, maximumSegmentDurationSeconds);
    }

    private static V1Volume BlobFuseVolume(string name, string storageAccount, string containerName, string clientId, bool readOnly)
    {
        var mountOptions = readOnly
            ? "--allow-other --use-attr-cache=true --cancel-list-on-mount-seconds=10"
            : "--allow-other --use-attr-cache=true --disable-writeback-cache=true";
        return new V1Volume
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
                    ["ClientID"] = clientId,
                    ["mountWithWorkloadIdentityToken"] = "true",
                    ["mountOptions"] = mountOptions
                }
            }
        };
    }

    private string RequiredConfig(string key) =>
        configuration[key] ?? throw new InvalidOperationException($"{key} is required");

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
        if (request.Crf is < 0 or > 63)
            throw new ArgumentException("Crf must be between 0 and 63");
        if (request.MaxVideoBitrateKbps is < 64 or > 100_000)
            throw new ArgumentException("MaxVideoBitrateKbps must be between 64 and 100000");
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