using System.Security.Cryptography;
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
var index = int.Parse(Required("JOB_COMPLETION_INDEX"));
var sourceUri = new Uri(Required("SOURCE_VIDEO_URI"));
var inputPath = Path.Combine(Path.GetTempPath(), $"source-{jobId}");
var outputPath = Path.Combine(Path.GetTempPath(), $"segment-{index:D6}.mp4");
var source = string.IsNullOrEmpty(sourceUri.Query) ? new BlobClient(sourceUri, credential) : new BlobClient(sourceUri);
await source.DownloadToAsync(inputPath);

var storage = new BlobServiceClient(new Uri(Required("STORAGE_SERVICE_URI")), credential);
var outputContainer = Required("OUTPUT_CONTAINER");
var manifestBlob = storage.GetBlobContainerClient(outputContainer).GetBlobClient($"{jobId}/manifest.json");
var manifest = (await manifestBlob.DownloadContentAsync()).Value.Content.ToObjectFromJson<VideoManifest>()
    ?? throw new InvalidOperationException("Manifest payload is empty");
var segmentCount = manifest.SegmentCount;
if (index < 0 || index >= segmentCount)
    throw new InvalidOperationException($"Completion index {index} is outside segment count {segmentCount}");
var segment = manifest.Segments.SingleOrDefault(item => item.Index == index)
    ?? throw new InvalidOperationException($"Segment definition for index {index} was not found");

var start = TimeSpan.FromSeconds(segment.StartSeconds);
await FFMpegArguments
    .FromFileInput(inputPath, false, options => options.Seek(start))
    .OutputToFile(outputPath, true, options => options
        .WithDuration(TimeSpan.FromSeconds(segment.DurationSeconds))
        .WithVideoCodec(Required("VIDEO_CODEC"))
        .WithCustomArgument($"-an -preset {Required("PRESET")} -crf {Required("CRF")} -movflags +faststart -avoid_negative_ts make_zero"))
    .ProcessAsynchronously();

var blobName = $"{jobId}/segments/{index:D6}.mp4";
var outputBlob = storage.GetBlobContainerClient(outputContainer).GetBlobClient(blobName);
await outputBlob.UploadAsync(outputPath, overwrite: true);
var fileInfo = new FileInfo(outputPath);
await using var stream = File.OpenRead(outputPath);
var hash = Convert.ToHexString(await SHA256.HashDataAsync(stream)).ToLowerInvariant();

await using var serviceBus = new ServiceBusClient(Required("SERVICE_BUS_NAMESPACE"), credential);
await using var sender = serviceBus.CreateSender(Required("COMPLETION_QUEUE"));
var completion = new SegmentEncoded(
    jobId,
    index,
    segmentCount,
    outputContainer,
    blobName,
    Required("AUDIO_BLOB_NAME"),
    new Uri(Required("OUTPUT_VIDEO_URI")),
    fileInfo.Length,
    hash,
    DateTimeOffset.UtcNow);
var message = new ServiceBusMessage(BinaryData.FromObjectAsJson(completion))
{
    MessageId = $"{jobId}:{index}",
    CorrelationId = jobId,
    Subject = nameof(SegmentEncoded)
};
await sender.SendMessageAsync(message);

static string Required(string name) =>
    Environment.GetEnvironmentVariable(name) ?? throw new InvalidOperationException($"{name} is required");