using Azure.Core;
using Azure.Identity;
using Azure.Messaging.ServiceBus;
using FFMpegCore;
using k8s;
using Video.Analysis;

GlobalFFOptions.Configure(options =>
{
    options.BinaryFolder = Environment.GetEnvironmentVariable("FFMPEG_BINARY_FOLDER")
        ?? (Directory.Exists("/opt/ffmpeg/bin") ? "/opt/ffmpeg/bin" : "/usr/bin");
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
builder.Services.AddSingleton<IParallelizationStrategyFactory, ParallelizationStrategyFactory>();
builder.Services.AddHostedService<AnalysisWorker>();
await builder.Build().RunAsync();