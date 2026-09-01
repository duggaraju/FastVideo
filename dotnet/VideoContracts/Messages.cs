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

public static class VideoLadderPresets
{
    public const string Max4K = "max4k";
    public const string Max1440P = "max1440p";
    public const string Max1080P = "max1080p";
    public const string Max720P = "max720p";
    public const string Max480P = "max480p";
    public const string Max360P = "max360p";

    public static bool IsLadder(string? value) => TryGetMaximumHeight(value, out _);

    public static bool TryGetMaximumHeight(string? value, out int height)
    {
        var normalized = value?.Trim().ToLowerInvariant();
        if (normalized == Max4K)
        {
            height = 2160;
            return true;
        }
        if (normalized is not null && normalized.StartsWith("max", StringComparison.Ordinal) && normalized.EndsWith('p') &&
            int.TryParse(normalized.AsSpan(3, normalized.Length - 4), out height) && height > 0)
        {
            return true;
        }
        height = 0;
        return false;
    }
}

public sealed record VideoSubmitted(
    string JobId,
    Uri InputVideoUri,
    Uri OutputPath,
    int SegmentDurationSeconds = 60,
    string VideoCodec = "libsvtav1",
    string AudioCodec = "copy",
    string? Preset = null,
    string? EncoderPreset = null,
    int? Crf = null,
    int? MaxVideoBitrateKbps = null,
    string? CapacityClass = null,
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
    string? Preset,
    IReadOnlyList<VideoEncodingProfile> EncodingProfiles,
    string? CapacityClass,
    bool CalculateVmaf,
    string MediaRuntime,
    string OutputType);

public sealed record VideoEncodingProfile(
    string Name,
    int Width,
    int Height,
    string EncoderPreset,
    int Crf,
    int MaxVideoBitrateKbps);

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