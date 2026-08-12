namespace Video.Analysis;

public sealed class ParallelizationStrategyFactory : IParallelizationStrategyFactory
{
    private readonly FixedDurationParallelizationStrategy _fixedDurationStrategy;
    private readonly KeyFrameBoundaryParallelizationStrategy _keyFrameBoundaryStrategy;
    private readonly string _defaultStrategy;

    public ParallelizationStrategyFactory(
        FixedDurationParallelizationStrategy fixedDurationStrategy,
        KeyFrameBoundaryParallelizationStrategy keyFrameBoundaryStrategy,
        IConfiguration configuration)
    {
        _fixedDurationStrategy = fixedDurationStrategy;
        _keyFrameBoundaryStrategy = keyFrameBoundaryStrategy;
        _defaultStrategy = configuration["Encoding:ParallelizationStrategy"] ?? "fixed-duration";
        _ = Resolve(_defaultStrategy, "Encoding:ParallelizationStrategy");
    }

    public IParallelizationStrategy GetStrategy(string? requestedStrategy) =>
        string.IsNullOrWhiteSpace(requestedStrategy)
            ? Resolve(_defaultStrategy, "Encoding:ParallelizationStrategy")
            : Resolve(requestedStrategy, nameof(requestedStrategy));

    private IParallelizationStrategy Resolve(string strategy, string source) =>
        strategy.Trim().ToLowerInvariant() switch
        {
            "fixed-duration" or "fixed" => _fixedDurationStrategy,
            "keyframe-boundary" or "keyframe" => _keyFrameBoundaryStrategy,
            _ => throw new ArgumentException(
                $"{source} must be 'fixed-duration' or 'keyframe-boundary'")
        };
}