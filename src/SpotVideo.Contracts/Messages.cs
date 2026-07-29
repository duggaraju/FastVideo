namespace SpotVideo.Contracts;

public sealed record VideoSubmitted(
    string JobId,
    Uri SourceBlobUri,
    string OutputContainer,
    int SegmentDurationSeconds = 60,
    string VideoCodec = "libx264",
    string AudioCodec = "aac",
    string Preset = "medium",
    int Crf = 23);

public sealed record VideoManifest(
    string JobId,
    Uri SourceBlobUri,
    string OutputContainer,
    TimeSpan Duration,
    int SegmentDurationSeconds,
    int SegmentCount,
    string VideoCodec,
    string AudioCodec,
    string Preset,
    int Crf);

public sealed record SegmentEncoded(
    string JobId,
    int SegmentIndex,
    int SegmentCount,
    string OutputContainer,
    string BlobName,
    long Length,
    string Sha256,
    DateTimeOffset CompletedAt);

public sealed record VideoStitched(
    string JobId,
    string BlobName,
    long Length,
    DateTimeOffset CompletedAt);