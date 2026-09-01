using System.Text.Json;
using Azure;
using Azure.Messaging.ServiceBus;
using FFMpegCore;
using k8s;
using k8s.Models;
using Video.Contracts;

namespace Video.Analysis;

public sealed class AnalysisWorker(
    ServiceBusClient serviceBus,
    IKubernetes kubernetes,
    IParallelizationStrategyFactory parallelizationStrategyFactory,
    IConfiguration configuration,
    ILogger<AnalysisWorker> logger) : BackgroundService
{
    private const string UseSpotAnnotation = "video.fastvideo/use-spot";
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
            var mediaRuntime = GetMediaRuntime(request.MediaRuntime, configuration["Encoding:MediaRuntimeDefault"] ?? "dotnet");
            var architecture = GetArchitecture(request.Architecture);

            var inputPath = BlobMountPaths.FromUri(request.InputVideoUri, inputAccount, inputContainer, inputMountPath);
            var audioPath = BlobMountPaths.FromBlobName(audioBlobName, outputMountPath);
            Directory.CreateDirectory(Path.GetDirectoryName(audioPath)!);

            var media = await FFProbe.AnalyseAsync(inputPath, cancellationToken: args.CancellationToken);
            if (media.Duration <= TimeSpan.Zero)
            {
                throw new InvalidOperationException("FFprobe returned an invalid duration");
            }
            var sourceAudio = media.PrimaryAudioStream
                ?? throw new InvalidOperationException("Input does not contain an audio stream");
            var maxAudioDurationSeconds = configuration.GetValue("Encoding:MaxAudioDurationSeconds", 21600);
            if (maxAudioDurationSeconds < 1)
            {
                throw new InvalidOperationException("Encoding:MaxAudioDurationSeconds must be greater than zero");
            }
            if (sourceAudio.Duration > TimeSpan.FromSeconds(maxAudioDurationSeconds))
            {
                throw new ArgumentException(
                    $"Audio duration {sourceAudio.Duration.TotalSeconds:F3}s exceeds the configured maximum of {maxAudioDurationSeconds}s");
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
            var ladderProfilesJson = LoadLadderProfiles(configuration);
            var encodingProfiles = EncodingProfileSelector.Select(
                sourceVideo,
                videoCodec,
                request.Preset,
                request.EncoderPreset,
                request.Crf,
                request.MaxVideoBitrateKbps,
                ladderProfilesJson);

            var audioEncodingRequired = !string.Equals(request.AudioCodec, "copy", StringComparison.OrdinalIgnoreCase);
            var outputType = VideoOutputTypes.Normalize(request.OutputType);
            if (!audioEncodingRequired)
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
                request.OutputPath,
                workingContainer,
                audioBlobName,
                media.Duration,
                segmentDurationSeconds,
                segments.Count,
                segments,
                videoCodec,
                request.AudioCodec,
                EncodingProfileSelector.IsLadderPreset(request.Preset, ladderProfilesJson) ? request.Preset!.ToLowerInvariant() : null,
                encodingProfiles.Select(profile => new VideoEncodingProfile(
                    profile.Name,
                    profile.Width,
                    profile.Height,
                    profile.EncoderPreset,
                    profile.Crf,
                    profile.MaxVideoBitrateKbps)).ToList(),
                request.UseSpot,
                request.CalculateVmaf,
                mediaRuntime,
                outputType);
            await WriteManifestAsync(manifest, outputMountPath, args.CancellationToken);
            await SubmitEncodingJobAsync(manifest, minParallelismPerJob, outputAccount, outputContainer, inputAccount, inputContainer, outputMountPath, inputMountPath, architecture, args.CancellationToken);
            if (audioEncodingRequired)
                await SubmitAudioEncodingJobAsync(manifest, outputAccount, outputContainer, inputAccount, inputContainer, outputMountPath, inputMountPath, architecture, args.CancellationToken);
            await args.CompleteMessageAsync(args.Message, args.CancellationToken);
            logger.LogInformation(
                "Submitted {SegmentCount} encoding indexes for {JobId} using {ParallelizationStrategy}; segment duration={SegmentDurationSeconds}s, initial parallelism={InitialParallelism}, max parallelism={MaxParallelism}, source={Width}x{Height} {SourceBitrateKbps}kbps, ladder={Ladder}",
                segments.Count,
                request.JobId,
                parallelizationStrategy.Name,
                segmentDurationSeconds,
                Math.Min(segments.Count, minParallelismPerJob),
                maxParallelism,
                sourceVideo.Width,
                sourceVideo.Height,
                sourceVideo.BitRate / 1000,
                string.Join(",", encodingProfiles.Select(profile => $"{profile.Name}:{profile.Width}x{profile.Height}@{profile.MaxVideoBitrateKbps}k")));
        }
        catch (Exception exception) when (IsTransient(exception))
        {
            logger.LogWarning(exception, "Transient failure processing analysis message; message will be retried");
        }
        catch (Exception exception)
        {
            logger.LogWarning(exception, "Non-retryable failure processing analysis message; dead-lettering");
            await args.DeadLetterMessageAsync(args.Message, exception.GetType().Name, exception.Message, args.CancellationToken);
        }
    }

    /// <summary>
    /// Determines whether an exception represents a transient condition (network blip, throttling,
    /// timeout) that is worth retrying via message redelivery, as opposed to a deterministic
    /// validation/configuration failure that will fail identically on every retry and should be
    /// dead-lettered immediately instead of looping until Service Bus exhausts MaxDeliveryCount.
    /// </summary>
    private static bool IsTransient(Exception exception) =>
        exception switch
        {
            OperationCanceledException => false,
            IOException => true,
            TimeoutException => true,
            ServiceBusException { IsTransient: true } => true,
            RequestFailedException requestFailed => requestFailed.Status is 408 or 429 or >= 500,
            HttpRequestException => true,
            _ => false
        };

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
        var targetNamespace = configuration["Kubernetes:Namespace"] ?? "video-servicebus";
        try
        {
            await kubernetes.BatchV1.ReadNamespacedJobAsync(jobName, targetNamespace, cancellationToken: cancellationToken);
            return;
        }
        catch (Exception exception) when (IsNotFound(exception))
        {
        }

        var mediaRuntime = JobTemplateFiles.NormalizeMediaRuntime(manifest.MediaRuntime);
        var job = await LoadJobTemplateAsync("encode", mediaRuntime, manifest.UseSpot, cancellationToken);
        job.Metadata ??= new V1ObjectMeta();
        job.Metadata.Name = jobName;
        var labels = EnsureLabels(job.Metadata);
        labels["app.kubernetes.io/name"] = "video-encoder";
        labels["video/job-id"] = JobNames.LabelValue(manifest.JobId);
        var annotations = EnsureAnnotations(job.Metadata);
        annotations[JobNames.JobIdAnnotation] = manifest.JobId;
        annotations[JobNames.AudioBlobNameAnnotation] = manifest.AudioBlobName;
        annotations[JobNames.AudioEncodingRequiredAnnotation] = (!string.Equals(manifest.AudioCodec, "copy", StringComparison.OrdinalIgnoreCase)).ToString();
        annotations[JobNames.OutputPathAnnotation] = manifest.OutputPath.ToString();
        annotations[JobNames.OutputTypeAnnotation] = manifest.OutputType;
        annotations[JobNames.CalculateVmafAnnotation] = manifest.CalculateVmaf ? "true" : "false";
        annotations[JobNames.MediaRuntimeAnnotation] = mediaRuntime;
        annotations[UseSpotAnnotation] = manifest.UseSpot ? "true" : "false";

        var spec = RequiredSpec(job);
        spec.Completions = manifest.SegmentCount;
        spec.Parallelism = Math.Min(manifest.SegmentCount, minParallelismPerJob);
        spec.ActiveDeadlineSeconds = configuration.GetValue("Encoding:EncodeJobActiveDeadlineSeconds", 21600);

        var podLabels = EnsureLabels(spec.Template.Metadata ??= new V1ObjectMeta());
        podLabels["app.kubernetes.io/name"] = "video-encoder";
        podLabels["video/job-id"] = JobNames.LabelValue(manifest.JobId);

        var podSpec = RequiredPodSpec(spec.Template, jobName);
        if (architecture is not null)
        {
            podSpec.NodeSelector ??= new Dictionary<string, string>(StringComparer.Ordinal);
            podSpec.NodeSelector["kubernetes.io/arch"] = architecture;
        }

        var container = RequiredContainer(podSpec, "encoder", jobName);
        SetEnvValue(container, "JOB_ID", manifest.JobId);
        SetEnvValue(container, "SOURCE_VIDEO_URI", manifest.InputVideoUri.ToString());
        SetEnvValue(container, "VIDEO_CODEC", manifest.VideoCodec);
        SetEnvValue(container, "CALCULATE_VMAF", manifest.CalculateVmaf ? "true" : "false");
        SetEnvValue(container, "INPUT_STORAGE_ACCOUNT_NAME", inputAccount);
        SetEnvValue(container, "INPUT_STORAGE_CONTAINER", inputContainer);
        SetEnvValue(container, "INPUT_MOUNT_PATH", inputMountPath);
        SetEnvValue(container, "OUTPUT_STORAGE_ACCOUNT_NAME", outputAccount);
        SetEnvValue(container, "OUTPUT_STORAGE_CONTAINER", outputContainer);
        SetEnvValue(container, "OUTPUT_MOUNT_PATH", outputMountPath);

        await kubernetes.BatchV1.CreateNamespacedJobAsync(job, targetNamespace, cancellationToken: cancellationToken);
    }

    private async Task SubmitAudioEncodingJobAsync(
        VideoManifest manifest,
        string outputAccount,
        string outputContainer,
        string inputAccount,
        string inputContainer,
        string outputMountPath,
        string inputMountPath,
        string? architecture,
        CancellationToken cancellationToken)
    {
        var jobName = JobNames.For("audio", manifest.JobId);
        var targetNamespace = configuration["Kubernetes:Namespace"] ?? "video-servicebus";
        try
        {
            await kubernetes.BatchV1.ReadNamespacedJobAsync(jobName, targetNamespace, cancellationToken: cancellationToken);
            return;
        }
        catch (Exception exception) when (IsNotFound(exception))
        {
        }

        var mediaRuntime = JobTemplateFiles.NormalizeMediaRuntime(manifest.MediaRuntime);
        var job = await LoadJobTemplateAsync("audio-encode", mediaRuntime, manifest.UseSpot, cancellationToken);
        job.Metadata ??= new V1ObjectMeta();
        job.Metadata.Name = jobName;
        var labels = EnsureLabels(job.Metadata);
        labels["app.kubernetes.io/name"] = "video-audio-encoder";
        labels["video/job-id"] = JobNames.LabelValue(manifest.JobId);
        var annotations = EnsureAnnotations(job.Metadata);
        annotations[JobNames.JobIdAnnotation] = manifest.JobId;
        annotations[UseSpotAnnotation] = manifest.UseSpot ? "true" : "false";

        var spec = RequiredSpec(job);
        spec.ActiveDeadlineSeconds = configuration.GetValue("Encoding:AudioEncodeJobActiveDeadlineSeconds", 21600);

        var podLabels = EnsureLabels(spec.Template.Metadata ??= new V1ObjectMeta());
        podLabels["app.kubernetes.io/name"] = "video-audio-encoder";
        podLabels["video/job-id"] = JobNames.LabelValue(manifest.JobId);

        var podSpec = RequiredPodSpec(spec.Template, jobName);
        if (architecture is not null)
        {
            podSpec.NodeSelector ??= new Dictionary<string, string>(StringComparer.Ordinal);
            podSpec.NodeSelector["kubernetes.io/arch"] = architecture;
        }

        var container = RequiredContainer(podSpec, "audio-encoder", jobName);
        SetEnvValue(container, "JOB_ID", manifest.JobId);
        SetEnvValue(container, "SOURCE_VIDEO_URI", manifest.InputVideoUri.ToString());
        SetEnvValue(container, "AUDIO_BLOB_NAME", manifest.AudioBlobName);
        SetEnvValue(container, "AUDIO_CODEC", manifest.AudioCodec);
        SetEnvValue(container, "INPUT_STORAGE_ACCOUNT_NAME", inputAccount);
        SetEnvValue(container, "INPUT_STORAGE_CONTAINER", inputContainer);
        SetEnvValue(container, "INPUT_MOUNT_PATH", inputMountPath);
        SetEnvValue(container, "OUTPUT_MOUNT_PATH", outputMountPath);

        await kubernetes.BatchV1.CreateNamespacedJobAsync(job, targetNamespace, cancellationToken: cancellationToken);
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

    private static async Task<V1Job> LoadJobTemplateAsync(string role, string mediaRuntime, bool useSpot, CancellationToken cancellationToken)
    {
        var path = JobTemplateFiles.PathFor(role, mediaRuntime, useSpot);
        if (!File.Exists(path))
            throw new InvalidOperationException($"Job template '{path}' does not exist");

        var yaml = await File.ReadAllTextAsync(path, cancellationToken);
        return KubernetesYaml.Deserialize<V1Job>(yaml, false)
            ?? throw new InvalidOperationException($"Job template '{path}' is empty");
    }

    private static string GetMediaRuntime(string? requestedRuntime, string defaultRuntime)
    {
        var mediaRuntime = string.IsNullOrWhiteSpace(requestedRuntime) ? defaultRuntime : requestedRuntime;
        return JobTemplateFiles.NormalizeMediaRuntime(mediaRuntime);
    }

    private static string? GetArchitecture(string? requestedArchitecture)
    {
        if (string.IsNullOrWhiteSpace(requestedArchitecture))
            return null;

        var architecture = requestedArchitecture.ToLowerInvariant();
        return architecture is "amd64" or "arm64"
            ? architecture
            : throw new ArgumentException("Architecture must be amd64 or arm64");
    }

    private static int CalculateSegmentDurationSeconds(TimeSpan duration, int maxParallelism, int minimumSegmentDurationSeconds)
    {
        var durationPerWorker = (int)Math.Ceiling(duration.TotalSeconds / maxParallelism);
        var maximumSegmentDurationSeconds = Math.Max(180, minimumSegmentDurationSeconds);
        return Math.Clamp(durationPerWorker, minimumSegmentDurationSeconds, maximumSegmentDurationSeconds);
    }

    private string RequiredConfig(string key) =>
        configuration[key] ?? throw new InvalidOperationException($"{key} is required");

    private static string? LoadLadderProfiles(IConfiguration configuration)
    {
        var path = configuration["Encoding:LadderProfilesPath"];
        if (!string.IsNullOrWhiteSpace(path))
        {
            try
            {
                return File.ReadAllText(path);
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
                throw new InvalidOperationException($"Could not read Encoding:LadderProfilesPath '{path}'", exception);
            }
        }
        return configuration["Encoding:LadderProfiles"];
    }

    private static bool IsNotFound(Exception exception) =>
        exception.ToString().Contains("404", StringComparison.Ordinal) ||
        exception.ToString().Contains("NotFound", StringComparison.OrdinalIgnoreCase);

    private static void Validate(VideoSubmitted request)
    {
        if (string.IsNullOrWhiteSpace(request.JobId) || request.JobId.Length > 128)
            throw new ArgumentException("JobId must contain 1-128 characters");
        if (request.InputVideoUri.Scheme != Uri.UriSchemeHttps)
            throw new ArgumentException("InputVideoUri must use HTTPS");
        if (request.OutputPath.Scheme != Uri.UriSchemeHttps)
            throw new ArgumentException("OutputPath must use HTTPS");
        if (request.OutputPath.AbsolutePath.EndsWith('/'))
            throw new ArgumentException("OutputPath must include a base filename");
        if (Path.HasExtension(request.OutputPath.AbsolutePath))
            throw new ArgumentException("OutputPath base filename must not include an extension");
        if (request.SegmentDurationSeconds is < 5 or > 3600)
            throw new ArgumentException("SegmentDurationSeconds must be between 5 and 3600");
        if (request.Crf is < 0 or > 63)
            throw new ArgumentException("Crf must be between 0 and 63");
        if (request.MaxVideoBitrateKbps is < 64 or > 100_000)
            throw new ArgumentException("MaxVideoBitrateKbps must be between 64 and 100000");
        if (!string.IsNullOrWhiteSpace(request.Preset) &&
            request.Preset.StartsWith("max", StringComparison.OrdinalIgnoreCase) &&
            !VideoLadderPresets.IsLadder(request.Preset))
            throw new ArgumentException("Preset must be max4k or max<height>p, for example max1080p");
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