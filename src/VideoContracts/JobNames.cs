using System.Security.Cryptography;
using System.Text;

namespace SpotVideo.Contracts;

public static class JobNames
{
    public const string BenchmarkArchitectureProperty = "spotvideo-benchmark-architecture";
    public const string ArchitectureAnnotation = "spotvideo/architecture";
    public const string JobIdAnnotation = "spotvideo/job-id";
    public const string StageIdAnnotation = "spotvideo/stage-id";
    public const string UseSpotAnnotation = "spotvideo/use-spot";
    public const string SegmentCountAnnotation = "spotvideo/segment-count";
    public const string AudioBlobNameAnnotation = "spotvideo/audio-blob-name";
    public const string OutputVideoUriAnnotation = "spotvideo/output-video-uri";
    public const string CalculateVmafAnnotation = "spotvideo/calculate-vmaf";
    public const string ResultReportedAnnotation = "spotvideo/result-reported";

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