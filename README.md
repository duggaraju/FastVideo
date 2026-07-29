# SpotVideo

SpotVideo is a .NET 10 and FFmpeg pipeline for horizontally parallel video encoding on Azure Kubernetes Service Spot nodes.

## Workflow

1. KEDA scales `SpotVideo.Analysis` from the `video-submitted` Service Bus queue.
2. The service downloads the input video URL, probes it with FFMpegCore/FFprobe, extracts one audio track (copy or optional re-encode), computes segment boundaries using the configured parallelization strategy, writes a manifest, and creates a Kubernetes Indexed Job.
3. Every `SpotVideo.Encoder` index downloads the source, encodes only its deterministic video time range (no audio), uploads one MP4 segment, and sends a `SegmentEncoded` event.
4. KEDA scales `SpotVideo.Completion` from the `segment-completed` queue. It records one Azure Table row per segment.
5. Once all unique rows exist, it creates a deterministic stitch Job. `SpotVideo.Stitcher` downloads the ordered segments, stitches them, muxes with the single extracted audio file, uploads to the requested output video URL, and sends `VideoStitched`.

Indexed encode and stitch Jobs tolerate Spot eviction: Kubernetes retries failed pods, blob names are deterministic, Service Bus duplicate detection is enabled, and repeated completion messages overwrite no state.

## Projects

| Project | Purpose |
| --- | --- |
| `SpotVideo.Contracts` | Queue and manifest contracts, deterministic Kubernetes names |
| `SpotVideo.Analysis` | KEDA-scaled intake listener, FFprobe analysis, Indexed Job submission |
| `SpotVideo.Encoder` | One FFmpeg time-range encode per Kubernetes completion index |
| `SpotVideo.Completion` | Completion listener, durable fan-in, stitch Job submission |
| `SpotVideo.Stitcher` | FFmpeg segment concatenation and final event publishing |

## Prerequisites

- .NET 10 SDK for local builds
- Azure CLI with the Bicep extension
- `kubectl`
- An Azure subscription where the deployer can create AKS, role assignments, ACR, Storage, Service Bus, and managed identities

The runtime containers install FFmpeg on Ubuntu and run as the non-root `app` user. Azure access uses AKS Workload Identity; no connection strings or account keys are deployed.

## Build

```powershell
dotnet restore SpotVideo.slnx
dotnet build SpotVideo.slnx --no-restore --configuration Release
```

## Deploy

```powershell
./scripts/deploy.ps1 -ResourceGroup rg-spotvideo -Location eastus
```

The script deploys [infra/main.bicep](infra/main.bicep), builds four images with ACR Tasks, renders [deploy/k8s/spotvideo.yaml](deploy/k8s/spotvideo.yaml), and applies it. The AKS system pool hosts the listeners and KEDA. A dedicated autoscaling Spot pool, tainted `NoSchedule`, hosts only encode and stitch Jobs.

Azure RBAC can take several minutes to propagate after first deployment. If the first pods report authorization failures, restart them after propagation.

## Submit Work

Send the JSON shape in [samples/video-submitted.json](samples/video-submitted.json) to the `video-submitted` queue. Set the Service Bus message ID to the job ID. `inputVideoUri` and `outputVideoUri` must be HTTPS URLs. They can target different storage accounts, and can be either blob URLs accessible to the workload identity or short-lived SAS URLs.

Job IDs must be unique for distinct work. Reusing a job ID deliberately resumes or deduplicates that workflow because Kubernetes Job names and output paths derive from it.

The default output is:

```text
videos/{jobId}/manifest.json
videos/{jobId}/audio.m4a
videos/{jobId}/segments/000000.mp4
videos/{jobId}/segments/000001.mp4
(final file is written to outputVideoUri)
```

Parallelization strategy is configured through `Encoding__ParallelizationStrategy`:
- `fixed-duration` (default): split by `segmentDurationSeconds`
- `keyframe-boundary`: split near target duration but align boundaries to video keyframes

## Production Notes

- Pin `kubernetesVersion` in [infra/main.bicepparam](infra/main.bicepparam) after selecting an AKS-supported version for the target region.
- Tune Spot VM SKU, maximum node count, Job parallelism, and pod resources for the target codec and video resolution.
- Place Storage, Service Bus, ACR, and AKS behind private endpoints for restricted production networks. The starter template leaves public endpoints enabled but disables anonymous/blob public access, shared-key Storage auth, local Service Bus auth, and ACR admin credentials.
- Monitor dead-letter queues, Indexed Job failed indexes, Spot eviction events, and stitch Job failures. Completed Jobs are retained for one hour for diagnosis.