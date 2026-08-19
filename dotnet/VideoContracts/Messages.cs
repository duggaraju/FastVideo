namespace Video.Contracts;

public static class VideoOutputTypes
{
    public const string Mp4 = "mp4";
    public const string Cmaf = "cmaf";
    public const string Both = "both";

    public static string Normalize(string? value) => value?.ToLowerInvariant() switch
    {
        null or "" or Mp4 => Mp4,
        Cmaf => Cmaf,
        Both => Both,
        _ => throw new ArgumentException("OutputType must be mp4, cmaf, or both", nameof(value))
    };
}

public sealed record VideoSubmitted(
    string JobId,
    Uri InputVideoUri,
    Uri OutputPath,
    int SegmentDurationSeconds = 60,
    string VideoCodec = "libsvtav1",
    string AudioCodec = "copy",
    string? Preset = null,
    int? Crf = null,
    int? MaxVideoBitrateKbps = null,
    bool UseSpot = true,
    bool CalculateVmaf = false,
    string? MediaRuntime = null,
    string? ParallelizationStrategy = null,
    string? Architecture = null,
    string OutputType = "mp4");

public sealed record VideoManifest(
    string JobId,
    Uri InputVideoUri,
    Uri OutputPath,
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
    bool CalculateVmaf,
    string MediaRuntime,
    string OutputType);

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

public sealed record SegmentVmaf(
    int Index,
    double Score);

public sealed record VideoVmaf(
    double Score,
    IReadOnlyList<SegmentVmaf> Segments);