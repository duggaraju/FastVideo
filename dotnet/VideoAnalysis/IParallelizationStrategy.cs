using Video.Contracts;

namespace Video.Analysis;

public interface IParallelizationStrategy
{
    string Name { get; }

    Task<IReadOnlyList<VideoSegment>> CreateSegmentsAsync(
        string inputPath,
        TimeSpan duration,
        int targetSegmentDurationSeconds,
        CancellationToken cancellationToken);
}
