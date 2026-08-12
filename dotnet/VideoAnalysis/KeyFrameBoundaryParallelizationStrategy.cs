using System.Diagnostics;
using System.Globalization;
using Video.Contracts;

namespace Video.Analysis;

public sealed class KeyFrameBoundaryParallelizationStrategy : IParallelizationStrategy
{
    public string Name => "keyframe-boundary";

    public async Task<IReadOnlyList<VideoSegment>> CreateSegmentsAsync(
        string inputPath,
        TimeSpan duration,
        int targetSegmentDurationSeconds,
        CancellationToken cancellationToken)
    {
        var durationSeconds = duration.TotalSeconds;
        var keyFrames = await ReadKeyFrameTimesAsync(inputPath, durationSeconds, cancellationToken);
        var boundaries = BuildBoundaries(keyFrames, durationSeconds, targetSegmentDurationSeconds);
        var segments = new List<VideoSegment>(Math.Max(1, boundaries.Count - 1));
        for (var i = 0; i < boundaries.Count - 1; i++)
        {
            var start = boundaries[i];
            var end = boundaries[i + 1];
            segments.Add(new VideoSegment(i, start, end - start));
        }

        return segments;
    }

    private static async Task<List<double>> ReadKeyFrameTimesAsync(string inputPath, double durationSeconds, CancellationToken cancellationToken)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = "ffprobe",
            Arguments = $"-v error -select_streams v:0 -skip_frame nokey -show_frames -show_entries frame=best_effort_timestamp_time -of csv=p=0:nk=1 \"{inputPath}\"",
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false
        };
        using var process = Process.Start(startInfo)
            ?? throw new InvalidOperationException("Failed to start ffprobe process");
        var outputTask = process.StandardOutput.ReadToEndAsync(cancellationToken);
        var errorTask = process.StandardError.ReadToEndAsync(cancellationToken);
        await process.WaitForExitAsync(cancellationToken);
        var output = await outputTask;
        var error = await errorTask;
        if (process.ExitCode != 0)
            throw new InvalidOperationException($"ffprobe failed while reading keyframes: {error}");

        var keyFrames = new List<double>();
        foreach (var line in output.Split('\n', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries))
        {
            if (double.TryParse(line, NumberStyles.Float, CultureInfo.InvariantCulture, out var timestamp))
                keyFrames.Add(timestamp);
        }

        keyFrames = keyFrames
            .Where(timestamp => timestamp >= 0 && timestamp <= durationSeconds)
            .DistinctBy(timestamp => Math.Round(timestamp, 6))
            .OrderBy(timestamp => timestamp)
            .ToList();

        if (keyFrames.Count == 0 || keyFrames[0] > 0)
            keyFrames.Insert(0, 0);
        if (keyFrames[^1] < durationSeconds)
            keyFrames.Add(durationSeconds);
        return keyFrames;
    }

    private static List<double> BuildBoundaries(List<double> keyFrames, double durationSeconds, int targetSegmentDurationSeconds)
    {
        const double epsilon = 0.0001;
        var boundaries = new List<double> { 0 };
        var start = 0d;
        while (start < durationSeconds - epsilon)
        {
            var target = start + targetSegmentDurationSeconds;
            var boundary = keyFrames.LastOrDefault(timestamp =>
                timestamp > start + epsilon && timestamp <= target + epsilon);
            if (boundary <= start + epsilon)
            {
                boundary = keyFrames.FirstOrDefault(timestamp => timestamp > start + epsilon);
            }
            if (boundary <= start + epsilon || boundary > durationSeconds)
                boundary = durationSeconds;

            boundaries.Add(boundary);
            start = boundary;
        }

        if (boundaries[^1] < durationSeconds)
            boundaries.Add(durationSeconds);
        return boundaries;
    }
}
