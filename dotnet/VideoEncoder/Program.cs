using System.Diagnostics;
using System.Globalization;
using System.Text.Json;
using FFMpegCore;
using Video.Contracts;

GlobalFFOptions.Configure(options =>
{
    options.BinaryFolder = Environment.GetEnvironmentVariable("FFMPEG_BINARY_FOLDER")
        ?? (Directory.Exists("/opt/ffmpeg/bin") ? "/opt/ffmpeg/bin" : "/usr/bin");
    options.TemporaryFilesFolder = "/tmp";
});

var jobId = Required("JOB_ID");
var index = int.Parse(Required("JOB_COMPLETION_INDEX"));
var sourceUri = new Uri(Required("SOURCE_VIDEO_URI"));
var inputPath = BlobMountPaths.FromUri(
    sourceUri,
    Required("INPUT_STORAGE_ACCOUNT_NAME"),
    Required("INPUT_STORAGE_CONTAINER"),
    Required("INPUT_MOUNT_PATH"));
var outputMountPath = Required("OUTPUT_MOUNT_PATH");
var manifestPath = BlobMountPaths.FromBlobName($"{jobId}/manifest.json", outputMountPath);
await using var manifestStream = File.OpenRead(manifestPath);
var manifest = await JsonSerializer.DeserializeAsync<VideoManifest>(manifestStream, JsonSerializerOptions.Web)
    ?? throw new InvalidOperationException("Manifest payload is empty");
var segmentCount = manifest.SegmentCount;
if (index < 0 || index >= segmentCount)
    throw new InvalidOperationException($"Completion index {index} is outside segment count {segmentCount}");
var segment = manifest.Segments.SingleOrDefault(item => item.Index == index)
    ?? throw new InvalidOperationException($"Segment definition for index {index} was not found");
var calculateVmaf = bool.Parse(Required("CALCULATE_VMAF"));
var stagingDirectory = BlobMountPaths.FromBlobName($"{jobId}/segments/.staging", outputMountPath);
Directory.CreateDirectory(stagingDirectory);

var pending = new List<PendingProfile>();
foreach (var profile in manifest.EncodingProfiles)
{
    var outputPath = BlobMountPaths.FromBlobName($"{jobId}/segments/{index:D6}-{profile.Name}.mp4", outputMountPath);
    var vmafPath = BlobMountPaths.FromBlobName($"{jobId}/segments/{index:D6}-{profile.Name}.vmaf.json", outputMountPath);
    Directory.CreateDirectory(Path.GetDirectoryName(outputPath)!);

    if (calculateVmaf && File.Exists(outputPath) != File.Exists(vmafPath))
    {
        File.Delete(outputPath);
        File.Delete(vmafPath);
    }

    if (File.Exists(outputPath) && (!calculateVmaf || File.Exists(vmafPath)))
        continue;

    var stagingId = $"{index:D6}-{profile.Name}-{Guid.NewGuid():N}";
    var stagingPath = Path.Combine(stagingDirectory, $"{stagingId}.mp4");
    var stagingVmafPath = Path.Combine(stagingDirectory, $"{stagingId}.vmaf.json");
    var rawVmafPath = Path.Combine(stagingDirectory, $"{stagingId}.libvmaf.json");
    pending.Add(new PendingProfile(
        profile,
        outputPath,
        vmafPath,
        stagingPath,
        stagingVmafPath,
        rawVmafPath));
}

try
{
    await EncodeProfilesAsync(inputPath, pending, segment, manifest.VideoCodec, calculateVmaf);
    if (calculateVmaf && pending.Count > 0)
    {
        foreach (var item in pending)
        {
            var score = await ReadVmafScoreAsync(item.RawVmafPath);
            await File.WriteAllBytesAsync(
                item.StagingVmafPath,
                JsonSerializer.SerializeToUtf8Bytes(new SegmentVmaf(index, score)));
        }
    }

    foreach (var item in pending)
    {
        Publish(item.StagingPath, item.OutputPath);
        if (calculateVmaf)
            Publish(item.StagingVmafPath, item.VmafPath);
    }
}
finally
{
    foreach (var item in pending)
    {
        File.Delete(item.StagingPath);
        File.Delete(item.StagingVmafPath);
        File.Delete(item.RawVmafPath);
    }
}

static async Task EncodeProfilesAsync(
    string sourcePath,
    IReadOnlyList<PendingProfile> outputs,
    VideoSegment segment,
    string videoCodec,
    bool calculateVmaf)
{
    if (outputs.Count == 0)
        return;

    var startInfo = CreateFfmpegStartInfo();
    AddArguments(startInfo,
        "-ss", segment.StartSeconds.ToString(CultureInfo.InvariantCulture),
        "-t", segment.DurationSeconds.ToString(CultureInfo.InvariantCulture),
        "-i", sourcePath);
    AddArguments(startInfo, "-filter_complex", calculateVmaf
        ? BuildProfileAndReferenceFilter(outputs)
        : BuildProfileFilter(outputs.Select(item => item.Profile).ToList()));
    AddProfileOutputs(startInfo, outputs, videoCodec);
    if (calculateVmaf)
    {
        for (var outputIndex = 0; outputIndex < outputs.Count; outputIndex++)
            AddArguments(startInfo, "-dec", $"{outputIndex}:0");
        AddArguments(startInfo, "-filter_complex", BuildVmafComparisonFilter(outputs));
        for (var outputIndex = 0; outputIndex < outputs.Count; outputIndex++)
            AddArguments(startInfo, "-map", $"[vmaf{outputIndex}]", "-f", "null", "-");
    }
    await RunFfmpegAsync(startInfo, calculateVmaf
        ? "multi-profile encoding with VMAF"
        : "multi-profile encoding");
}

static void AddProfileOutputs(
    ProcessStartInfo startInfo,
    IReadOnlyList<PendingProfile> outputs,
    string videoCodec)
{
    for (var outputIndex = 0; outputIndex < outputs.Count; outputIndex++)
    {
        var item = outputs[outputIndex];
        var profile = item.Profile;
        AddArguments(startInfo,
            "-map", $"[profile{outputIndex}]", "-an",
            "-c:v", videoCodec,
            "-preset", profile.EncoderPreset,
            "-crf", profile.Crf.ToString(CultureInfo.InvariantCulture));
        if (profile.MaxVideoBitrateKbps > 0)
        {
            AddArguments(startInfo,
                "-maxrate", $"{profile.MaxVideoBitrateKbps}k",
                "-bufsize", $"{2 * profile.MaxVideoBitrateKbps}k");
        }
        AddArguments(startInfo,
            "-fps_mode", "passthrough",
            "-movflags", "+faststart",
            "-avoid_negative_ts", "make_zero",
            item.StagingPath);
    }
}

static string BuildProfileFilter(IReadOnlyList<VideoEncodingProfile> profiles)
{
    var filters = new List<string>();
    filters.Add(profiles.Count == 1
        ? "[0:v]null[split0]"
        : $"[0:v]split={profiles.Count}{string.Concat(Enumerable.Range(0, profiles.Count).Select(index => $"[split{index}]"))}");
    filters.AddRange(profiles.Select((profile, profileIndex) =>
        $"[split{profileIndex}]scale={profile.Width}:{profile.Height}:flags=lanczos,setsar=1[profile{profileIndex}]"));
    return string.Join(';', filters);
}

static string BuildProfileAndReferenceFilter(IReadOnlyList<PendingProfile> outputs)
{
    var filters = new List<string>();
    var splitOutputs = string.Concat(Enumerable.Range(0, outputs.Count).Select(index => $"[split{index}]")
        .Concat(Enumerable.Range(0, outputs.Count).Select(index => $"[reference{index}]")));
    filters.Add($"[0:v]split={2 * outputs.Count}{splitOutputs}");
    for (var outputIndex = 0; outputIndex < outputs.Count; outputIndex++)
    {
        var item = outputs[outputIndex];
        filters.Add($"[split{outputIndex}]scale={item.Profile.Width}:{item.Profile.Height}:flags=lanczos,setsar=1[profile{outputIndex}]");
        filters.Add($"[reference{outputIndex}]scale={item.Profile.Width}:{item.Profile.Height}:flags=lanczos,setsar=1,setpts=PTS-STARTPTS[scaled{outputIndex}]");
    }
    return string.Join(';', filters);
}

static string BuildVmafComparisonFilter(IReadOnlyList<PendingProfile> outputs)
{
    var filters = new List<string>();
    for (var outputIndex = 0; outputIndex < outputs.Count; outputIndex++)
    {
        var item = outputs[outputIndex];
        filters.Add($"[dec:{outputIndex}]setpts=PTS-STARTPTS[distorted{outputIndex}]");
        filters.Add($"[distorted{outputIndex}][scaled{outputIndex}]libvmaf=model=path=/opt/ffmpeg/share/vmaf/vmaf_v0.6.1.json:log_fmt=json:log_path={EscapeFilterPath(item.RawVmafPath)}[vmaf{outputIndex}]");
    }
    return string.Join(';', filters);
}

static ProcessStartInfo CreateFfmpegStartInfo()
{
    var startInfo = new ProcessStartInfo
    {
        FileName = "ffmpeg",
        RedirectStandardError = true,
        UseShellExecute = false
    };
    AddArguments(startInfo, "-hide_banner", "-nostdin", "-v", "error", "-y");
    return startInfo;
}

static void AddArguments(ProcessStartInfo startInfo, params string[] arguments)
{
    foreach (var argument in arguments)
        startInfo.ArgumentList.Add(argument);
}

static async Task RunFfmpegAsync(ProcessStartInfo startInfo, string operation)
{
    using var process = Process.Start(startInfo)
        ?? throw new InvalidOperationException($"Failed to start FFmpeg {operation}");
    var error = await process.StandardError.ReadToEndAsync();
    await process.WaitForExitAsync();
    if (process.ExitCode != 0)
        throw new InvalidOperationException($"FFmpeg {operation} failed: {error}");
}

static string EscapeFilterPath(string path) => path
    .Replace("\\", "\\\\", StringComparison.Ordinal)
    .Replace(":", "\\:", StringComparison.Ordinal)
    .Replace("'", "\\'", StringComparison.Ordinal);

static void Publish(string stagingPath, string canonicalPath)
{
    try
    {
        File.Move(stagingPath, canonicalPath, false);
    }
    catch (IOException) when (File.Exists(canonicalPath))
    {
    }
}

static string Required(string name) =>
    Environment.GetEnvironmentVariable(name) ?? throw new InvalidOperationException($"{name} is required");

static async Task<double> ReadVmafScoreAsync(string logPath)
{
    await using var stream = File.OpenRead(logPath);
    using var document = await JsonDocument.ParseAsync(stream);
    return document.RootElement
        .GetProperty("pooled_metrics")
        .GetProperty("vmaf")
        .GetProperty("mean")
        .GetDouble();
}

sealed record PendingProfile(
    VideoEncodingProfile Profile,
    string OutputPath,
    string VmafPath,
    string StagingPath,
    string StagingVmafPath,
    string RawVmafPath);