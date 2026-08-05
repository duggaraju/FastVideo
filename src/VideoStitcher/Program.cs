using System.Text.Json;
using Azure.Identity;
using Azure.Messaging.ServiceBus;
using FFMpegCore;
using SpotVideo.Contracts;

GlobalFFOptions.Configure(options =>
{
    options.BinaryFolder = Environment.GetEnvironmentVariable("FFMPEG_BINARY_FOLDER")
        ?? (Directory.Exists("/opt/ffmpeg/bin") ? "/opt/ffmpeg/bin" : "/usr/bin");
    options.TemporaryFilesFolder = "/tmp";
});

var credential = new DefaultAzureCredential();
var jobId = Required("JOB_ID");
var segmentCount = int.Parse(Required("SEGMENT_COUNT"));
var outputMountPath = Required("OUTPUT_MOUNT_PATH");
var audioBlobName = Required("AUDIO_BLOB_NAME");
var outputVideoUri = new Uri(Required("OUTPUT_VIDEO_URI"));
var outputStorageAccountName = Required("OUTPUT_STORAGE_ACCOUNT_NAME");
var outputStorageContainer = Required("OUTPUT_STORAGE_CONTAINER");
var calculateVmaf = bool.Parse(Required("CALCULATE_VMAF"));
var jobDirectory = BlobMountPaths.FromBlobName(jobId, outputMountPath);
var workingDirectory = Path.Combine(jobDirectory, "_stitch");
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
    double? vmafScore = calculateVmaf
        ? (await Task.WhenAll(vmafPaths.Select(ReadVmafAsync))).Average(result => result.Score)
        : null;

    var stitchedVideoPath = Path.Combine(workingDirectory, "stitched-video.mp4");
    var concatListPath = Path.Combine(workingDirectory, "segments.txt");
    await File.WriteAllLinesAsync(
        concatListPath,
        paths.Select(path => $"file '{path.Replace("'", "'\\''")}'"));
    await FFMpegArguments
        .FromFileInput(concatListPath, false, options => options.WithCustomArgument("-f concat -safe 0"))
        .OutputToFile(stitchedVideoPath, false, options => options.WithCustomArgument("-c copy -movflags +faststart"))
        .ProcessAsynchronously();
    var audioPath = BlobMountPaths.FromBlobName(audioBlobName, outputMountPath);

    var outputPath = BlobMountPaths.FromUri(
        outputVideoUri,
        outputStorageAccountName,
        outputStorageContainer,
        outputMountPath);
    Directory.CreateDirectory(Path.GetDirectoryName(outputPath)!);
    await FFMpegArguments
        .FromFileInput(stitchedVideoPath)
        .AddFileInput(audioPath)
        .OutputToFile(outputPath, true, options => options.WithCustomArgument("-map 0:v:0 -map 1:a:0 -c:v copy -c:a copy -movflags +faststart"))
        .ProcessAsynchronously();
    var length = new FileInfo(outputPath).Length;
    if (vmafScore is not null)
    {
        var outputVmafPath = Path.ChangeExtension(outputPath, ".vmaf.json");
        await File.WriteAllBytesAsync(
            outputVmafPath,
            JsonSerializer.SerializeToUtf8Bytes(new { Score = vmafScore.Value }));
    }

    await using var serviceBus = new ServiceBusClient(Required("SERVICE_BUS_NAMESPACE"), credential);
    await using var sender = serviceBus.CreateSender(Required("STITCHED_QUEUE"));
    var completed = new VideoStitched(jobId, outputVideoUri, length, DateTimeOffset.UtcNow, vmafScore);
    var message = new ServiceBusMessage(BinaryData.FromObjectAsJson(completed))
    {
        MessageId = $"{jobId}:stitched",
        CorrelationId = jobId,
        Subject = nameof(VideoStitched)
    };
    await sender.SendMessageAsync(message);
    stitchCompleted = true;
    await DeleteIntermediateFilesAsync(
        paths.Concat(vmafPaths).Append(audioPath)
            .Append(Path.Combine(jobDirectory, "manifest.json"))
            .Append(concatListPath)
            .Append(stitchedVideoPath),
        jobDirectory);
}
finally
{
    if (!stitchCompleted)
        await DeleteDirectoryAsync(workingDirectory);
}

static string Required(string name) =>
    Environment.GetEnvironmentVariable(name) ?? throw new InvalidOperationException($"{name} is required");

static async Task<SegmentVmaf> ReadVmafAsync(string path)
{
    await using var stream = File.OpenRead(path);
    return await JsonSerializer.DeserializeAsync<SegmentVmaf>(stream)
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