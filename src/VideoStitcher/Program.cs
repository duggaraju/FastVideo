using Azure.Data.Tables;
using Azure.Identity;
using Azure.Messaging.ServiceBus;
using Azure.Storage.Blobs;
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
var outputContainer = Required("OUTPUT_CONTAINER");
var audioBlobName = Required("AUDIO_BLOB_NAME");
var outputVideoUri = new Uri(Required("OUTPUT_VIDEO_URI"));
var state = new TableClient(new Uri(Required("TABLE_SERVICE_URI")), Required("STATE_TABLE"), credential);
var filter = TableClient.CreateQueryFilter($"PartitionKey eq {jobId} and RowKey ge {"segment-"} and RowKey lt {"segment."}");
var segments = new List<(int Index, string BlobName)>();
await foreach (var entity in state.QueryAsync<TableEntity>(filter))
    segments.Add((entity.GetInt32("SegmentIndex")!.Value, entity.GetString("BlobName")!));
if (segments.Count != segmentCount)
    throw new InvalidOperationException($"Expected {segmentCount} segments but found {segments.Count}");

var storage = new BlobServiceClient(new Uri(Required("STORAGE_SERVICE_URI")), credential);
var container = storage.GetBlobContainerClient(outputContainer);
var workingDirectory = Directory.CreateTempSubdirectory($"stitch-{JobNames.LabelValue(jobId)}-");
try
{
    var paths = new List<string>(segmentCount);
    foreach (var segment in segments.OrderBy(segment => segment.Index))
    {
        var path = Path.Combine(workingDirectory.FullName, $"{segment.Index:D6}.mp4");
        await container.GetBlobClient(segment.BlobName).DownloadToAsync(path);
        paths.Add(path);
    }

    var stitchedVideoPath = Path.Combine(workingDirectory.FullName, "stitched-video.mp4");
    await Task.Run(() => FFMpeg.Join(stitchedVideoPath, paths.ToArray()));
    var audioPath = Path.Combine(workingDirectory.FullName, "audio.m4a");
    await container.GetBlobClient(audioBlobName).DownloadToAsync(audioPath);

    var outputPath = Path.Combine(workingDirectory.FullName, "complete.mp4");
    await FFMpegArguments
        .FromFileInput(stitchedVideoPath)
        .AddFileInput(audioPath)
        .OutputToFile(outputPath, true, options => options.WithCustomArgument("-map 0:v:0 -map 1:a:0 -c:v copy -c:a copy -shortest -movflags +faststart"))
        .ProcessAsynchronously();

    var finalBlob = string.IsNullOrEmpty(outputVideoUri.Query)
        ? new BlobClient(outputVideoUri, credential)
        : new BlobClient(outputVideoUri);
    await finalBlob.UploadAsync(outputPath, overwrite: true);
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
    workingDirectory.Delete(recursive: true);
}

static string Required(string name) =>
    Environment.GetEnvironmentVariable(name) ?? throw new InvalidOperationException($"{name} is required");