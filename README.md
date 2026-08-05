# SpotVideo

SpotVideo is a .NET 10 and FFmpeg pipeline for horizontally parallel video encoding on Azure Kubernetes Service Spot nodes.

## Workflow

1. KEDA scales `SpotVideo.Analysis` from the `video-submitted` Service Bus queue.
2. The service reads the source from the read-only input mount, probes it with FFMpegCore/FFprobe, extracts one audio track (copy or optional re-encode) to output storage, computes segment boundaries, writes the manifest to output storage, and creates a Kubernetes Indexed Job.
3. Every `SpotVideo.Encoder` index reads the source from input storage, encodes only its deterministic video time range (no audio), and writes to a unique staging path on the output BlobFuse mount. After FFmpeg succeeds, it renames the staging file to the deterministic segment path and sends a `SegmentEncoded` event. A retry skips encoding when that segment already exists. Each index gets up to five retries on Spot interruption or encoding failure.
4. KEDA scales `SpotVideo.Completion` from the `segment-completed` queue. It records one Azure Table row per segment.
5. Once all unique rows exist, it creates a deterministic stitch Job. `SpotVideo.Stitcher` reads every ordered segment and the extracted audio exclusively from output storage, merges them there, writes the requested final output path, and sends `VideoStitched`.
6. A singleton Job watcher logs failed encode pod attempts and sends one terminal `VideoProcessingResult` per video to `video-results`: encode failure after all retries means failure, stitch success means success, and stitch failure means failure. Individual retry failures and encode success are not sent to Service Bus. After stitching succeeds, the watcher deletes the corresponding encode Job.

Only indexed encode Jobs run on Spot nodes and tolerate eviction. Analysis, completion, and stitch workloads run on regular nodes so long-running analysis and stitching are not interrupted by Spot eviction. Encoder retries remain safe because blob names are deterministic, Service Bus duplicate detection is enabled, and repeated completion messages overwrite no state.

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
- Permission to write Azure role assignments on the target scope (for example, Owner or User Access Administrator)

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

The script deploys [infra/main.bicep](infra/main.bicep), builds four images with ACR Tasks, renders [deploy/k8s/spotvideo.yaml](deploy/k8s/spotvideo.yaml), applies it, and restarts the workload deployments so rebuilt images are used even with the default `latest` tag. The AKS system pool (small regular VMs) hosts analysis, completion, and stitch jobs. A dedicated autoscaling Spot pool, tainted `NoSchedule`, hosts only encode Jobs.

The infrastructure also enables Container Insights with managed-identity authentication and retains container logs in Log Analytics for 30 days, including logs from pods deleted after KEDA scales a deployment to zero.

When the infrastructure has not changed, skip the Bicep deployment and reuse the latest successful deployment outputs while rebuilding and deploying all container images:

```powershell
./scripts/deploy.ps1 `
    -ResourceGroup rg-spotvideo `
    -SkipInfrastructureDeployment
```

Azure RBAC can take several minutes to propagate after first deployment. If the first pods report authorization failures, restart them after propagation.

## Submit Work

Send the JSON shape in [samples/video-submitted.json](samples/video-submitted.json) to the `video-submitted` queue. Set the Service Bus message ID to the job ID. `inputVideoUri` and `outputVideoUri` must be HTTPS blob URLs. They can target different storage accounts, and should match the input/output BlobFuse mounts configured in deployment.

When encoding parameters are omitted, analysis uses the source codec, bitrate, resolution, and frame rate to select CRF, preset, and a maximum video bitrate. The default target codec is `libsvtav1`. Optional `crf`, `preset`, and `maxVideoBitrateKbps` values override the corresponding automatic choices.

Job IDs must be unique for distinct work. Reusing a job ID deliberately resumes or deduplicates that workflow because Kubernetes Job names and output paths derive from it.

Use the timestamp format `test-yyyyMMdd-HHmm` for manual tests. For example, a test started at 14:30 on August 4, 2026 uses `test-20260804-1430`. Generate the value once and reuse it as the payload job ID, Service Bus message ID, correlation ID, and output filename.

### Test from PowerShell

The signed-in Azure identity needs `Azure Service Bus Data Sender` on the namespace, `Storage Blob Data Reader` on the input and output accounts, and access to retrieve AKS credentials. Run the test script:

```powershell
./scripts/test-workflow.ps1 -ResourceGroup rg-spotvideo
```

The script discovers the latest successful deployment, creates one `test-yyyyMMdd-HHmm` job ID, verifies the input blob, submits the message without an account key, and waits up to 60 minutes for a nonzero final blob. Override the source or timeout when needed:

```powershell
./scripts/test-workflow.ps1 `
    -ResourceGroup rg-spotvideo `
    -InputVideoUri "https://spotvideoinsoudinndket2a.blob.core.windows.net/input/bingshort.mp4" `
    -TimeoutMinutes 90
```

After the blob validation succeeds, the script reports the active `video-results` message count. Inspect that queue with Service Bus Explorer using **Peek** and confirm the matching `VideoProcessingResult` has `succeeded` set to `true` and `terminalStage` set to `stitch`; peeking avoids removing the result. On timeout, the script prints the current KEDA, pod, and Job state.

### Test from Azure Portal

1. In the input storage account, open **Storage browser** and upload a source video to the configured `input` container.
1. Open the deployed Service Bus namespace, select **Queues**, and open `video-submitted`.
1. Select **Service Bus Explorer**, then **Send messages**.
1. Set **Content type** to `application/json` and set **Message ID** to the same unique value used for `jobId`. The correlation ID can also be set to that value.
1. Replace the account names and source blob path in this message, then send it:

```json
{
    "jobId": "test-20260804-1430",
    "inputVideoUri": "https://spotvideoinsoudinndket2a.blob.core.windows.net/input/bingshort.mp4",
    "outputVideoUri": "https://spotvideooutsoudinndket2.blob.core.windows.net/videos/test-20260804-1430.mp4",
    "segmentDurationSeconds": 20,
    "audioCodec": "copy"
}
```

1. Monitor the AKS workloads and the `segment-completed` and `video-results` Service Bus queues. The output storage container will populate with the manifest, extracted audio, encoded segments, and final video.

Use a new `jobId` and Message ID for each fresh test because Service Bus duplicate detection is enabled.

Intermediate output is written under the job prefix until stitching succeeds:

```text
videos/{jobId}/manifest.json
videos/{jobId}/segments/audio.m4a
videos/{jobId}/segments/000000.mp4
videos/{jobId}/segments/000001.mp4
(final file is written to outputVideoUri)
```

After the final video and completion event are published, the stitcher removes the job prefix and all intermediate files.

## BlobFuse mounts

- Input storage is mounted read-only at `/mnt/input` and the workload identity has only `Storage Blob Data Reader` on its account.
- Output storage is mounted read-write at `/mnt/output` for manifest/audio/segment/final artifact writes.
- Encoder input and output mounts use BlobFuse CSI ephemeral volumes and access media through mounted paths.
- Stitch jobs mount only output storage; they cannot access the input mount.
- This avoids large local downloads on node OS disks and keeps media I/O on Blob storage paths.

Parallelization strategy is configured through `Encoding__ParallelizationStrategy`:

- `fixed-duration` (default): split by `segmentDurationSeconds`
- `keyframe-boundary`: split near target duration but align boundaries to video keyframes

## Production Notes

- Pin `kubernetesVersion` in [infra/main.bicepparam](infra/main.bicepparam) after selecting an AKS-supported version for the target region.
- Tune Spot VM SKU, maximum node count, Job parallelism, and pod resources for the target codec and video resolution.
- Place Storage, Service Bus, ACR, and AKS behind private endpoints for restricted production networks. The starter template leaves public endpoints enabled but disables anonymous/blob public access, shared-key Storage auth, local Service Bus auth, and ACR admin credentials.
- Monitor dead-letter queues, `video-results`, Indexed Job failed indexes, Spot eviction events, and stitch Job failures. Successful encode Jobs are removed after stitching; encode Jobs have a 24-hour fallback TTL and stitch Jobs are retained for one hour.
