using Video.Contracts;

namespace Video.Analysis;

public sealed class FixedDurationParallelizationStrategy : IParallelizationStrategy
{
    public string Name => "fixed-duration";

    public Task<IReadOnlyList<VideoSegment>> CreateSegmentsAsync(
        string inputPath,
        TimeSpan duration,
        int targetSegmentDurationSeconds,
        CancellationToken cancellationToken)
    {
        var totalSeconds = duration.TotalSeconds;
        var startSeconds = 0d;
        var index = 0;
        var segments = new List<VideoSegment>();
        while (startSeconds < totalSeconds)
        {
            var segmentDuration = Math.Min(targetSegmentDurationSeconds, totalSeconds - startSeconds);
            segments.Add(new VideoSegment(index, startSeconds, segmentDuration));
            startSeconds += segmentDuration;
            index++;
        }

        return Task.FromResult<IReadOnlyList<VideoSegment>>(segments);
    }
}
