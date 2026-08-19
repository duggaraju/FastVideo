using FFMpegCore;
using Video.Contracts;

GlobalFFOptions.Configure(options =>
{
    options.BinaryFolder = Environment.GetEnvironmentVariable("FFMPEG_BINARY_FOLDER")
        ?? (Directory.Exists("/opt/ffmpeg/bin") ? "/opt/ffmpeg/bin" : "/usr/bin");
    options.TemporaryFilesFolder = "/tmp";
});

var jobId = Required("JOB_ID");
var sourceUri = new Uri(Required("SOURCE_VIDEO_URI"));
var inputPath = BlobMountPaths.FromUri(
    sourceUri,
    Required("INPUT_STORAGE_ACCOUNT_NAME"),
    Required("INPUT_STORAGE_CONTAINER"),
    Required("INPUT_MOUNT_PATH"));
var outputPath = BlobMountPaths.FromBlobName(Required("AUDIO_BLOB_NAME"), Required("OUTPUT_MOUNT_PATH"));
if (File.Exists(outputPath))
    return;

Directory.CreateDirectory(Path.GetDirectoryName(outputPath)!);
var stagingDirectory = BlobMountPaths.FromBlobName($"{jobId}/segments/.staging", Required("OUTPUT_MOUNT_PATH"));
var stagingPath = Path.Combine(stagingDirectory, $"audio-{Guid.NewGuid():N}.m4a");
Directory.CreateDirectory(stagingDirectory);
try
{
    await FFMpegArguments
        .FromFileInput(inputPath)
        .OutputToFile(stagingPath, true, options => options
            .WithCustomArgument("-map 0:a:0 -vn -sn -dn")
            .WithAudioCodec(Required("AUDIO_CODEC")))
        .ProcessAsynchronously();
    try
    {
        File.Move(stagingPath, outputPath, false);
    }
    catch (IOException) when (File.Exists(outputPath))
    {
    }
}
finally
{
    File.Delete(stagingPath);
}

static string Required(string name) =>
    Environment.GetEnvironmentVariable(name) ?? throw new InvalidOperationException($"{name} is required");