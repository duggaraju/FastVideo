using System.Diagnostics;
using System.Globalization;
using System.Text.Json;
using FFMpegCore;
using SpotVideo.Contracts;

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
var manifest = await JsonSerializer.DeserializeAsync<VideoManifest>(manifestStream)
    ?? throw new InvalidOperationException("Manifest payload is empty");
var segmentCount = manifest.SegmentCount;
if (index < 0 || index >= segmentCount)
    throw new InvalidOperationException($"Completion index {index} is outside segment count {segmentCount}");
var segment = manifest.Segments.SingleOrDefault(item => item.Index == index)
    ?? throw new InvalidOperationException($"Segment definition for index {index} was not found");
var blobName = $"{jobId}/segments/{index:D6}.mp4";
var outputPath = BlobMountPaths.FromBlobName(blobName, outputMountPath);
var vmafPath = BlobMountPaths.FromBlobName($"{jobId}/segments/{index:D6}.vmaf.json", outputMountPath);
Directory.CreateDirectory(Path.GetDirectoryName(outputPath)!);
var calculateVmaf = bool.Parse(Required("CALCULATE_VMAF"));

if (calculateVmaf && File.Exists(outputPath) != File.Exists(vmafPath))
{
    File.Delete(outputPath);
    File.Delete(vmafPath);
}

if (File.Exists(outputPath) && (!calculateVmaf || File.Exists(vmafPath)))
    return;

var stagingId = $"{index:D6}-{Guid.NewGuid():N}";
var stagingDirectory = BlobMountPaths.FromBlobName($"{jobId}/segments/.staging", outputMountPath);
var stagingPath = Path.Combine(stagingDirectory, $"{stagingId}.mp4");
var stagingVmafPath = Path.Combine(stagingDirectory, $"{stagingId}.vmaf.json");
var rawVmafPath = Path.Combine(stagingDirectory, $"{stagingId}.libvmaf.json");
Directory.CreateDirectory(stagingDirectory);
try
{
    if (calculateVmaf)
        await EncodeWithVmafAsync(inputPath, stagingPath, rawVmafPath, segment);
    else
        await EncodeAsync(inputPath, stagingPath, segment);

    if (calculateVmaf)
    {
        var score = await ReadVmafScoreAsync(rawVmafPath);
        await File.WriteAllBytesAsync(
            stagingVmafPath,
            JsonSerializer.SerializeToUtf8Bytes(new SegmentVmaf(index, score)));
        Publish(stagingVmafPath, vmafPath);
    }

    Publish(stagingPath, outputPath);
}
finally
{
    File.Delete(stagingPath);
    File.Delete(stagingVmafPath);
    File.Delete(rawVmafPath);
}

static async Task EncodeAsync(string sourcePath, string encodedPath, VideoSegment segment)
{
    var maxVideoBitrateKbps = int.Parse(Required("MAX_VIDEO_BITRATE_KBPS"));
    var rateControlArguments = maxVideoBitrateKbps > 0
        ? $" -maxrate {maxVideoBitrateKbps}k -bufsize {2 * maxVideoBitrateKbps}k"
        : string.Empty;
    await FFMpegArguments
        .FromFileInput(sourcePath, false, options => options.Seek(TimeSpan.FromSeconds(segment.StartSeconds)))
        .OutputToFile(encodedPath, false, options => options
            .WithDuration(TimeSpan.FromSeconds(segment.DurationSeconds))
            .WithVideoCodec(Required("VIDEO_CODEC"))
            .WithCustomArgument($"-an -preset {Required("PRESET")} -crf {Required("CRF")}{rateControlArguments} -fps_mode passthrough -movflags +faststart -avoid_negative_ts make_zero"))
        .ProcessAsynchronously();
}

static async Task EncodeWithVmafAsync(
    string sourcePath,
    string encodedPath,
    string logPath,
    VideoSegment segment)
{
    var startInfo = new ProcessStartInfo
    {
        FileName = "ffmpeg",
        RedirectStandardError = true,
        UseShellExecute = false
    };
    var arguments = new List<string>
    {
        "-hide_banner", "-nostdin", "-v", "error", "-y",
        "-ss", segment.StartSeconds.ToString(CultureInfo.InvariantCulture),
        "-t", segment.DurationSeconds.ToString(CultureInfo.InvariantCulture),
        "-i", sourcePath,
        "-map", "0:v:0", "-an",
        "-c:v", Required("VIDEO_CODEC"),
        "-preset", Required("PRESET"),
        "-crf", Required("CRF")
    };
    var maxVideoBitrateKbps = int.Parse(Required("MAX_VIDEO_BITRATE_KBPS"));
    if (maxVideoBitrateKbps > 0)
    {
        arguments.AddRange(new[]
        {
            "-maxrate", $"{maxVideoBitrateKbps}k",
            "-bufsize", $"{2 * maxVideoBitrateKbps}k"
        });
    }
    arguments.AddRange(new[]
    {
        "-fps_mode", "passthrough",
        "-movflags", "+faststart",
        "-avoid_negative_ts", "make_zero",
        encodedPath,
        "-dec", "0:0",
        "-filter_complex", $"[dec:0]setpts=PTS-STARTPTS[distorted];[0:v]setpts=PTS-STARTPTS[reference];[distorted][reference]libvmaf=model=path=/opt/ffmpeg/share/vmaf/vmaf_v0.6.1.json:log_fmt=json:log_path={logPath}[vmaf]",
        "-map", "[vmaf]", "-f", "null", "-"
    });
    foreach (var argument in arguments)
        startInfo.ArgumentList.Add(argument);

    using var process = Process.Start(startInfo)
        ?? throw new InvalidOperationException("Failed to start FFmpeg encoding with VMAF");
    var error = await process.StandardError.ReadToEndAsync();
    await process.WaitForExitAsync();
    if (process.ExitCode != 0)
        throw new InvalidOperationException($"FFmpeg encoding with VMAF failed: {error}");
}

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