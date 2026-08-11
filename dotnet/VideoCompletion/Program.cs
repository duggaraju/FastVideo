using Azure.Core;
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
builder.Services.AddSingleton<IKubernetes>(_ => new Kubernetes(KubernetesClientConfiguration.InClusterConfig()));
builder.Services.AddHostedService<EncodeJobWatcher>();
await builder.Build().RunAsync();