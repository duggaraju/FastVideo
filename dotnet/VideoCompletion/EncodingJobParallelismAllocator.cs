namespace Video.Completion;

internal sealed record EncodingJobDemand(string Name, int RemainingSegments);

internal static class EncodingJobParallelismAllocator
{
    public static IReadOnlyDictionary<string, int> Allocate(
        IEnumerable<EncodingJobDemand> jobs,
        int maxParallelism)
    {
        if (maxParallelism < 1)
            throw new ArgumentOutOfRangeException(nameof(maxParallelism), "Max parallelism must be greater than zero");

        var pending = jobs
            .Where(job => job.RemainingSegments > 0)
            .OrderBy(job => job.Name, StringComparer.Ordinal)
            .ToList();
        var allocations = new Dictionary<string, int>(StringComparer.Ordinal);
        if (pending.Count == 0)
            return allocations;

        if (pending.Count >= maxParallelism)
        {
            for (var index = 0; index < pending.Count; index++)
                allocations[pending[index].Name] = index < maxParallelism ? 1 : 0;
            return allocations;
        }

        var available = maxParallelism;
        while (pending.Count > 0)
        {
            var equalShare = available / pending.Count;
            var completedAllocations = pending
                .Where(job => job.RemainingSegments <= equalShare)
                .ToList();
            if (completedAllocations.Count == 0)
            {
                var remainder = available % pending.Count;
                for (var index = 0; index < pending.Count; index++)
                {
                    var allocation = equalShare + (index < remainder ? 1 : 0);
                    allocations[pending[index].Name] = Math.Min(pending[index].RemainingSegments, allocation);
                }
                break;
            }

            foreach (var job in completedAllocations)
            {
                allocations[job.Name] = job.RemainingSegments;
                available -= job.RemainingSegments;
                pending.Remove(job);
            }
        }

        return allocations;
    }
}