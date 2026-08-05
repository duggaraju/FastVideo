namespace SpotVideo.Contracts;

public sealed record VideoSubmitted(
    string JobId,
    Uri InputVideoUri,
    Uri OutputVideoUri,
    int SegmentDurationSeconds = 20,
    string VideoCodec = "libsvtav1",
    string AudioCodec = "copy",
    string? Preset = null,
    int? Crf = null,
    int? MaxVideoBitrateKbps = null);

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
    int Crf,
    int MaxVideoBitrateKbps);

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

public sealed record VideoProcessingResult(
    string JobId,
    bool Succeeded,
    string TerminalStage,
    string? FailedIndexes,
    string? FailureReason,
    DateTimeOffset CompletedAt);

public sealed record VideoStitched(
    string JobId,
    Uri OutputVideoUri,
    long Length,
    DateTimeOffset CompletedAt);