namespace SpotVideo.Contracts;

public sealed record VideoSubmitted(
    string JobId,
    Uri InputVideoUri,
    Uri OutputVideoUri,
    int SegmentDurationSeconds = 60,
    string VideoCodec = "libsvtav1",
    string AudioCodec = "copy",
    string? Preset = null,
    int? Crf = null,
    int? MaxVideoBitrateKbps = null,
    bool UseSpot = true,
    bool CalculateVmaf = false,
    string? ParallelizationStrategy = null);

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
    int MaxVideoBitrateKbps,
    bool UseSpot,
    bool CalculateVmaf);

public sealed record VideoSegment(
    int Index,
    double StartSeconds,
    double DurationSeconds);

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
    DateTimeOffset CompletedAt,
    double? VmafScore = null);

public sealed record SegmentVmaf(
    int Index,
    double Score);

public sealed record VideoVmaf(
    double Score,
    IReadOnlyList<SegmentVmaf> Segments);