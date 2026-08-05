namespace SpotVideo.Analysis;

public interface IParallelizationStrategyFactory
{
    IParallelizationStrategy GetStrategy(string? requestedStrategy);
}