using System.Security.Cryptography;
using System.Text;

namespace SpotVideo.Contracts;

public static class JobNames
{
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