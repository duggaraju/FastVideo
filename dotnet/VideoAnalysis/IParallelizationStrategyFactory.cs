namespace Video.Analysis;

public interface IParallelizationStrategyFactory
{
    IParallelizationStrategy GetStrategy(string? requestedStrategy);
}