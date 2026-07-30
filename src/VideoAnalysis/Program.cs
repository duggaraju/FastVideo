using Azure.Core;
using Azure.Identity;
using Azure.Messaging.ServiceBus;
using FFMpegCore;
using k8s;
using SpotVideo.Analysis;

GlobalFFOptions.Configure(options =>
{
    options.BinaryFolder = "/usr/bin";
    options.TemporaryFilesFolder = "/tmp";
});

var builder = Host.CreateApplicationBuilder(args);
TokenCredential credential = new DefaultAzureCredential();
builder.Services.AddSingleton(credential);
builder.Services.AddSingleton(new ServiceBusClient(
    builder.Configuration["ServiceBus:Namespace"] ?? throw new InvalidOperationException("ServiceBus:Namespace is required"),
    credential));
builder.Services.AddSingleton<IKubernetes>(_ => new Kubernetes(KubernetesClientConfiguration.InClusterConfig()));
builder.Services.AddSingleton<FixedDurationParallelizationStrategy>();
builder.Services.AddSingleton<KeyFrameBoundaryParallelizationStrategy>();
builder.Services.AddSingleton<IParallelizationStrategy>(services =>
{
    var mode = builder.Configuration["Encoding:ParallelizationStrategy"] ?? "fixed-duration";
    return mode.Trim().ToLowerInvariant() switch
    {
        "fixed-duration" or "fixed" => services.GetRequiredService<FixedDurationParallelizationStrategy>(),
        "keyframe-boundary" or "keyframe" => services.GetRequiredService<KeyFrameBoundaryParallelizationStrategy>(),
        _ => throw new InvalidOperationException($"Unsupported Encoding:ParallelizationStrategy '{mode}'")
    };
});
builder.Services.AddHostedService<AnalysisWorker>();
await builder.Build().RunAsync();