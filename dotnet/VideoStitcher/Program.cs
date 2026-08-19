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
var segmentCount = int.Parse(Required("SEGMENT_COUNT"));
var outputMountPath = Required("OUTPUT_MOUNT_PATH");
var audioBlobName = Required("AUDIO_BLOB_NAME");
var outputUri = new Uri(Required("OUTPUT_PATH"));
var outputType = VideoOutputTypes.Normalize(Required("OUTPUT_TYPE"));
var outputStorageAccountName = Required("OUTPUT_STORAGE_ACCOUNT_NAME");
var outputStorageContainer = Required("OUTPUT_STORAGE_CONTAINER");
var calculateVmaf = bool.Parse(Required("CALCULATE_VMAF"));
var jobDirectory = BlobMountPaths.FromBlobName(jobId, outputMountPath);
var workingDirectory = Path.Combine(jobDirectory, "_stitch");
var packageDirectory = Path.Combine(Path.GetTempPath(), "video-stitcher", jobId, "package");
Directory.CreateDirectory(workingDirectory);
var stitchCompleted = false;
try
{
    var paths = Enumerable.Range(0, segmentCount)
        .Select(index => BlobMountPaths.FromBlobName($"{jobId}/segments/{index:D6}.mp4", outputMountPath))
        .ToList();
    var missingPaths = paths.Where(path => !File.Exists(path)).ToList();
    if (missingPaths.Count > 0)
        throw new InvalidOperationException($"Expected {segmentCount} segments but {missingPaths.Count} files are missing");
    var vmafPaths = calculateVmaf
        ? Enumerable.Range(0, segmentCount)
            .Select(index => BlobMountPaths.FromBlobName($"{jobId}/segments/{index:D6}.vmaf.json", outputMountPath))
            .ToList()
        : [];
    var missingVmafPaths = vmafPaths.Where(path => !File.Exists(path)).ToList();
    if (missingVmafPaths.Count > 0)
        throw new InvalidOperationException($"Expected {segmentCount} VMAF results but {missingVmafPaths.Count} files are missing");
    var segmentVmafScores = calculateVmaf
        ? (await Task.WhenAll(vmafPaths.Select(ReadVmafAsync))).OrderBy(result => result.Index).ToList()
        : [];
    double? vmafScore = calculateVmaf ? segmentVmafScores.Average(result => result.Score) : null;

    var concatListPath = Path.Combine(workingDirectory, "segments.txt");
    await File.WriteAllLinesAsync(
        concatListPath,
        paths.Select(path => $"file '{Path.GetFullPath(path).Replace("'", "'\\''")}'"));
    var audioPath = BlobMountPaths.FromBlobName(audioBlobName, outputMountPath);

    var outputBasePath = BlobMountPaths.FromUri(
        outputUri,
        outputStorageAccountName,
        outputStorageContainer,
        outputMountPath);
    Directory.CreateDirectory(Path.GetDirectoryName(outputBasePath)!);
    await StitchAsync(concatListPath, audioPath, outputBasePath, packageDirectory, outputType);
    if (vmafScore is not null)
    {
        var outputVmafPath = $"{outputBasePath}.vmaf.json";
        await File.WriteAllBytesAsync(
            outputVmafPath,
            JsonSerializer.SerializeToUtf8Bytes(new VideoVmaf(vmafScore.Value, segmentVmafScores)));
    }

    stitchCompleted = true;
    await DeleteIntermediateFilesAsync(
        paths.Concat(vmafPaths).Append(audioPath)
            .Append(Path.Combine(jobDirectory, "manifest.json"))
            .Append(concatListPath),
        jobDirectory);
}
finally
{
    await DeleteDirectoryAsync(packageDirectory);
    if (!stitchCompleted)
        await DeleteDirectoryAsync(workingDirectory);
}

static string Required(string name) =>
    Environment.GetEnvironmentVariable(name) ?? throw new InvalidOperationException($"{name} is required");

static async Task StitchAsync(string concatListPath, string audioPath, string outputBasePath, string packageDirectory, string outputType)
{
    var arguments = FFMpegArguments
        .FromFileInput(concatListPath, false, options => options.WithCustomArgument("-f concat -safe 0"))
        .AddFileInput(audioPath);
    if (outputType == VideoOutputTypes.Mp4)
    {
        await arguments
            .OutputToFile($"{outputBasePath}.mp4", true, ConfigureMp4Output)
            .ProcessAsynchronously();
        return;
    }

    Directory.CreateDirectory(packageDirectory);
    var baseName = Path.GetFileName(outputBasePath);
    var cmafManifestPath = Path.Combine(packageDirectory, $"{baseName}.mpd");
    if (outputType == VideoOutputTypes.Cmaf)
    {
        var cmafArguments = arguments
            .OutputToFile(cmafManifestPath, true, options => ConfigureCmafOutput(options, baseName));
        await cmafArguments
            .Configure(options => options.WorkingDirectory = Path.GetFullPath(packageDirectory))
            .ProcessAsynchronously();
    }
    else
    {
        var multiOutputArguments = arguments.MultiOutput(outputs =>
        {
            outputs.OutputToFile($"{outputBasePath}.mp4", true, ConfigureMp4Output);
            outputs.OutputToFile(cmafManifestPath, true, options => ConfigureCmafOutput(options, baseName));
        });
        await multiOutputArguments
            .Configure(options => options.WorkingDirectory = Path.GetFullPath(packageDirectory))
            .ProcessAsynchronously();
    }

    RenameHlsMediaPlaylists(packageDirectory, baseName);
    foreach (var packagePath in Directory.EnumerateFiles(packageDirectory))
    {
        var outputPath = Path.Combine(Path.GetDirectoryName(outputBasePath)!, Path.GetFileName(packagePath));
        await using var source = File.OpenRead(packagePath);
        await using var destination = File.Create(outputPath);
        await source.CopyToAsync(destination);
    }
}

static void ConfigureMp4Output(FFMpegArgumentOptions options)
{
    options
        .WithCustomArgument("-map 0:v:0 -map 1:a:0 -c copy")
        .WithFastStart();
}

static void ConfigureCmafOutput(FFMpegArgumentOptions options, string baseName)
{
    options
        .WithCustomArgument("-map 0:v:0 -map 1:a:0 -c copy")
        .ForceFormat("dash")
        .WithCustomArgument("-seg_duration 6")
        .WithCustomArgument("-use_template 1")
        .WithCustomArgument("-use_timeline 1")
        .WithCustomArgument("-dash_segment_type mp4")
        .WithCustomArgument("-single_file 1")
        .WithCustomArgument($"-single_file_name {baseName}-stream$RepresentationID$.cmaf")
        .WithCustomArgument("-adaptation_sets \"id=0,streams=v id=1,streams=a\"")
        .WithCustomArgument("-hls_playlist 1")
        .WithCustomArgument($"-hls_master_name {baseName}.m3u8");
}

static void RenameHlsMediaPlaylists(string packageDirectory, string baseName)
{
    var masterPath = Path.Combine(packageDirectory, $"{baseName}.m3u8");
    var masterContent = File.ReadAllText(masterPath);
    foreach (var mediaPath in Directory.EnumerateFiles(packageDirectory, "media_*.m3u8"))
    {
        var originalName = Path.GetFileName(mediaPath);
        var representationId = Path.GetFileNameWithoutExtension(mediaPath)["media_".Length..];
        var renamedName = $"{baseName}-stream{representationId}.m3u8";
        File.Move(mediaPath, Path.Combine(packageDirectory, renamedName));
        masterContent = masterContent.Replace(originalName, renamedName, StringComparison.Ordinal);
    }
    File.WriteAllText(masterPath, masterContent);
}

static async Task<SegmentVmaf> ReadVmafAsync(string path)
{
    await using var stream = File.OpenRead(path);
    return await JsonSerializer.DeserializeAsync<SegmentVmaf>(stream, JsonSerializerOptions.Web)
        ?? throw new InvalidOperationException($"VMAF result {path} is empty");
}

static async Task DeleteIntermediateFilesAsync(IEnumerable<string> paths, string jobDirectory)
{
    foreach (var path in paths.Distinct(StringComparer.Ordinal))
    {
        try
        {
            File.Delete(path);
        }
        catch (IOException exception)
        {
            Console.Error.WriteLine($"Could not delete intermediate file {path}: {exception.Message}");
        }
    }

    await DeleteDirectoryAsync(jobDirectory);
}

static async Task DeleteDirectoryAsync(string path)
{
    for (var attempt = 0; attempt < 3 && Directory.Exists(path); attempt++)
    {
        try
        {
            Directory.Delete(path, recursive: true);
        }
        catch (IOException) when (attempt < 2)
        {
            await Task.Delay(TimeSpan.FromSeconds(1));
        }
        catch (DirectoryNotFoundException)
        {
            return;
        }
        catch (IOException)
        {
            return;
        }
    }
}