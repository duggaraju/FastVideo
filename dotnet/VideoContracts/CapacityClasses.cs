namespace Video.Contracts;

public static class CapacityClasses
{
    public const string Interruptible = "interruptible";
    public const string Regular = "regular";
    public const string AnnotationName = "video.fastvideo/capacity-class";

    public static string? Normalize(string? value) => value?.Trim().ToLowerInvariant() switch
    {
        null or "" => null,
        Interruptible => Interruptible,
        Regular => Regular,
        _ => throw new ArgumentException("CapacityClass must be interruptible or regular", nameof(value))
    };
}