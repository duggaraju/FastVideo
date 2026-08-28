using FFMpegCore;
using System.Text.Json;
using Video.Contracts;

namespace Video.Analysis;

public sealed record EncodingProfile(string Name, int Width, int Height, string EncoderPreset, int Crf, int MaxVideoBitrateKbps);

public static class EncodingProfileSelector
{
    private sealed record LadderRung(string Name, int Width, int Height, int MaxVideoBitrateKbps);
    private sealed record LadderRungDefinition(int Width, int Height, int MaxVideoBitrateKbps);
    private sealed record RenditionDefinition(string? Rung, string? Name, int? Width, int? Height, int? MaxVideoBitrateKbps);
    private sealed record LadderPresetDefinition(
        string Type,
        IReadOnlyList<string>? Rungs,
        int? MaxWidth,
        int? MaxHeight,
        int? MaxVideoBitrateKbps,
        IReadOnlyList<RenditionDefinition>? Renditions);
    private sealed record LadderCatalog(
        IReadOnlyDictionary<string, LadderRungDefinition> Rungs,
        IReadOnlyDictionary<string, LadderPresetDefinition> Presets);

    public const string DefaultLadderProfilesJson = """
        {"rungs":{"2160p":{"width":3840,"height":2160,"maxVideoBitrateKbps":16000},"1440p":{"width":2560,"height":1440,"maxVideoBitrateKbps":9000},"1080p":{"width":1920,"height":1080,"maxVideoBitrateKbps":5000},"720p":{"width":1280,"height":720,"maxVideoBitrateKbps":2800},"480p":{"width":854,"height":480,"maxVideoBitrateKbps":1400},"360p":{"width":640,"height":360,"maxVideoBitrateKbps":800}},"presets":{"max4k":{"type":"bounded","maxWidth":3840,"maxHeight":2160,"maxVideoBitrateKbps":16000},"max2160p":{"type":"bounded","maxWidth":3840,"maxHeight":2160,"maxVideoBitrateKbps":16000},"max1440p":{"type":"bounded","maxWidth":2560,"maxHeight":1440,"maxVideoBitrateKbps":9000},"max1080p":{"type":"bounded","maxWidth":1920,"maxHeight":1080,"maxVideoBitrateKbps":5000},"max720p":{"type":"bounded","maxWidth":1280,"maxHeight":720,"maxVideoBitrateKbps":2800},"max480p":{"type":"bounded","maxWidth":854,"maxHeight":480,"maxVideoBitrateKbps":1400},"max360p":{"type":"bounded","maxWidth":640,"maxHeight":360,"maxVideoBitrateKbps":800}}}
        """;

    public static bool IsLadderPreset(string? preset, string? ladderProfilesJson = null)
    {
        if (VideoLadderPresets.IsLadder(preset))
            return true;
        if (string.IsNullOrWhiteSpace(preset))
            return false;
        var catalog = ParseLadder(ladderProfilesJson);
        return catalog.Presets.Keys.Any(name => name.Equals(preset, StringComparison.OrdinalIgnoreCase));
    }

    public static IReadOnlyList<EncodingProfile> Select(
        VideoStream source,
        string targetVideoCodec,
        string? ladderPreset,
        string? encoderPreset,
        int? crf,
        int? maxVideoBitrateKbps,
        string? ladderProfilesJson = null)
    {
        var frameRate = source.AvgFrameRate > 0 ? source.AvgFrameRate : source.FrameRate > 0 ? source.FrameRate : 30;
        var sourcePixels = (long)source.Width * source.Height;
        var bitsPerPixel = source.BitRate > 0 && sourcePixels > 0
            ? source.BitRate / (sourcePixels * frameRate)
            : 0.08;
        var isAv1 = targetVideoCodec.Contains("av1", StringComparison.OrdinalIgnoreCase);

        // Before ladder presets existed, `preset` was the encoder speed preset. Keep accepting
        // those payloads while making `encoderPreset` the unambiguous override going forward.
        var catalog = ParseLadder(ladderProfilesJson);
        if (!string.IsNullOrWhiteSpace(ladderPreset) && !IsLadderPreset(ladderPreset, ladderProfilesJson))
        {
            encoderPreset ??= ladderPreset;
            ladderPreset = null;
        }

        var rungs = SelectRungs(source.Width, source.Height, ladderPreset, catalog);
        var profiles = rungs.Select(rung => CreateProfile(
            source,
            rung,
            frameRate,
            bitsPerPixel,
            isAv1,
            encoderPreset,
            crf,
            maxVideoBitrateKbps)).ToList();
        for (var index = 1; index < profiles.Count; index++)
        {
            profiles[index] = profiles[index] with
            {
                MaxVideoBitrateKbps = Math.Min(profiles[index].MaxVideoBitrateKbps, Math.Max(1, profiles[index - 1].MaxVideoBitrateKbps - 1))
            };
        }
        return profiles;
    }

    private static EncodingProfile CreateProfile(
        VideoStream source,
        LadderRung rung,
        double frameRate,
        double bitsPerPixel,
        bool isAv1,
        string? encoderPreset,
        int? crf,
        int? maxVideoBitrateKbps)
    {
        var pixels = (long)rung.Width * rung.Height;

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

        var automaticEncoderPreset = !isAv1 ? "medium" : pixels switch
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
            ? Math.Max(1, (int)Math.Floor(source.BitRate / 1000d * sourceEfficiencyRatio))
            : resolutionCeilingKbps;
        var automaticMaxVideoBitrateKbps = Math.Min(rung.MaxVideoBitrateKbps, Math.Min(sourceCeilingKbps, resolutionCeilingKbps));
        var requestedCeilingKbps = maxVideoBitrateKbps ?? int.MaxValue;

        return new EncodingProfile(
            rung.Name,
            rung.Width,
            rung.Height,
            string.IsNullOrWhiteSpace(encoderPreset) ? automaticEncoderPreset : encoderPreset,
            crf ?? automaticCrf,
            Math.Min(requestedCeilingKbps, automaticMaxVideoBitrateKbps));
    }

    private static IReadOnlyList<LadderRung> SelectRungs(
        int sourceWidth,
        int sourceHeight,
        string? preset,
        LadderCatalog catalog)
    {
        if (string.IsNullOrWhiteSpace(preset))
        {
            return [new($"{sourceHeight}p", sourceWidth, sourceHeight, int.MaxValue)];
        }

        var configuredPreset = catalog.Presets.FirstOrDefault(pair => pair.Key.Equals(preset, StringComparison.OrdinalIgnoreCase));
        var selected = configuredPreset.Value is not null
            ? ResolvePreset(catalog, configuredPreset.Value)
            : ResolveGenericBoundedPreset(catalog, preset);
        selected = selected
            .Where(rung => rung.Width <= sourceWidth && rung.Height <= sourceHeight)
            .OrderByDescending(rung => rung.Height)
            .ToList();
        if (selected.Count == 0)
        {
            selected.Add(new($"{sourceHeight}p", sourceWidth, sourceHeight, 800));
        }
        return selected;
    }

    private static List<LadderRung> ResolvePreset(LadderCatalog catalog, LadderPresetDefinition preset)
    {
        if (preset.Type.Equals("bounded", StringComparison.OrdinalIgnoreCase))
        {
            if (preset.MaxWidth is null or < 2 || preset.MaxHeight is null or < 2 || preset.MaxVideoBitrateKbps is null or < 1)
                throw new InvalidOperationException("Bounded presets require positive maxWidth, maxHeight, and maxVideoBitrateKbps");
            var eligible = preset.Rungs?.ToHashSet(StringComparer.OrdinalIgnoreCase);
            return catalog.Rungs
                .Where(pair => eligible is null || eligible.Contains(pair.Key))
                .Where(pair => pair.Value.Width <= preset.MaxWidth && pair.Value.Height <= preset.MaxHeight)
                .Select(pair => new LadderRung(pair.Key, pair.Value.Width, pair.Value.Height,
                    Math.Min(pair.Value.MaxVideoBitrateKbps, preset.MaxVideoBitrateKbps.Value)))
                .ToList();
        }
        if (!preset.Type.Equals("custom", StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException($"Unknown ladder preset type '{preset.Type}'");
        if (preset.Renditions is not { Count: > 0 })
            throw new InvalidOperationException("Custom presets require at least one rendition");
        return preset.Renditions.Select(rendition => ResolveRendition(catalog, rendition)).ToList();
    }

    private static List<LadderRung> ResolveGenericBoundedPreset(LadderCatalog catalog, string preset)
    {
        if (!VideoLadderPresets.TryGetMaximumHeight(preset, out var maximumHeight))
            throw new InvalidOperationException($"Unknown ladder preset '{preset}'");
        return catalog.Rungs
            .Where(pair => pair.Value.Height <= maximumHeight)
            .Select(pair => new LadderRung(pair.Key, pair.Value.Width, pair.Value.Height, pair.Value.MaxVideoBitrateKbps))
            .ToList();
    }

    private static LadderRung ResolveRendition(LadderCatalog catalog, RenditionDefinition rendition)
    {
        if (!string.IsNullOrWhiteSpace(rendition.Rung))
        {
            var referenced = catalog.Rungs.FirstOrDefault(pair => pair.Key.Equals(rendition.Rung, StringComparison.OrdinalIgnoreCase));
            if (referenced.Value is null)
                throw new InvalidOperationException($"Unknown ladder rung reference '{rendition.Rung}'");
            return new LadderRung(
                rendition.Name ?? referenced.Key,
                rendition.Width ?? referenced.Value.Width,
                rendition.Height ?? referenced.Value.Height,
                rendition.MaxVideoBitrateKbps ?? referenced.Value.MaxVideoBitrateKbps);
        }
        if (string.IsNullOrWhiteSpace(rendition.Name) || rendition.Width is null or < 2 ||
            rendition.Height is null or < 2 || rendition.MaxVideoBitrateKbps is null or < 1)
            throw new InvalidOperationException("Inline renditions require a name, dimensions, and positive maxVideoBitrateKbps");
        return new LadderRung(rendition.Name, rendition.Width.Value, rendition.Height.Value, rendition.MaxVideoBitrateKbps.Value);
    }

    private static LadderCatalog ParseLadder(string? json)
    {
        var catalog = JsonSerializer.Deserialize<LadderCatalog>(
            string.IsNullOrWhiteSpace(json) ? DefaultLadderProfilesJson : json,
            JsonSerializerOptions.Web) ?? throw new InvalidOperationException("Encoding:LadderProfiles must be valid JSON");
        if (catalog.Rungs.Count == 0 || catalog.Presets.Count == 0 || catalog.Rungs.Any(pair =>
                string.IsNullOrWhiteSpace(pair.Key) || pair.Value.Width < 2 || pair.Value.Height < 2 || pair.Value.MaxVideoBitrateKbps < 1))
            throw new InvalidOperationException("Encoding:LadderProfiles must contain valid rungs and presets");
        foreach (var preset in catalog.Presets.Values)
            _ = ResolvePreset(catalog, preset);
        return catalog;
    }
}