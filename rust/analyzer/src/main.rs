use anyhow::{anyhow, bail, Context, Result};
use azure_core::credentials::TokenCredential;
use azure_core::http::Url;
use azure_identity::{DeveloperToolsCredential, WorkloadIdentityCredential};
use azure_storage_queue::models::{QueueClientReceiveMessagesOptions, ReceivedMessage};
use azure_storage_queue::{QueueClient, QueueServiceClient};
use k8s_openapi::api::batch::v1::Job;
use kube::api::PostParams;
use kube::{Api, Client};
use serde_json::json;
use std::sync::Arc;
use std::time::Duration;
use video::{
    config,
    contracts::{
        job_name, VideoManifest, VideoSubmitted, AUDIO_BLOB_NAME_ANNOTATION,
        AUDIO_ENCODING_REQUIRED_ANNOTATION, CALCULATE_VMAF_ANNOTATION, JOB_ID_ANNOTATION,
        MEDIA_RUNTIME_ANNOTATION, OUTPUT_PATH_ANNOTATION, OUTPUT_TYPE_ANNOTATION,
    },
    media, parallelism, paths,
};

#[derive(Debug, Clone)]
struct AnalyzerConfig {
    namespace: String,
    input_storage_account: String,
    input_storage_container: String,
    input_mount_path: String,
    output_storage_account: String,
    output_storage_container: String,
    output_mount_path: String,
    working_container: String,
    workload_client_id: String,
    submission_queue: String,
    max_parallelism: i32,
    min_parallelism_per_job: i32,
    max_audio_duration_seconds: u32,
    default_parallelization_strategy: String,
    default_media_runtime: String,
    receive_visibility_timeout_seconds: i32,
    receive_poll_interval_seconds: u64,
    renew_visibility: bool,
    renew_interval_seconds: i32,
}

#[derive(Debug)]
struct AudioDurationExceeded {
    actual_seconds: f64,
    maximum_seconds: u32,
}

impl std::fmt::Display for AudioDurationExceeded {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            formatter,
            "Audio duration {:.3}s exceeds the configured maximum of {}s",
            self.actual_seconds, self.maximum_seconds
        )
    }
}

impl std::error::Error for AudioDurationExceeded {}

#[tokio::main]
async fn main() -> Result<()> {
    video::init_tracing();
    let cfg = AnalyzerConfig::from_env()?;

    let client = Client::try_default()
        .await
        .context("Failed to initialize in-cluster Kubernetes client")?;
    let jobs: Api<Job> = Api::namespaced(client, &cfg.namespace);

    let queue_client = queue_client(&cfg.output_storage_account, &cfg.submission_queue)?;

    tracing::info!(
        queue = %cfg.submission_queue,
        account = %cfg.output_storage_account,
        "Analyzer worker started"
    );

    loop {
        let received = queue_client
            .receive_messages(Some(QueueClientReceiveMessagesOptions {
                number_of_messages: Some(1),
                visibility_timeout: Some(cfg.receive_visibility_timeout_seconds),
                ..Default::default()
            }))
            .await
            .context("Failed to receive queue messages")?;
        let messages = received.into_model()?.items.unwrap_or_default();
        if messages.is_empty() {
            tokio::time::sleep(Duration::from_secs(cfg.receive_poll_interval_seconds)).await;
            continue;
        }

        for message in messages {
            if let Err(error) = handle_message(&cfg, &queue_client, &jobs, message).await {
                tracing::error!(%error, "Analyzer message handler failed");
            }
        }
    }
}

impl AnalyzerConfig {
    fn from_env() -> Result<Self> {
        let max_parallelism: i32 = config::setting("Encoding__MaxParallelism", "16")
            .parse()
            .context("Encoding__MaxParallelism is invalid")?;
        if max_parallelism < 1 {
            bail!("Encoding__MaxParallelism must be greater than zero");
        }

        let min_parallelism_per_job: i32 = config::setting("Encoding__MinParallelismPerJob", "2")
            .parse()
            .context("Encoding__MinParallelismPerJob is invalid")?;
        if min_parallelism_per_job < 1 || min_parallelism_per_job > max_parallelism {
            bail!("Encoding__MinParallelismPerJob must be between 1 and Encoding__MaxParallelism");
        }

        let max_audio_duration_seconds: u32 =
            config::setting("Encoding__MaxAudioDurationSeconds", "21600")
                .parse()
                .context("Encoding__MaxAudioDurationSeconds is invalid")?;
        if max_audio_duration_seconds < 1 {
            bail!("Encoding__MaxAudioDurationSeconds must be greater than zero");
        }

        let receive_visibility_timeout_seconds: i32 =
            config::setting("Storage__QueueVisibilityTimeoutSeconds", "900")
                .parse()
                .context("Storage__QueueVisibilityTimeoutSeconds is invalid")?;
        if !(1..=604800).contains(&receive_visibility_timeout_seconds) {
            bail!("Storage__QueueVisibilityTimeoutSeconds must be between 1 and 604800");
        }

        let renew_interval_seconds: i32 =
            config::setting("Storage__QueueVisibilityRenewalSeconds", "120")
                .parse()
                .context("Storage__QueueVisibilityRenewalSeconds is invalid")?;
        if renew_interval_seconds < 1
            || renew_interval_seconds >= receive_visibility_timeout_seconds
        {
            bail!("Storage__QueueVisibilityRenewalSeconds must be positive and less than Storage__QueueVisibilityTimeoutSeconds");
        }

        let receive_poll_interval_seconds = config::setting("Storage__QueuePollSeconds", "3")
            .parse()
            .context("Storage__QueuePollSeconds is invalid")?;
        if receive_poll_interval_seconds < 1 {
            bail!("Storage__QueuePollSeconds must be greater than zero");
        }

        Ok(Self {
            namespace: config::setting("Kubernetes__Namespace", "video-storagequeue"),
            input_storage_account: config::required("Storage__InputAccountName")?,
            input_storage_container: config::required("Storage__InputContainer")?,
            input_mount_path: config::setting("Storage__InputMountPath", "/mnt/input"),
            output_storage_account: config::required("Storage__OutputAccountName")?,
            output_storage_container: config::required("Storage__OutputContainer")?,
            output_mount_path: config::setting("Storage__OutputMountPath", "/mnt/output"),
            working_container: config::setting("Storage__WorkingContainer", "videos"),
            workload_client_id: config::required("WorkloadIdentity__ClientId")?,
            submission_queue: config::setting("Storage__SubmissionQueue", "video-submitted"),
            max_parallelism,
            min_parallelism_per_job,
            max_audio_duration_seconds,
            default_parallelization_strategy: config::setting(
                "Encoding__ParallelizationStrategy",
                "fixed-duration",
            ),
            default_media_runtime: config::setting("Encoding__MediaRuntimeDefault", "rust"),
            receive_visibility_timeout_seconds,
            receive_poll_interval_seconds,
            renew_visibility: config::setting("Storage__QueueVisibilityRenew", "true")
                .parse()
                .context("Storage__QueueVisibilityRenew is invalid")?,
            renew_interval_seconds,
        })
    }
}

async fn handle_message(
    cfg: &AnalyzerConfig,
    queue_client: &QueueClient,
    jobs: &Api<Job>,
    message: ReceivedMessage,
) -> Result<()> {
    let message_id = message
        .message_id
        .clone()
        .context("Queue message did not include message_id")?;
    let mut pop_receipt = message
        .pop_receipt
        .clone()
        .context("Queue message did not include pop_receipt")?;
    let body = message
        .message_text
        .clone()
        .context("Queue message body is empty")?;

    let request: VideoSubmitted = match serde_json::from_str(&body) {
        Ok(value) => value,
        Err(error) => {
            tracing::warn!(%message_id, %error, "Invalid JSON payload; deleting message");
            delete_message(queue_client, &message_id, &pop_receipt).await?;
            return Ok(());
        }
    };

    if let Err(error) = validate_submission(&request) {
        tracing::warn!(%message_id, %error, "Invalid submission payload; deleting message");
        delete_message(queue_client, &message_id, &pop_receipt).await?;
        return Ok(());
    }

    let mut renew_handle = None;
    if cfg.renew_visibility {
        renew_handle = Some(start_renewal_task(
            cfg.output_storage_account.clone(),
            cfg.submission_queue.clone(),
            message_id.clone(),
            pop_receipt.clone(),
            cfg.receive_visibility_timeout_seconds,
            cfg.renew_interval_seconds,
        ));
    }

    let processing_result = process_submission(cfg, jobs, &request).await;

    if let Some(handle) = renew_handle {
        handle.stop.send_replace(true);
        if let Ok(Some(value)) = handle.task.await {
            pop_receipt = value;
        }
    }

    match processing_result {
        Ok(()) => {
            delete_message(queue_client, &message_id, &pop_receipt).await?;
            tracing::info!(job_id = %request.job_id, "Analyzer completed submission");
        }
        Err(error) if error.downcast_ref::<AudioDurationExceeded>().is_some() => {
            delete_message(queue_client, &message_id, &pop_receipt).await?;
            tracing::warn!(job_id = %request.job_id, %error, "Submission exceeded the audio duration limit; deleting message");
        }
        Err(error) => {
            tracing::error!(job_id = %request.job_id, %error, "Analyzer failed; message will become visible again");
        }
    }

    Ok(())
}

struct RenewalHandle {
    stop: tokio::sync::watch::Sender<bool>,
    task: tokio::task::JoinHandle<Option<String>>,
}

fn start_renewal_task(
    account: String,
    queue_name: String,
    message_id: String,
    pop_receipt: String,
    visibility_timeout_seconds: i32,
    renew_interval_seconds: i32,
) -> RenewalHandle {
    let (stop_tx, mut stop_rx) = tokio::sync::watch::channel(false);
    let task = tokio::spawn(async move {
        let queue_client = match queue_client(&account, &queue_name) {
            Ok(client) => client,
            Err(error) => {
                tracing::warn!(%message_id, %error, "Queue renewal task could not create queue client");
                return Some(pop_receipt);
            }
        };
        let mut receipt = pop_receipt;
        loop {
            tokio::select! {
                _ = tokio::time::sleep(Duration::from_secs(renew_interval_seconds as u64)) => {}
                changed = stop_rx.changed() => {
                    if changed.is_ok() && *stop_rx.borrow() {
                        return Some(receipt);
                    }
                }
            }

            match queue_client
                .update_message(&message_id, &receipt, visibility_timeout_seconds, None)
                .await
            {
                Ok(response) => {
                    let (_, headers, _) = response.deconstruct();
                    let mut next_receipt = None;
                    for (name, value) in headers.iter() {
                        if name.as_str().eq_ignore_ascii_case("x-ms-popreceipt") {
                            next_receipt = Some(value.as_str().to_owned());
                            break;
                        }
                    }
                    if let Some(value) = next_receipt {
                        receipt = value;
                    }
                }
                Err(error) => {
                    tracing::warn!(%message_id, %error, "Queue visibility renewal failed");
                    return Some(receipt);
                }
            }
        }
    });
    RenewalHandle {
        stop: stop_tx,
        task,
    }
}

async fn process_submission(
    cfg: &AnalyzerConfig,
    jobs: &Api<Job>,
    request: &VideoSubmitted,
) -> Result<()> {
    let analysis_stage_id = job_name("analysis", &request.job_id);
    let input_path = paths::from_uri(
        &request.input_video_uri,
        &cfg.input_storage_account,
        &cfg.input_storage_container,
        std::path::Path::new(&cfg.input_mount_path),
    )?;
    let output_mount = std::path::PathBuf::from(&cfg.output_mount_path);
    let audio_blob_name = format!("{}/segments/audio.m4a", request.job_id);
    let audio_path = paths::from_blob_name(&audio_blob_name, &output_mount)?;

    let media_info = media::probe(&input_path)?;
    if media_info.audio_duration_seconds > f64::from(cfg.max_audio_duration_seconds) {
        return Err(AudioDurationExceeded {
            actual_seconds: media_info.audio_duration_seconds,
            maximum_seconds: cfg.max_audio_duration_seconds,
        }
        .into());
    }
    let segment_duration_seconds = calculate_segment_duration_seconds(
        media_info.duration_seconds,
        cfg.max_parallelism,
        request.segment_duration_seconds,
    );

    let profile = media::select_profile(
        &media_info,
        &request.video_codec,
        request.preset.clone(),
        request.crf,
        request.max_video_bitrate_kbps,
    );

    let audio_encoding_required = !request.audio_codec.eq_ignore_ascii_case("copy");
    if !audio_encoding_required {
        media::extract_audio(&input_path, &audio_path, &request.audio_codec)?;
    }

    let strategy = request
        .parallelization_strategy
        .clone()
        .unwrap_or_else(|| cfg.default_parallelization_strategy.clone())
        .to_ascii_lowercase();

    let segments = match strategy.as_str() {
        "fixed-duration" => parallelism::fixed_duration_segments(
            media_info.duration_seconds,
            segment_duration_seconds,
        ),
        "keyframe-boundary" => {
            let keyframes = media::keyframe_times(&input_path, media_info.duration_seconds)?;
            parallelism::keyframe_segments(
                media_info.duration_seconds,
                segment_duration_seconds,
                keyframes,
            )
        }
        other => bail!("Unsupported parallelization strategy '{other}'"),
    };

    if segments.is_empty() {
        bail!("Parallelization strategy produced no segments");
    }

    let media_runtime = normalize_media_runtime(
        request
            .media_runtime
            .as_deref()
            .unwrap_or(&cfg.default_media_runtime),
    )?;

    let output_type = video::contracts::normalize_output_type(&request.output_type)
        .map_err(anyhow::Error::msg)?;
    let manifest = VideoManifest {
        job_id: request.job_id.clone(),
        input_video_uri: request.input_video_uri.clone(),
        output_path: request.output_path.clone(),
        working_container: cfg.working_container.clone(),
        audio_blob_name: audio_blob_name.clone(),
        duration: format_dotnet_timespan(media_info.duration_seconds),
        segment_duration_seconds,
        segment_count: segments.len(),
        segments,
        video_codec: request.video_codec.clone(),
        audio_codec: request.audio_codec.clone(),
        preset: profile.preset,
        crf: profile.crf,
        max_video_bitrate_kbps: profile.max_video_bitrate_kbps,
        use_spot: request.use_spot,
        calculate_vmaf: request.calculate_vmaf,
        output_type: output_type.to_owned(),
    };

    write_manifest(&manifest, &output_mount)?;
    submit_encoding_job(
        cfg,
        jobs,
        &manifest,
        media_runtime,
        request.architecture.as_deref(),
    )
    .await?;
    if audio_encoding_required {
        submit_audio_encoding_job(
            cfg,
            jobs,
            &manifest,
            media_runtime,
            request.architecture.as_deref(),
        )
        .await?;
    }

    tracing::info!(
        job_id = %manifest.job_id,
        stage_id = %analysis_stage_id,
        segment_count = manifest.segment_count,
        segment_duration_seconds = manifest.segment_duration_seconds,
        strategy = %strategy,
        media_runtime = %media_runtime,
        "Analyzer created/verified encode job"
    );

    Ok(())
}

fn write_manifest(manifest: &VideoManifest, output_mount: &std::path::Path) -> Result<()> {
    let manifest_path =
        paths::from_blob_name(&format!("{}/manifest.json", manifest.job_id), output_mount)?;
    if let Some(parent) = manifest_path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(manifest_path, serde_json::to_vec(manifest)?)?;
    Ok(())
}

async fn submit_encoding_job(
    cfg: &AnalyzerConfig,
    jobs: &Api<Job>,
    manifest: &VideoManifest,
    media_runtime: &str,
    requested_architecture: Option<&str>,
) -> Result<()> {
    let encode_job_name = job_name("encode", &manifest.job_id);

    match jobs.get(&encode_job_name).await {
        Ok(_) => return Ok(()),
        Err(kube::Error::Api(error)) if error.code == 404 => {}
        Err(error) => return Err(error).context("Failed to check for existing encode job"),
    }

    let architecture = match requested_architecture {
        Some("amd64") => Some("amd64"),
        Some("arm64") => Some("arm64"),
        Some(other) => bail!("architecture must be amd64 or arm64; got '{other}'"),
        None => None,
    };

    let annotations = json!({
        JOB_ID_ANNOTATION: manifest.job_id,
        AUDIO_BLOB_NAME_ANNOTATION: manifest.audio_blob_name,
        AUDIO_ENCODING_REQUIRED_ANNOTATION: (!manifest.audio_codec.eq_ignore_ascii_case("copy")).to_string(),
        OUTPUT_PATH_ANNOTATION: manifest.output_path.to_string(),
        OUTPUT_TYPE_ANNOTATION: manifest.output_type,
        CALCULATE_VMAF_ANNOTATION: if manifest.calculate_vmaf { "true" } else { "false" },
        MEDIA_RUNTIME_ANNOTATION: media_runtime,
    });
    let mut node_selector = json!({
        "workload": "video-encoding",
        "kubernetes.azure.com/scalesetpriority": if manifest.use_spot { "spot" } else { "regular" },
        "kubernetes.io/os": "linux",
    });
    if let Some(arch) = architecture {
        node_selector["kubernetes.io/arch"] = json!(arch);
    }

    let encoder_image = required_image(media_runtime, "Encoder")?;

    let job_json = json!({
        "apiVersion": "batch/v1",
        "kind": "Job",
        "metadata": {
            "name": encode_job_name,
            "labels": {
                "app.kubernetes.io/name": "video-encoder",
                "video/job-id": video::contracts::label_value(&manifest.job_id),
                "azure.workload.identity/use": "true"
            },
            "annotations": annotations
        },
        "spec": {
            "completionMode": "Indexed",
            "completions": manifest.segment_count,
            "parallelism": std::cmp::min(manifest.segment_count as i32, cfg.min_parallelism_per_job),
            "backoffLimitPerIndex": 5,
            "ttlSecondsAfterFinished": 86400,
            "template": {
                "metadata": {
                    "labels": {
                        "app.kubernetes.io/name": "video-encoder",
                        "video/job-id": video::contracts::label_value(&manifest.job_id),
                        "azure.workload.identity/use": "true"
                    }
                },
                "spec": {
                    "serviceAccountName": "video-worker",
                    "restartPolicy": "Never",
                    "terminationGracePeriodSeconds": 120,
                    "nodeSelector": node_selector,
                    "tolerations": manifest.use_spot.then(|| vec![json!({
                        "key": "kubernetes.azure.com/scalesetpriority",
                        "operator": "Equal",
                        "value": "spot",
                        "effect": "NoSchedule"
                    })]),
                    "volumes": [
                        {
                            "name": "input-storage",
                            "csi": {
                                "driver": "blob.csi.azure.com",
                                "readOnly": true,
                                "volumeAttributes": {
                                    "protocol": "fuse2",
                                    "storageAccount": cfg.input_storage_account,
                                    "containerName": cfg.input_storage_container,
                                    "ClientID": cfg.workload_client_id,
                                    "mountWithWorkloadIdentityToken": "true",
                                    "mountOptions": "--allow-other --use-attr-cache=true --cancel-list-on-mount-seconds=10"
                                }
                            }
                        },
                        {
                            "name": "output-storage",
                            "csi": {
                                "driver": "blob.csi.azure.com",
                                "readOnly": false,
                                "volumeAttributes": {
                                    "protocol": "fuse2",
                                    "storageAccount": cfg.output_storage_account,
                                    "containerName": cfg.output_storage_container,
                                    "ClientID": cfg.workload_client_id,
                                    "mountWithWorkloadIdentityToken": "true",
                                    "mountOptions": "--allow-other --use-attr-cache=true --disable-writeback-cache=true"
                                }
                            }
                        }
                    ],
                    "containers": [
                        {
                            "name": "encoder",
                            "image": encoder_image,
                            "env": [
                                {
                                    "name": "JOB_COMPLETION_INDEX",
                                    "valueFrom": {
                                        "fieldRef": {
                                            "fieldPath": "metadata.annotations['batch.kubernetes.io/job-completion-index']"
                                        }
                                    }
                                },
                                { "name": "JOB_ID", "value": manifest.job_id },
                                { "name": "SOURCE_VIDEO_URI", "value": manifest.input_video_uri.to_string() },
                                { "name": "VIDEO_CODEC", "value": manifest.video_codec },
                                { "name": "PRESET", "value": manifest.preset },
                                { "name": "CRF", "value": manifest.crf.to_string() },
                                { "name": "MAX_VIDEO_BITRATE_KBPS", "value": manifest.max_video_bitrate_kbps.to_string() },
                                { "name": "CALCULATE_VMAF", "value": if manifest.calculate_vmaf { "true" } else { "false" } },
                                { "name": "INPUT_STORAGE_ACCOUNT_NAME", "value": cfg.input_storage_account },
                                { "name": "INPUT_STORAGE_CONTAINER", "value": cfg.input_storage_container },
                                { "name": "INPUT_MOUNT_PATH", "value": cfg.input_mount_path },
                                { "name": "OUTPUT_STORAGE_ACCOUNT_NAME", "value": cfg.output_storage_account },
                                { "name": "OUTPUT_STORAGE_CONTAINER", "value": cfg.output_storage_container },
                                { "name": "OUTPUT_MOUNT_PATH", "value": cfg.output_mount_path }
                            ],
                            "volumeMounts": [
                                { "name": "input-storage", "mountPath": cfg.input_mount_path, "readOnly": true },
                                { "name": "output-storage", "mountPath": cfg.output_mount_path }
                            ],
                            "resources": {
                                "requests": { "cpu": "1750m", "memory": "4Gi" },
                                "limits": { "cpu": "4", "memory": "8Gi" }
                            }
                        }
                    ]
                }
            }
        }
    });

    let job: Job = serde_json::from_value(job_json).context("Failed to serialize encode job")?;
    match jobs.create(&PostParams::default(), &job).await {
        Ok(_) => Ok(()),
        Err(kube::Error::Api(error)) if error.code == 409 => Ok(()),
        Err(error) => Err(error).context("Failed to create encode job"),
    }
}

async fn submit_audio_encoding_job(
    cfg: &AnalyzerConfig,
    jobs: &Api<Job>,
    manifest: &VideoManifest,
    media_runtime: &str,
    requested_architecture: Option<&str>,
) -> Result<()> {
    let audio_job_name = job_name("audio", &manifest.job_id);
    match jobs.get(&audio_job_name).await {
        Ok(_) => return Ok(()),
        Err(kube::Error::Api(error)) if error.code == 404 => {}
        Err(error) => return Err(error).context("Failed to check for existing audio encode job"),
    }

    let architecture = match requested_architecture {
        Some("amd64") => Some("amd64"),
        Some("arm64") => Some("arm64"),
        Some(other) => bail!("architecture must be amd64 or arm64; got '{other}'"),
        None => None,
    };
    let annotations = json!({ JOB_ID_ANNOTATION: manifest.job_id });
    let mut node_selector = json!({
        "workload": "video-encoding",
        "kubernetes.azure.com/scalesetpriority": if manifest.use_spot { "spot" } else { "regular" },
        "kubernetes.io/os": "linux",
    });
    if let Some(arch) = architecture {
        node_selector["kubernetes.io/arch"] = json!(arch);
    }

    let audio_encoder_image = required_image(media_runtime, "AudioEncoder")?;
    let job_json = json!({
        "apiVersion": "batch/v1",
        "kind": "Job",
        "metadata": {
            "name": audio_job_name,
            "labels": {
                "app.kubernetes.io/name": "video-audio-encoder",
                "video/job-id": video::contracts::label_value(&manifest.job_id),
                "azure.workload.identity/use": "true"
            },
            "annotations": annotations
        },
        "spec": {
            "backoffLimit": 6,
            "ttlSecondsAfterFinished": 86400,
            "template": {
                "metadata": { "labels": {
                    "app.kubernetes.io/name": "video-audio-encoder",
                    "video/job-id": video::contracts::label_value(&manifest.job_id),
                    "azure.workload.identity/use": "true"
                }},
                "spec": {
                    "serviceAccountName": "video-worker",
                    "restartPolicy": "Never",
                    "terminationGracePeriodSeconds": 120,
                    "nodeSelector": node_selector,
                    "tolerations": manifest.use_spot.then(|| vec![json!({
                        "key": "kubernetes.azure.com/scalesetpriority",
                        "operator": "Equal",
                        "value": "spot",
                        "effect": "NoSchedule"
                    })]),
                    "volumes": [
                        { "name": "input-storage", "csi": {
                            "driver": "blob.csi.azure.com", "readOnly": true,
                            "volumeAttributes": {
                                "protocol": "fuse2", "storageAccount": cfg.input_storage_account,
                                "containerName": cfg.input_storage_container, "ClientID": cfg.workload_client_id,
                                "mountWithWorkloadIdentityToken": "true",
                                "mountOptions": "--allow-other --use-attr-cache=true --cancel-list-on-mount-seconds=10"
                            }
                        }},
                        { "name": "output-storage", "csi": {
                            "driver": "blob.csi.azure.com", "readOnly": false,
                            "volumeAttributes": {
                                "protocol": "fuse2", "storageAccount": cfg.output_storage_account,
                                "containerName": cfg.output_storage_container, "ClientID": cfg.workload_client_id,
                                "mountWithWorkloadIdentityToken": "true",
                                "mountOptions": "--allow-other --use-attr-cache=true --disable-writeback-cache=true"
                            }
                        }}
                    ],
                    "containers": [{
                        "name": "audio-encoder",
                        "image": audio_encoder_image,
                        "env": [
                            { "name": "JOB_ID", "value": manifest.job_id },
                            { "name": "SOURCE_VIDEO_URI", "value": manifest.input_video_uri.to_string() },
                            { "name": "AUDIO_BLOB_NAME", "value": manifest.audio_blob_name },
                            { "name": "AUDIO_CODEC", "value": manifest.audio_codec },
                            { "name": "INPUT_STORAGE_ACCOUNT_NAME", "value": cfg.input_storage_account },
                            { "name": "INPUT_STORAGE_CONTAINER", "value": cfg.input_storage_container },
                            { "name": "INPUT_MOUNT_PATH", "value": cfg.input_mount_path },
                            { "name": "OUTPUT_MOUNT_PATH", "value": cfg.output_mount_path }
                        ],
                        "volumeMounts": [
                            { "name": "input-storage", "mountPath": cfg.input_mount_path, "readOnly": true },
                            { "name": "output-storage", "mountPath": cfg.output_mount_path }
                        ],
                        "resources": {
                            "requests": { "cpu": "1", "memory": "1Gi" },
                            "limits": { "cpu": "2", "memory": "2Gi" }
                        }
                    }]
                }
            }
        }
    });

    let job: Job =
        serde_json::from_value(job_json).context("Failed to serialize audio encode job")?;
    match jobs.create(&PostParams::default(), &job).await {
        Ok(_) => Ok(()),
        Err(kube::Error::Api(error)) if error.code == 409 => Ok(()),
        Err(error) => Err(error).context("Failed to create audio encode job"),
    }
}

fn calculate_segment_duration_seconds(
    duration_seconds: f64,
    max_parallelism: i32,
    minimum_segment_duration_seconds: u32,
) -> u32 {
    let duration_per_worker = (duration_seconds / f64::from(max_parallelism)).ceil() as u32;
    let maximum_segment_duration_seconds = std::cmp::max(180, minimum_segment_duration_seconds);
    duration_per_worker.clamp(
        minimum_segment_duration_seconds,
        maximum_segment_duration_seconds,
    )
}

fn validate_submission(request: &VideoSubmitted) -> Result<()> {
    if request.job_id.trim().is_empty() || request.job_id.len() > 128 {
        bail!("JobId must contain 1-128 characters");
    }
    if request.input_video_uri.scheme() != "https" {
        bail!("InputVideoUri must use HTTPS");
    }
    if request.output_path.scheme() != "https" {
        bail!("OutputPath must use HTTPS");
    }
    if request.output_path.path().ends_with('/') {
        bail!("OutputPath must include a base filename");
    }
    if std::path::Path::new(request.output_path.path())
        .extension()
        .is_some()
    {
        bail!("OutputPath base filename must not include an extension");
    }
    if !(5..=3600).contains(&request.segment_duration_seconds) {
        bail!("SegmentDurationSeconds must be between 5 and 3600");
    }
    if request.crf.is_some_and(|value| value > 63) {
        bail!("Crf must be between 0 and 63");
    }
    if request
        .max_video_bitrate_kbps
        .is_some_and(|value| !(64..=100_000).contains(&value))
    {
        bail!("MaxVideoBitrateKbps must be between 64 and 100000");
    }
    if request.audio_codec.trim().is_empty() {
        bail!("AudioCodec is required");
    }
    Ok(())
}

fn required_image(media_runtime: &str, role: &str) -> Result<String> {
    let runtime = normalize_media_runtime(media_runtime)?;
    let key = format!("Images__{}__{}", capitalize(runtime), role);
    std::env::var(&key)
        .or_else(|_| std::env::var(format!("Images__{role}")))
        .map_err(|_| anyhow!("{key} is required"))
}

fn normalize_media_runtime(value: &str) -> Result<&'static str> {
    match value.to_ascii_lowercase().as_str() {
        "dotnet" => Ok("dotnet"),
        "rust" => Ok("rust"),
        _ => bail!("MediaRuntime must be dotnet or rust"),
    }
}

fn capitalize(value: &str) -> &'static str {
    match value {
        "dotnet" => "Dotnet",
        "rust" => "Rust",
        _ => "",
    }
}

fn queue_client(account: &str, queue_name: &str) -> Result<QueueClient> {
    let service_url = Url::parse(&format!("https://{account}.queue.core.windows.net/"))?;
    let credential = build_credential()?;
    let service_client = QueueServiceClient::new(service_url, Some(credential), None)?;
    service_client
        .queue_client(queue_name)
        .context("Failed to create queue client")
}

fn build_credential() -> Result<Arc<dyn TokenCredential>> {
    if std::env::var("AZURE_FEDERATED_TOKEN_FILE").is_ok() {
        return WorkloadIdentityCredential::new(None)
            .map(|credential| credential as Arc<dyn TokenCredential>)
            .context("Failed to initialize WorkloadIdentityCredential");
    }
    DeveloperToolsCredential::new(None)
        .map(|credential| credential as Arc<dyn TokenCredential>)
        .context("Failed to initialize DeveloperToolsCredential")
}

async fn delete_message(
    queue_client: &QueueClient,
    message_id: &str,
    pop_receipt: &str,
) -> Result<()> {
    queue_client
        .delete_message(message_id, pop_receipt, None)
        .await
        .with_context(|| format!("Failed to delete queue message {message_id}"))?;
    Ok(())
}

fn format_dotnet_timespan(duration_seconds: f64) -> String {
    let total_millis = (duration_seconds * 1000.0).round() as i64;
    let hours = total_millis / 3_600_000;
    let minutes = (total_millis % 3_600_000) / 60_000;
    let seconds = (total_millis % 60_000) / 1000;
    let millis = total_millis % 1000;
    format!("{hours:02}:{minutes:02}:{seconds:02}.{millis:03}")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn submission() -> VideoSubmitted {
        serde_json::from_value(json!({
            "jobId": "job-1",
            "inputVideoUri": "https://input.blob.core.windows.net/input/video.mp4",
            "outputPath": "https://output.blob.core.windows.net/videos/video",
            "segmentDurationSeconds": 60,
            "audioCodec": "copy"
        }))
        .unwrap()
    }

    #[test]
    fn validates_submission_contract() {
        assert!(validate_submission(&submission()).is_ok());

        let mut invalid = submission();
        invalid.segment_duration_seconds = 4;
        assert!(validate_submission(&invalid).is_err());

        let mut invalid = submission();
        invalid.output_path =
            Url::parse("https://output.blob.core.windows.net/videos/video.mp4").unwrap();
        assert!(validate_submission(&invalid).is_err());
    }

    #[test]
    fn calculates_bounded_segment_duration() {
        assert_eq!(calculate_segment_duration_seconds(600.0, 16, 60), 60);
        assert_eq!(calculate_segment_duration_seconds(7_200.0, 16, 60), 180);
    }

    #[test]
    fn formats_duration_for_cross_runtime_manifest() {
        assert_eq!(format_dotnet_timespan(3_661.125), "01:01:01.125");
    }
}
