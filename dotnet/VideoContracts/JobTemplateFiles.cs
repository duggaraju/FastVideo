namespace Video.Contracts;

public static class JobTemplateFiles
{
    public const string DirectoryPath = "/etc/video/job-templates";

    public static string PathFor(string role, string mediaRuntime, string? capacityClass)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(role);
        var normalizedCapacityClass = CapacityClasses.Normalize(capacityClass);
        var capacityClassSuffix = normalizedCapacityClass is null ? "" : $"-{normalizedCapacityClass}";
        return System.IO.Path.Combine(
            DirectoryPath,
            $"{role}-{NormalizeMediaRuntime(mediaRuntime)}{capacityClassSuffix}.yaml");
    }

    public static string NormalizeMediaRuntime(string? mediaRuntime) => mediaRuntime?.Trim().ToLowerInvariant() switch
    {
        "dotnet" => "dotnet",
        "rust" => "rust",
        _ => throw new ArgumentException("MediaRuntime must be dotnet or rust", nameof(mediaRuntime))
    };
}
