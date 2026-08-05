using Azure.Core;
using Azure.Data.Tables;
using Azure.Identity;
using Azure.Messaging.ServiceBus;
using k8s;
using SpotVideo.Completion;

var builder = Host.CreateApplicationBuilder(args);
TokenCredential credential = new DefaultAzureCredential();
builder.Services.AddSingleton(credential);
builder.Services.AddSingleton(new ServiceBusClient(
    builder.Configuration["ServiceBus:Namespace"] ?? throw new InvalidOperationException("ServiceBus:Namespace is required"),
    credential));
builder.Services.AddSingleton(new TableClient(
    new Uri(builder.Configuration["Storage:TableServiceUri"] ?? throw new InvalidOperationException("Storage:TableServiceUri is required")),
    builder.Configuration["Storage:StateTable"] ?? "encodingstate",
    credential));
builder.Services.AddSingleton<IKubernetes>(_ => new Kubernetes(KubernetesClientConfiguration.InClusterConfig()));
if (builder.Configuration.GetValue("Completion:ProcessorEnabled", true))
    builder.Services.AddHostedService<CompletionWorker>();
if (builder.Configuration.GetValue("Completion:WatcherEnabled", false))
    builder.Services.AddHostedService<EncodeJobWatcher>();
await builder.Build().RunAsync();