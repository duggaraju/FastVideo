using System.Security.Cryptography;
using System.Text.Json;
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
var index = int.Parse(Required("JOB_COMPLETION_INDEX"));
var sourceUri = new Uri(Required("SOURCE_VIDEO_URI"));
var inputPath = BlobMountPaths.FromUri(
    sourceUri,
    Required("INPUT_STORAGE_ACCOUNT_NAME"),
    Required("INPUT_STORAGE_CONTAINER"),
    Required("INPUT_MOUNT_PATH"));
var outputMountPath = Required("OUTPUT_MOUNT_PATH");
var outputContainer = Required("OUTPUT_CONTAINER");
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
Directory.CreateDirectory(Path.GetDirectoryName(outputPath)!);

var start = TimeSpan.FromSeconds(segment.StartSeconds);
await FFMpegArguments
    .FromFileInput(inputPath, false, options => options.Seek(start))
    .OutputToFile(outputPath, true, options => options
        .WithDuration(TimeSpan.FromSeconds(segment.DurationSeconds))
        .WithVideoCodec(Required("VIDEO_CODEC"))
        .WithCustomArgument($"-an -preset {Required("PRESET")} -crf {Required("CRF")} -movflags +faststart -avoid_negative_ts make_zero"))
    .ProcessAsynchronously();

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