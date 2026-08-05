using Azure.Data.Tables;
using Azure.Identity;
using Azure.Messaging.ServiceBus;
using FFMpegCore;
using SpotVideo.Contracts;

GlobalFFOptions.Configure(options =>
{
    options.BinaryFolder = "/usr/bin";
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
var state = new TableClient(new Uri(Required("TABLE_SERVICE_URI")), Required("STATE_TABLE"), credential);
var filter = TableClient.CreateQueryFilter($"PartitionKey eq {jobId} and RowKey ge {"segment-"} and RowKey lt {"segment."}");
var segments = new List<(int Index, string BlobName)>();
await foreach (var entity in state.QueryAsync<TableEntity>(filter))
    segments.Add((entity.GetInt32("SegmentIndex")!.Value, entity.GetString("BlobName")!));
if (segments.Count != segmentCount)
    throw new InvalidOperationException($"Expected {segmentCount} segments but found {segments.Count}");

var jobDirectory = BlobMountPaths.FromBlobName(jobId, outputMountPath);
var workingDirectory = Path.Combine(jobDirectory, "_stitch");
Directory.CreateDirectory(workingDirectory);
var stitchCompleted = false;
try
{
    var paths = new List<string>(segmentCount);
    foreach (var segment in segments.OrderBy(segment => segment.Index))
    {
        paths.Add(BlobMountPaths.FromBlobName(segment.BlobName, outputMountPath));
    }

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
        .OutputToFile(outputPath, true, options => options.WithCustomArgument("-map 0:v:0 -map 1:a:0 -c:v copy -c:a copy -shortest -movflags +faststart"))
        .ProcessAsynchronously();
    var length = new FileInfo(outputPath).Length;

    await using var serviceBus = new ServiceBusClient(Required("SERVICE_BUS_NAMESPACE"), credential);
    await using var sender = serviceBus.CreateSender(Required("STITCHED_QUEUE"));
    var completed = new VideoStitched(jobId, outputVideoUri, length, DateTimeOffset.UtcNow);
    var message = new ServiceBusMessage(BinaryData.FromObjectAsJson(completed))
    {
        MessageId = $"{jobId}:stitched",
        CorrelationId = jobId,
        Subject = nameof(VideoStitched)
    };
    await sender.SendMessageAsync(message);
    stitchCompleted = true;
    await DeleteIntermediateFilesAsync(
        paths.Append(audioPath)
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