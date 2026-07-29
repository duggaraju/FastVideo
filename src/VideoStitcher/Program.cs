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
var state = new TableClient(new Uri(Required("TABLE_SERVICE_URI")), Required("STATE_TABLE"), credential);
var filter = TableClient.CreateQueryFilter($"PartitionKey eq {jobId} and RowKey ge {"segment-"} and RowKey lt {"segment."}");
var segments = new List<(int Index, string BlobName)>();
await foreach (var entity in state.QueryAsync<TableEntity>(filter))
    segments.Add((entity.GetInt32("SegmentIndex")!.Value, entity.GetString("BlobName")!));
if (segments.Count != segmentCount)
    throw new InvalidOperationException($"Expected {segmentCount} segments but found {segments.Count}");

var workingDirectory = BlobMountPaths.FromBlobName($"{jobId}/_stitch", outputMountPath);
Directory.CreateDirectory(workingDirectory);
try
{
    var paths = new List<string>(segmentCount);
    foreach (var segment in segments.OrderBy(segment => segment.Index))
    {
        paths.Add(BlobMountPaths.FromBlobName(segment.BlobName, outputMountPath));
    }

    var stitchedVideoPath = Path.Combine(workingDirectory, "stitched-video.mp4");
    await Task.Run(() => FFMpeg.Join(stitchedVideoPath, paths.ToArray()));
    var audioPath = BlobMountPaths.FromBlobName(audioBlobName, outputMountPath);

    var outputPath = BlobMountPaths.FromUri(
        outputVideoUri,
        Required("OUTPUT_STORAGE_ACCOUNT_NAME"),
        Required("OUTPUT_STORAGE_CONTAINER"),
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
}
finally
{
    Directory.Delete(workingDirectory, recursive: true);
}

static string Required(string name) =>
    Environment.GetEnvironmentVariable(name) ?? throw new InvalidOperationException($"{name} is required");