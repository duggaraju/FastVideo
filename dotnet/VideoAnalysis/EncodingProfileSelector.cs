using FFMpegCore;

namespace Video.Analysis;

public sealed record EncodingProfile(string Preset, int Crf, int MaxVideoBitrateKbps);

public static class EncodingProfileSelector
{
    public static EncodingProfile Select(VideoStream source, string targetVideoCodec, string? preset, int? crf, int? maxVideoBitrateKbps)
    {
        var pixels = (long)source.Width * source.Height;
        var frameRate = source.AvgFrameRate > 0 ? source.AvgFrameRate : source.FrameRate > 0 ? source.FrameRate : 30;
        var bitsPerPixel = source.BitRate > 0 && pixels > 0
            ? source.BitRate / (pixels * frameRate)
            : 0.08;
        var isAv1 = targetVideoCodec.Contains("av1", StringComparison.OrdinalIgnoreCase);

        var automaticCrf = isAv1 ? bitsPerPixel switch
        {
            <= 0.04 => 35,
            <= 0.07 => 33,
            <= 0.12 => 31,
            _ => 29
        } : bitsPerPixel switch
        {
            <= 0.04 => 28,
            <= 0.07 => 26,
            <= 0.12 => 24,
            _ => 22
        };
        if (isAv1 && pixels >= 3840L * 2160)
            automaticCrf += 2;
        else if (isAv1 && pixels >= 1920L * 1080)
            automaticCrf += 1;

        var automaticPreset = !isAv1 ? "medium" : pixels switch
        {
            <= 1280L * 720 => "6",
            <= 1920L * 1080 => "7",
            _ => "8"
        };
        var resolutionCeilingKbps = Math.Max(128, (int)Math.Round(pixels * frameRate * 0.08 / 1000));
        var sourceEfficiencyRatio = !isAv1 ? 1.0 : source.CodecName.ToLowerInvariant() switch
        {
            "h264" or "avc" => 0.70,
            "hevc" or "h265" or "vp9" => 0.90,
            "av1" => 1.00,
            _ => 0.80
        };
        var sourceCeilingKbps = source.BitRate > 0
            ? Math.Max(128, (int)Math.Round(source.BitRate / 1000d * sourceEfficiencyRatio))
            : resolutionCeilingKbps;
        var automaticMaxVideoBitrateKbps = Math.Min(sourceCeilingKbps, resolutionCeilingKbps);

        return new EncodingProfile(
            string.IsNullOrWhiteSpace(preset) ? automaticPreset : preset,
            crf ?? automaticCrf,
            maxVideoBitrateKbps ?? automaticMaxVideoBitrateKbps);
    }
}