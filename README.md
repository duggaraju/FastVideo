# FastVideo

FastVideo is a .NET 10, Rust, and FFmpeg pipeline for horizontally parallel video encoding on Kubernetes. Azure Kubernetes Service has the complete infrastructure-as-code path; an external-cluster profile supports existing Kubernetes clusters with separately provisioned dependencies.

The Storage Queue and Service Bus control planes can run side by side. `storagequeue` deploys the Rust analyzer and completion workers to `video-storagequeue`; `servicebus` deploys the .NET analysis and completion workers to `video-servicebus`. Each namespace has its own KEDA scaler, service account, RBAC, and workload-identity federation. The control-plane transport is independent from the `dotnet` or `rust` encoder and stitcher media runtime.

## Workflow

1. KEDA scales the selected analyzer from the `video-submitted` Storage Queue or Service Bus queue.
2. The analyzer reads the source from the read-only input mount and probes it with FFprobe. It rejects audio longer than `Encoding__MaxAudioDurationSeconds`, stream-copies audio to output storage when `audioCodec` is `copy`, computes segment boundaries, writes the manifest, and creates the media Jobs. Audio transcoding runs concurrently in a singleton Job on the selected Spot or regular pool; video encoding runs in a Kubernetes Indexed Job.
3. Every `VideoEncoder` index reads the source from input storage, encodes only its deterministic video time range (no audio), and writes to a unique staging path on the output BlobFuse mount. After FFmpeg succeeds, it renames the staging file to the deterministic segment path. When requested, the index also compares the segment with its source interval using VMAF and writes a deterministic score sidecar. A retry skips each artifact that already exists. Each index gets up to five retries on interruption or encoding failure.
4. Kubernetes marks the Indexed encode Job complete only after every index succeeds. For transcoding requests, the singleton Job watcher also waits for the audio encode Job to complete. It then creates a deterministic stitch Job using metadata stored on the encode Job. Stitching follows the request's `useSpot` setting and runs on the same Spot or regular pool selected for encoding.
5. `VideoStitcher` constructs ordered segment paths directly from indexes `0..SegmentCount-1` and reads them and the extracted audio exclusively from output storage. One FFmpeg process concatenates the video and emits the selected MP4 output, CMAF package with DASH and HLS manifests, or both. When VMAF was requested, the stitcher also writes the arithmetic mean of all segment VMAF means beside the requested output path.
6. A singleton completion reconciler logs failed encode pod attempts and sends one terminal `VideoProcessingResult` per video to `video-results`: encode failure after all retries means failure, stitch success means success, and stitch failure means failure. Individual retry failures and encode success are not sent as terminal results. After stitching succeeds, the reconciler deletes the corresponding encode Job.

Indexed encode Jobs use Spot nodes by default and tolerate eviction. A request can instead select the dedicated autoscaling regular encoding pool. Stitch Jobs use the same pool selected for encoding, while lightweight analysis and the Job watcher remain on regular system nodes. Encoder retries remain safe because blob names are deterministic, while Kubernetes Job conditions provide durable fan-in state.

## Projects

| Project | Purpose |
| --- | --- |
| `VideoContracts` / Rust contracts | Queue and manifest contracts, deterministic Kubernetes names |
| Analysis / `video-analyzer` | KEDA-scaled queue intake listener, FFprobe analysis, Indexed Job submission |
| `VideoEncoder` | One FFmpeg time-range encode per Kubernetes completion index |
| `VideoAudioEncoder` / Rust `audio-encoder` | One complete audio transcode for non-copy requests |
| Completion / `video-completion` | Kubernetes Job watcher, stitch Job submission, terminal result publishing |
| `VideoStitcher` | FFmpeg segment concatenation and output publishing |

## Prerequisites

- PowerShell 7 or later on Windows or Linux
- `kubectl`

Local builds require the .NET 10 SDK, Rust 1.98, and Docker. The default Azure deployment additionally requires Azure CLI with Bicep, an Azure subscription where the deployer can create AKS, role assignments, ACR, Storage, Service Bus, and managed identities, and permission to write role assignments on the target scope (for example, Owner or User Access Administrator). External mode has separate prerequisites below and does not invoke Azure CLI.

Runtime containers use the .NET 10 Azure Linux 3 image and run as the non-root `app` user. They default to BtbN's latest Linux x64 GPL shared FFmpeg build; the release archive is verified against BtbN's published SHA-256 checksums during each image build. Set the Docker build argument `FFMPEG_BUILD=custom` (or deploy with `-FfmpegBuild custom`) to compile FFmpeg 9.0 with native AAC, `libx264`, `libsvtav1`, `libdav1d`, and `libvmaf`. Override the custom version with the `FFMPEG_VERSION` Docker build argument or `-FfmpegVersion` deployment parameter. Both variants include the VMAF model. Azure access uses AKS Workload Identity; no connection strings or account keys are deployed.

## Build

```powershell
dotnet restore dotnet/Video.slnx
dotnet build dotnet/Video.slnx --no-restore --configuration Release
```

The Rust implementation in `rust` provides analyzer, completion, encoder, and stitcher workers:

```powershell
Push-Location rust
cargo build --release
Pop-Location
```

Build a Rust worker image with the separate Dockerfile by selecting `encoder` or `stitcher`:

```powershell
docker build -f rust/Dockerfile `
    --build-arg PACKAGE=encoder `
    -t video-encoder-rust:latest .
```

Build the complete image set locally for the current machine architecture without Azure credentials or a registry push:

```powershell
./scripts/build-images.ps1 -ImageTag dev
```

To build both media architectures with local Docker and push them to ACR, provide the registry name:

```powershell
./scripts/build-images.ps1 `
    -AcrName videoacr `
    -ImageTag latest `
    -Platforms linux/amd64,linux/arm64
```

Use ACR build agents instead of local Docker by adding `-AcrBuild`. The script submits each architecture through [deploy/acr-build.yaml](deploy/acr-build.yaml), then creates the multi-platform manifests with [deploy/acr-manifest.yaml](deploy/acr-manifest.yaml).

```powershell
./scripts/build-images.ps1 `
    -AcrName videoacr `
    -AcrBuild `
    -Platforms linux/amd64,linux/arm64
```

## Deploy

### Azure (default)

```powershell
./scripts/deploy.ps1 -Location westus2
```

Audio is limited to six hours by default. Override the analysis-stage limit at deployment time; requests exceeding it are rejected before media Jobs are scheduled:

```powershell
./scripts/deploy.ps1 -Location westus2 -MaxAudioDurationSeconds 43200
```

The default deploys the Rust Storage Queue control plane and Rust media workers. Deploy either or both control planes; select the media runtime independently for each namespace:

```powershell
# Rust analyzer/completion over Storage Queue, with .NET encoder/stitcher
./scripts/deploy.ps1 -Location westus2 `
    -MessageTransport storagequeue -MediaRuntime dotnet

# .NET analysis/completion over Service Bus, with Rust encoder/stitcher
./scripts/deploy.ps1 -Location westus2 `
    -MessageTransport servicebus -MediaRuntime rust
```

The resource group defaults to `<current-user-id>-video`, so each user gets an isolated deployment. Pass `-ResourceGroup` to override it. The Kubernetes namespace defaults to `video-storagequeue` or `video-servicebus`; pass `-KubernetesNamespace` to override it.

To compile a specific FFmpeg release from the official GitHub mirror:

```powershell
./scripts/deploy.ps1 `
    -Location westus2 `
    -FfmpegBuild custom `
    -FfmpegVersion 9.0
```

The script deploys [infra/main.bicep](infra/main.bicep), which creates or updates the selected broker and its RBAC assignments. Existing resources from the other mode are retained. It calls [scripts/build-images.ps1](scripts/build-images.ps1) to build the corresponding Rust or .NET control-plane images, build .NET and Rust encoder, audio encoder, and stitcher images for both `linux/amd64` and `linux/arm64`, and publish a multi-platform manifest for each media image. It then combines the shared [deploy/k8s/video.yaml](deploy/k8s/video.yaml) resources with the selected transport manifest. Each transport deployment only applies and restarts resources in its own namespace, allowing both control planes to remain active. The AKS system pool hosts analysis and completion. Dedicated x64 Spot, ARM64 Spot, and regular media-processing pools autoscale from zero. Encoding and stitching use any available Spot media architecture unless `useSpot` is `false`; no architecture-specific application code or image tag is required.

The infrastructure also enables Container Insights with managed-identity authentication and retains container logs in Log Analytics for 30 days, including logs from pods deleted after KEDA scales a deployment to zero.

When the infrastructure has not changed, skip the Bicep deployment and reuse the latest successful deployment outputs while rebuilding and deploying all container images:

```powershell
./scripts/deploy.ps1 `
    -SkipInfrastructureDeployment `
    -MessageTransport storagequeue
```

When skipping infrastructure deployment, the script reuses the latest successful deployment record for the requested `-MessageTransport`. Run infrastructure deployment at least once for each transport so its broker RBAC and namespace-specific federated credential exist.

Azure RBAC can take several minutes to propagate after first deployment. If the first pods report authorization failures, restart them after propagation.

Azure-specific scheduling, CSI, and scaler defaults are not hardcoded in `scripts/deploy.ps1`; they live in [deploy/overlays/azure-config.json](deploy/overlays/azure-config.json), an overlay config in the same shape as the external-cluster config below. The script fills in `{{...}}` tokens (storage account names, container names, the workload identity client ID, and the Service Bus namespace short name) from the Bicep deployment outputs, then applies the overlay the same way it applies an external config. Edit that file to change Azure node selectors, tolerations, CSI mount options, or scaler tuning without touching the script.

### Existing Kubernetes cluster

External mode renders and applies the same resources without invoking Azure CLI, Bicep, ACR, or image builds. Prerequisites are:

- an existing kubeconfig context and namespace-creation permission;
- FastVideo images already pushed under one registry repository prefix;
- externally provisioned Azure Blob Storage and either Azure Storage Queues or Azure Service Bus;
- a CSI driver capable of mounting those containers, plus its required volume attributes;
- a Kubernetes service account authentication setup that lets the current worker SDKs use Microsoft Entra credentials;
- KEDA and a matching scaler, or `"scaler": { "mode": "none" }` to run one analyzer replica.

Copy [deploy/external-config.example.json](deploy/external-config.example.json) outside source control, replace its example values, and deploy:

```powershell
Copy-Item deploy/external-config.example.json ~/fastvideo-external.json
# Edit ~/fastvideo-external.json; do not add credentials or connection strings.
./scripts/deploy.ps1 `
    -DeploymentMode external `
    -ExternalConfigPath ~/fastvideo-external.json `
    -MessageTransport storagequeue `
    -MediaRuntime rust `
    -ImageTag v1
```

The config controls the kube context, namespace, image repository, service account and annotations, pod labels, CSI driver/attributes, control-plane and Spot/regular media node selectors and tolerations, and scaler type/metadata/authentication. `useSpot` selects the configured Spot or regular scheduling profile; it does not assume a provider-specific node label. With scaler mode `none`, scaling is deliberately disabled and the analyzer stays at one replica.

The portability boundary is Kubernetes scheduling, registry naming, CSI mounting, and scaler configuration. It is **not yet a provider-neutral data plane**: queue and result clients still use Azure Storage Queue or Azure Service Bus SDKs, blob paths and manifests still use Azure Blob-compatible HTTPS URLs, and authentication still expects Microsoft Entra credentials. A different broker or object store requires a worker adapter implementation; configuring another scaler or CSI driver alone does not add that adapter. The example therefore uses externally provisioned Azure-compatible services and contains identifiers only, never secrets or connection strings.

## Submit Work

Send the JSON shape in [samples/video-submitted.json](samples/video-submitted.json) to the selected broker's `video-submitted` queue. `inputVideoUri` and `outputPath` must be HTTPS blob URLs. `outputPath` includes a base filename without an extension. The URLs can target different storage accounts and should match the input/output BlobFuse mounts configured in deployment.

When encoding parameters are omitted, analysis creates one output at the source resolution and uses the source codec, bitrate, resolution, and frame rate to select CRF, encoder speed preset, and maximum video bitrate. The default target codec is `libsvtav1`.

Set the optional `preset` message property to a ladder ceiling such as `max4k`, `max1440p`, `max1080p`, `max720p`, `max480p`, or `max360p`. Generic `max<height>p` values are also supported. The analyzer selects every configured rung at or below both that ceiling and the input dimensions, so it never upscales. Each segment worker encodes all selected resolutions; the stitcher independently publishes `<outputPath>-1080p.mp4`, `<outputPath>-720p.mp4`, and so on. Without a ladder preset, the existing `<outputPath>.mp4` naming is retained.

Optional `crf`, `encoderPreset`, and `maxVideoBitrateKbps` fields customize encoding. `maxVideoBitrateKbps` is a ceiling, not a replacement for every rung's configured target. The highest profile is capped at the detected input bitrate (including the existing target-codec efficiency adjustment), and every lower-resolution profile is guaranteed to use a lower maximum bitrate. For backward compatibility, a non-ladder value in `preset` is treated as the encoder speed preset; new clients should use `encoderPreset` for that purpose.

Ladder rungs and named presets are deployment configuration in [deploy/ladder-profiles.json](deploy/ladder-profiles.json). A `bounded` preset selects shared rungs at or below its resolution and bitrate ceilings; its optional `rungs` array can restrict which shared rungs are eligible. A `custom` preset declares an exact `renditions` array. Each custom rendition can reference a shared rung with `{ "rung": "720p" }`, optionally override its name, dimensions, or bitrate, or define all fields inline. Source-dimension and source-bitrate safeguards apply to both preset types. The deployment script validates the JSON, embeds it in the `video-ladder-profiles` ConfigMap, and mounts it read-only at `/etc/video/ladder/ladder-profiles.json` in both analyzers. Add, remove, or retune rungs and presets without changing or rebuilding application code. The analyzers read the projected file for each submission, while `Encoding__LadderProfiles` remains available as an inline JSON fallback for local deployments.

`useSpot` is optional and defaults to `true`. Set it to `false` to schedule all indexes for that video on the regular encoding pool. `calculateVmaf` is optional and defaults to `false`. When enabled, every encoder compares its output with the matching source interval. The final `.vmaf.json` beside the output video contains the overall unweighted arithmetic mean and an ordered `Segments` array with the `Index` and `Score` for every segment.

`outputType` is optional and defaults to `mp4`. Supported values are `mp4`, `cmaf`, and `both`:

| Value | Output |
| --- | --- |
| `mp4` | A single fast-start MP4 at `<outputPath>.mp4` |
| `cmaf` | Flat DASH/HLS manifests and single-file CMAF representations prefixed by the `outputPath` base filename |
| `both` | The MP4 and CMAF outputs above, produced by the same FFmpeg invocation |

For example, an `outputPath` ending in `videos/demo` produces `videos/demo.mp4`, `videos/demo.mpd`, `videos/demo.m3u8`, `videos/demo-stream0.m3u8`, and `videos/demo-stream0.cmaf` at the same level. Stream suffixes use FFmpeg's zero-based representation IDs. The DASH and HLS manifests reference the same CMAF representation media.

Job IDs must be unique for distinct work. Reusing a job ID deliberately resumes or deduplicates that workflow because Kubernetes Job names and output paths derive from it.

Use the timestamp format `test-yyyyMMdd-HHmm` for manual tests. For example, a test started at 14:30 on August 4, 2026 uses `test-20260804-1430`. Generate the value once and reuse it as the payload job ID and output filename.

### Test from PowerShell

The signed-in Azure identity needs `Storage Blob Data Reader` on the input and output accounts and access to retrieve AKS credentials. Storage Queue submissions also need `Storage Queue Data Contributor` on the output account; Service Bus submissions need `Azure Service Bus Data Sender` on the namespace. Run the test script:

```powershell
./scripts/test-workflow.ps1
```

The script discovers the latest successful deployment, creates a transport/VMAF-specific job ID with second precision, verifies the input blob, submits the message without an account key, and waits up to 60 minutes for a nonzero final blob. A VMAF-enabled run also verifies the final `.vmaf.json` blob. Override the source, job ID, or timeout when needed:

```powershell
./scripts/test-workflow.ps1 `
    -InputVideoUri "https://videoinsoudinndket2a.blob.core.windows.net/input/bingshort.mp4" `
    -ParallelizationStrategy keyframe-boundary `
    -UseSpot $false `
    -CalculateVmaf `
    -TimeoutMinutes 90
```

Use `-OutputVideoUri` to select the deployed output container and an optional virtual-directory prefix. By default, the job ID is appended as another prefix so each workflow's files remain grouped. Set `-UseJobIdAsPrefix $false` to omit it:

```powershell
./scripts/test-workflow.ps1 `
    -OutputVideoUri "https://videoout.blob.core.windows.net/videos/validation" `
    -UseJobIdAsPrefix $false
```

For an input named `sample.mp4`, this writes final artifacts with the base path `validation/sample`; manifests and intermediate segments remain under the workflow's job-ID prefix.

Use `-MediaRuntime dotnet` or `-MediaRuntime rust` to select the encoder and stitcher implementation. Message transport is independent: `-MessageTransport auto` follows the deployment's selected transport. Pass `storagequeue` or `servicebus` explicitly to require a matching deployment.

After the blob validation succeeds, the script reports the `video-results` message count. Inspect that queue with Azure Storage Explorer or Service Bus Explorer and confirm the matching `VideoProcessingResult` has `succeeded` set to `true` and `terminalStage` set to `stitch`; peeking avoids removing the result. On timeout, the script prints the current KEDA, pod, and Job state.

### Compare AMD64 and ARM64

The benchmark script can pin encoder and stitch Jobs to either architecture using an optional `architecture` field in the queue JSON. The analyzer translates that field into the standard Kubernetes `kubernetes.io/arch` node selector. Use `-Architecture any` or omit `-Architecture` to leave the architecture selector empty so Jobs remain eligible for any matching media-processing architecture. Normal submissions use the same architecture-independent behavior.

Run the same source, encoding settings, Spot priority, and run count for both architectures:

```powershell
./scripts/benchmark-workflow.ps1 -Architecture amd64 -Runs 5 -UseSpot $true -OutputPath ./scripts/amd64.json
./scripts/benchmark-workflow.ps1 -Architecture arm64 -Runs 5 -UseSpot $true -OutputPath ./scripts/arm64.json
./scripts/benchmark-workflow.ps1 -Architecture any -Runs 1 -UseSpot $true -OutputPath ./scripts/any-arch.json
```

To compare .NET and Rust encoding/stitching on the x64 Spot pool, deploy and benchmark each implementation with distinct immutable image tags. Use the custom FFmpeg build and the same FFmpeg version for both:

```powershell
./scripts/deploy.ps1 -SkipInfrastructureDeployment `
    -MediaRuntime dotnet -ImageTag bench-dotnet `
    -FfmpegBuild custom -FfmpegVersion 8.1 -Platforms linux/amd64
./scripts/benchmark-workflow.ps1 -MediaRuntime dotnet `
    -Architecture amd64 -Runs 5 -UseSpot $true -OutputPath ./scripts/dotnet-amd64.json

./scripts/deploy.ps1 -SkipInfrastructureDeployment `
    -MediaRuntime rust -ImageTag bench-rust `
    -FfmpegBuild custom -FfmpegVersion 8.1 -Platforms linux/amd64
./scripts/benchmark-workflow.ps1 -MediaRuntime rust `
    -Architecture amd64 -Runs 5 -UseSpot $true -OutputPath ./scripts/rust-amd64.json
```

The two runs use the same input URI by default and are pinned to the x64 Spot node pool. Each pod result records its image and resolved image ID; verify those fields before comparing medians. Alternate deployment order across repeated batches to reduce node warm-up, image-pull, storage-cache, autoscaler, and changing Spot-capacity bias.

Pass the effective hourly price for each VM SKU to include a node-active-time estimate:

```powershell
./scripts/benchmark-workflow.ps1 -Architecture amd64 -NodeHourlyPriceUsd <amd64-spot-price> -OutputPath ./scripts/amd64.json
./scripts/benchmark-workflow.ps1 -Architecture arm64 -NodeHourlyPriceUsd <arm64-spot-price> -OutputPath ./scripts/arm64.json
```

Each result records requested and actual architecture, node pool, VM SKU, encoder and stitch pod duration, end-to-end duration, node-active seconds, and estimated compute cost. Compare median `encodeQueueAndRunSeconds`, `totalSeconds`, and `estimatedComputeUsd`; also report throughput as input video duration divided by encode runtime. The estimate merges overlapping pod intervals on each node, but excludes autoscaler startup/idle time, the shared system pool, storage, and Log Analytics. Use Azure Cost Management amortized or actual cost filtered by the benchmark window and node-pool VM scale set for the authoritative cost comparison. Run architectures in alternating order and use at least five runs to reduce Spot-capacity, cache, and autoscaling bias.

### Test from Azure Portal

1. In the input storage account, open **Storage browser** and upload a source video to the configured `input` container.
1. Open the output storage account, select **Queues**, and open `video-submitted`.
1. Select **Storage browser** or Azure Storage Explorer, then add a message.
1. Paste the JSON payload exactly as shown.
1. Replace the account names and source blob path in this message, then send it:

```json
{
    "jobId": "test-20260804-1430",
    "inputVideoUri": "https://videoinsoudinndket2a.blob.core.windows.net/input/bingshort.mp4",
    "outputPath": "https://videooutsoudinndket2.blob.core.windows.net/videos/test-20260804-1430",
    "segmentDurationSeconds": 60,
    "audioCodec": "copy",
    "outputType": "both"
}
```

1. Monitor the AKS Indexed encode and stitch Jobs and the `video-results` Storage Queue. The output storage container will populate with the manifest, extracted audio, encoded segments, and final video.

Use a new `jobId` for each fresh test to avoid intentionally resuming prior work.

Intermediate output is written under the job prefix until stitching succeeds:

```text
videos/{jobId}/manifest.json
videos/{jobId}/segments/audio.m4a
videos/{jobId}/segments/000000-1080p.mp4
videos/{jobId}/segments/000000-1080p.vmaf.json (when requested)
videos/{jobId}/segments/000000-720p.mp4
videos/{jobId}/segments/000001-1080p.mp4
videos/{output-base}.mp4 (when outputType is mp4 or both)
videos/{output-base}-1080p.mp4 (for a ladder request)
videos/{output-base}-720p.mp4 (for a ladder request)
videos/{output-base}.mpd (when outputType is cmaf or both)
videos/{output-base}.m3u8 (when outputType is cmaf or both)
videos/{output-base}-stream*.m3u8 (when outputType is cmaf or both)
videos/{output-base}-stream*.cmaf (when outputType is cmaf or both)
```

After the final video and completion event are published, the stitcher removes the job prefix and all intermediate files.

## BlobFuse mounts

- Input storage is mounted read-only at `/mnt/input` and the workload identity has only `Storage Blob Data Reader` on its account.
- Output storage is mounted read-write at `/mnt/output` for manifest/audio/segment/final artifact writes.
- Encoder input and output mounts use BlobFuse CSI ephemeral volumes and access media through mounted paths.
- Stitch jobs mount only output storage; they cannot access the input mount.
- This avoids large local downloads on node OS disks and keeps media I/O on Blob storage paths.

Set `parallelizationStrategy` on a submitted message to select a strategy for that video. When omitted, the worker uses the strategy configured through `Encoding__ParallelizationStrategy`:

- `fixed-duration` (default): split using `ceil(video duration / Encoding__MaxParallelism)`, clamped to `segmentDurationSeconds` (60 seconds by default) through 180 seconds
- `keyframe-boundary`: accumulate one or more GOPs per segment and use the last keyframe at or before the target duration; a segment exceeds the target only when a single GOP is longer

`Encoding__MaxParallelism` controls adaptive segment sizing and the global encoder concurrency budget. Its application fallback is 16, while the deployment configures 32. `Encoding__MinParallelismPerJob` controls each Indexed Job's initial parallelism, capped by its segment count. Its application fallback is 2, while the deployment configures 2 so a Job can start up to 60 indexes without waiting for watcher reallocation. The job watcher still shares the global budget across unfinished Jobs and lends unused slots to Jobs that can use them. It can reduce a Job below 2 when capacity is oversubscribed or fewer segments remain. A single Job can use the full budget when no other encoding work is active.

## Production Notes

- Pin `kubernetesVersion` in [infra/main.bicepparam](infra/main.bicepparam) after selecting an AKS-supported version for the target region.
- Tune Spot and regular encoding VM SKUs, maximum node counts, Job parallelism, and pod resources for the target codec and video resolution. VMAF adds a second decode and quality-analysis pass to each encoder index.
- Place Storage, the selected message broker, ACR, and AKS behind private endpoints for restricted production networks. The starter template leaves public endpoints enabled but disables anonymous/blob public access, shared-key Storage auth, local Service Bus auth, and ACR admin credentials.
- Monitor dead-letter queues, `video-results`, Indexed Job failed indexes, Spot eviction events, and stitch Job failures. Successful encode Jobs are removed after stitching; encode Jobs have a 24-hour fallback TTL and stitch Jobs are retained for one hour.
