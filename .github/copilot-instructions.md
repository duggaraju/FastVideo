# FastVideo repository instructions

## Build, test, and lint

Run commands from the repository root unless a command changes directories.

```powershell
# .NET 10 solution
dotnet restore dotnet/Video.slnx
dotnet build dotnet/Video.slnx --no-restore --configuration Release

# Rust 1.98 workspace
Push-Location rust
cargo build --locked --release
cargo test --locked --workspace
cargo fmt --all --check
cargo clippy --locked --workspace --all-targets -- -D warnings
Pop-Location
```

Rust unit tests live inline in the relevant crate. Run one test by package and test-name filter:

```powershell
Push-Location rust
cargo test --locked --package video-core distributes_global_budget
cargo test --locked --package analyzer validates_submission_contract
Pop-Location
```

There are no .NET test projects in `dotnet/Video.slnx`. The deployed end-to-end workflow test requires Azure access, an existing deployment, `az`, and `kubectl`:

```powershell
./scripts/test-workflow.ps1
```

Build the local container set with `./scripts/build-images.ps1 -ImageTag dev`. The script intentionally builds only the control plane selected by `-MessageTransport`, but builds both .NET and Rust variants of the media workers. Deployment is driven by `./scripts/deploy.ps1 -Location <azure-region>`.

## Architecture

FastVideo is an AKS/FFmpeg pipeline with two independent choices:

- **Control-plane transport:** Rust analyzer/completion workers use Azure Storage Queues in `video-storagequeue`; .NET analysis/completion workers use Azure Service Bus in `video-servicebus`.
- **Media runtime:** encoder, audio encoder, and stitcher Jobs can independently use the .NET or Rust implementation. Do not couple transport selection to media runtime selection.

The workflow is analyzer -> Indexed video encode Job plus optional singleton audio encode Job -> completion reconciler -> stitch Job -> one terminal result. KEDA scales only the analyzer intake deployment. Analysis and completion run on system nodes; media Jobs run on Spot nodes by default or the regular media pool when `useSpot` is false.

Shared logical components have parallel implementations:

- `dotnet/VideoContracts` and `rust/video-core/src/contracts.rs` define interoperable queue, manifest, result, annotation, and deterministic-name contracts.
- `dotnet/VideoAnalysis` and `rust/analyzer` probe media, select profiles and segmentation, write the manifest, and submit Kubernetes Jobs.
- `dotnet/VideoCompletion` and `rust/completion` rebalance the global Indexed Job parallelism budget, fan in encode/audio completion, create stitch Jobs, and publish terminal results.
- The encoder/audio-encoder/stitcher binaries are short-lived Kubernetes Job processes driven primarily by environment variables and BlobFuse-mounted files.

Media flows through BlobFuse rather than local downloads. The input mount is read-only; intermediate and final artifacts use the output mount. Stitchers intentionally mount only output storage. `deploy/ladder-profiles.json` is runtime configuration mounted into both analyzers, not application code.

Infrastructure starts at `infra/main.bicep`, with transport-specific modules under `infra/modules`. Kubernetes manifests now live under `deploy/k8s/base` and `deploy/k8s/overlays/*`; `scripts/deploy.ps1` generates a small runtime overlay, renders it with `kubectl kustomize`, writes `deploy/rendered.yaml`, and applies that rendered manifest.

## Repository-specific conventions

- Keep .NET and Rust behavior compatible whenever changing submissions, manifests, results, defaults, validation, Kubernetes annotations, path layout, profile selection, segmentation, parallelism allocation, or output naming. Rust manifests accept PascalCase aliases because they must read .NET-produced JSON; queue-facing JSON is camelCase.
- Preserve deterministic, retry-safe processing. Kubernetes names derive from a normalized job ID plus a stable hash. Segment files use zero-padded indexes and profile names. Encoders publish through unique staging files and skip already-complete canonical artifacts; do not replace this with nondeterministic names or overwrite-in-place behavior.
- The manifest is the handoff between analyzer and media Jobs. Add workflow data there, in both contract implementations, when downstream workers need it; keep environment variables for deployment/runtime wiring.
- Terminal results are emitted only for exhausted encode/audio failures or terminal stitch success/failure. Individual pod retries and successful encode completion are not terminal events. Result-report annotations provide deduplication.
- Preserve the global encoding budget semantics. The analyzer sets initial Indexed Job parallelism from `Encoding__MinParallelismPerJob`; the completion worker continuously reallocates `Encoding__MaxParallelism` across unfinished Jobs.
- Configuration uses .NET-style hierarchical names. Kubernetes ConfigMap keys use double underscores such as `Encoding__MaxParallelism`; .NET reads the equivalent `Encoding:MaxParallelism`, while Rust reads the double-underscore environment variable directly.
- Treat `deploy/k8s/base`, `deploy/k8s/overlays`, `deploy/ladder-profiles.json`, and Bicep sources as editable inputs. Do not hand-edit generated `deploy/rendered.yaml`, `deploy/.generated/`, or `infra/main.json`.
- Keep image naming aligned with `scripts/build-images.ps1`: transport suffixes identify control-plane images, while `-dotnet` and `-rust` suffixes identify media images. Rust package names are `analyzer`, `completion`, `encoder`, `audio-encoder`, and `stitcher`.
- Runtime containers are Linux, non-root, and expect FFmpeg/FFprobe under `/opt/ffmpeg/bin` in images, with `/usr/bin` as the local fallback. Preserve architecture-neutral application behavior; scheduling selects `amd64` or `arm64`.
- PowerShell automation requires PowerShell 7, sets `$ErrorActionPreference = "Stop"`, and checks `$LASTEXITCODE` after native commands. Keep Azure authentication identity-based; do not introduce storage keys, Service Bus connection strings, or ACR admin credentials.
