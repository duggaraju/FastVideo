using System.Security.Cryptography;
using System.Text;

namespace Video.Contracts;

public static class JobNames
{
    public const string ArchitectureAnnotation = "video/architecture";
    public const string JobIdAnnotation = "video/job-id";
    public const string StageIdAnnotation = "video/stage-id";
    public const string UseSpotAnnotation = "video/use-spot";
    public const string SegmentCountAnnotation = "video/segment-count";
    public const string AudioBlobNameAnnotation = "video/audio-blob-name";
    public const string OutputVideoUriAnnotation = "video/output-video-uri";
    public const string CalculateVmafAnnotation = "video/calculate-vmaf";
    public const string MediaRuntimeAnnotation = "video/media-runtime";
    public const string ResultReportedAnnotation = "video/result-reported";

    public static string For(string prefix, string jobId) => $"{prefix}-{LabelValue(jobId)}";

    public static string LabelValue(string value)
    {
        var normalized = new string(value.ToLowerInvariant()
            .Select(character => char.IsAsciiLetterOrDigit(character) || character is '-' or '.' ? character : '-')
            .ToArray()).Trim('-', '.');
        var hash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value)))[..10].ToLowerInvariant();
        var available = 52 - hash.Length;
        return $"{normalized[..Math.Min(normalized.Length, available)].TrimEnd('-', '.')}-{hash}";
    }
}