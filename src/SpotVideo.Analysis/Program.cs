using Azure.Core;
using Azure.Identity;
using Azure.Messaging.ServiceBus;
using Azure.Storage.Blobs;
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
builder.Services.AddSingleton(new BlobServiceClient(
    new Uri(builder.Configuration["Storage:ServiceUri"] ?? throw new InvalidOperationException("Storage:ServiceUri is required")),
    credential));
builder.Services.AddSingleton<IKubernetes>(_ => new Kubernetes(KubernetesClientConfiguration.InClusterConfig()));
builder.Services.AddHostedService<AnalysisWorker>();
await builder.Build().RunAsync();