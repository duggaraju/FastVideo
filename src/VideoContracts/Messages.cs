namespace SpotVideo.Contracts;

public sealed record VideoSubmitted(
    string JobId,
    Uri InputVideoUri,
    Uri OutputVideoUri,
    int SegmentDurationSeconds = 60,
    string VideoCodec = "libx264",
    string AudioCodec = "copy",
    string Preset = "medium",
    int Crf = 23);

public sealed record VideoManifest(
    string JobId,
    Uri InputVideoUri,
    Uri OutputVideoUri,
    string WorkingContainer,
    string AudioBlobName,
    TimeSpan Duration,
    int SegmentDurationSeconds,
    int SegmentCount,
    IReadOnlyList<VideoSegment> Segments,
    string VideoCodec,
    string AudioCodec,
    string Preset,
    int Crf);

public sealed record VideoSegment(
    int Index,
    double StartSeconds,
    double DurationSeconds);

public sealed record SegmentEncoded(
    string JobId,
    int SegmentIndex,
    int SegmentCount,
    string WorkingContainer,
    string BlobName,
    string AudioBlobName,
    Uri OutputVideoUri,
    long Length,
    string Sha256,
    DateTimeOffset CompletedAt);

public sealed record VideoStitched(
    string JobId,
    Uri OutputVideoUri,
    long Length,
    DateTimeOffset CompletedAt);