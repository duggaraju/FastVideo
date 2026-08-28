use anyhow::{Context, Result, anyhow, bail};
use azure_core::credentials::TokenCredential;
use azure_core::http::Url;
use azure_identity::{DeveloperToolsCredential, WorkloadIdentityCredential};
use azure_storage_queue::models::QueueMessage;
use azure_storage_queue::{QueueClient, QueueServiceClient};
use k8s_openapi::api::batch::v1::Job;
use kube::api::{DeleteParams, Patch, PatchParams, PostParams};
use kube::{Api, Client};
use serde_json::json;
use std::sync::Arc;
use video::{
    config,
    contracts::{
        AUDIO_BLOB_NAME_ANNOTATION, AUDIO_ENCODING_REQUIRED_ANNOTATION, CALCULATE_VMAF_ANNOTATION,
        JOB_ID_ANNOTATION, MEDIA_RUNTIME_ANNOTATION, OUTPUT_PATH_ANNOTATION,
        OUTPUT_TYPE_ANNOTATION, RESULT_REPORTED_ANNOTATION, VideoProcessingResult, job_name,
    },
    parallelism,
};

#[derive(Debug, Clone)]
struct CompletionConfig {
    namespace: String,
    output_storage_account: String,
    output_storage_container: String,
    output_mount_path: String,
    workload_client_id: String,
    result_queue: String,
    max_parallelism: i32,
    default_media_runtime: String,
    poll_seconds: u64,
}

#[tokio::main]
async fn main() -> Result<()> {
    video::init_tracing();
    let cfg = CompletionConfig::from_env()?;

    let client = Client::try_default()
        .await
        .context("Failed to initialize in-cluster Kubernetes client")?;
    let jobs: Api<Job> = Api::namespaced(client, &cfg.namespace);
    let result_queue = queue_client(&cfg.output_storage_account, &cfg.result_queue)?;

    tracing::info!(queue = %cfg.result_queue, "Completion worker started");
    let mut interval = tokio::time::interval(std::time::Duration::from_secs(cfg.poll_seconds));

    loop {
        interval.tick().await;
        if let Err(error) = reconcile_once(&cfg, &jobs, &result_queue).await {
            tracing::error!(%error, "Completion reconciliation iteration failed");
        }
    }
}

impl CompletionConfig {
    fn from_env() -> Result<Self> {
        let max_parallelism: i32 = config::setting("Encoding__MaxParallelism", "16")
            .parse()
            .context("Encoding__MaxParallelism is invalid")?;
        if max_parallelism < 1 {
            bail!("Encoding__MaxParallelism must be greater than zero");
        }

        Ok(Self {
            namespace: config::setting("Kubernetes__Namespace", "video-storagequeue"),
            output_storage_account: config::required("Storage__OutputAccountName")?,
            output_storage_container: config::required("Storage__OutputContainer")?,
            output_mount_path: config::setting("Storage__OutputMountPath", "/mnt/output"),
            workload_client_id: config::required("WorkloadIdentity__ClientId")?,
            result_queue: config::setting("Storage__ResultQueue", "video-results"),
            max_parallelism,
            default_media_runtime: config::setting("Encoding__MediaRuntimeDefault", "rust"),
            poll_seconds: positive_interval("Completion__PollSeconds", "10")?,
        })
    }
}

async fn reconcile_once(
    cfg: &CompletionConfig,
    jobs: &Api<Job>,
    result_queue: &QueueClient,
) -> Result<()> {
    let encode_jobs = jobs
        .list(&kube::api::ListParams::default().labels("app.kubernetes.io/name=video-encoder"))
        .await
        .context("Failed to list encode jobs")?;
    let audio_jobs = jobs
        .list(
            &kube::api::ListParams::default().labels("app.kubernetes.io/name=video-audio-encoder"),
        )
        .await
        .context("Failed to list audio encode jobs")?;

    rebalance_encoding_jobs(cfg.max_parallelism, jobs, &encode_jobs.items).await?;

    for job in encode_jobs
        .items
        .iter()
        .filter(|job| has_condition(job, "Complete"))
    {
        let audio_encoding_required = annotation(job, AUDIO_ENCODING_REQUIRED_ANNOTATION)
            .is_some_and(|value| value.eq_ignore_ascii_case("true"));
        if audio_encoding_required {
            let Some(job_id) = annotation(job, JOB_ID_ANNOTATION) else {
                continue;
            };
            let audio_complete = audio_jobs.items.iter().any(|audio_job| {
                annotation(audio_job, JOB_ID_ANNOTATION).as_deref() == Some(job_id.as_str())
                    && has_condition(audio_job, "Complete")
            });
            if !audio_complete {
                continue;
            }
        }
        submit_stitch_job(cfg, jobs, job).await?;
    }

    for job in encode_jobs
        .items
        .iter()
        .filter(|job| has_condition(job, "Failed"))
    {
        let Some(job_id) = annotation(job, JOB_ID_ANNOTATION) else {
            tracing::warn!(job = ?job.metadata.name, "Failed encode job missing job-id annotation");
            continue;
        };
        if audio_jobs.items.iter().any(|audio_job| {
            annotation(audio_job, JOB_ID_ANNOTATION).as_deref() == Some(job_id.as_str())
                && has_condition(audio_job, "Failed")
        }) {
            continue;
        }
        let failure_reason = condition_message(job, "Failed");
        report_result(
            jobs,
            result_queue,
            job,
            VideoProcessingResult {
                job_id,
                succeeded: false,
                terminal_stage: "encode".to_owned(),
                failed_indexes: job
                    .status
                    .as_ref()
                    .and_then(|status| status.failed_indexes.clone()),
                failure_reason,
                completed_at: chrono_timestamp(),
            },
        )
        .await?;
    }

    for audio_job in audio_jobs
        .items
        .iter()
        .filter(|job| has_condition(job, "Failed"))
    {
        let Some(job_id) = annotation(audio_job, JOB_ID_ANNOTATION) else {
            tracing::warn!(job = ?audio_job.metadata.name, "Failed audio encode job missing job-id annotation");
            continue;
        };
        report_result(
            jobs,
            result_queue,
            audio_job,
            VideoProcessingResult {
                job_id,
                succeeded: false,
                terminal_stage: "audio-encode".to_owned(),
                failed_indexes: None,
                failure_reason: condition_message(audio_job, "Failed"),
                completed_at: chrono_timestamp(),
            },
        )
        .await?;
    }

    let stitch_jobs = jobs
        .list(&kube::api::ListParams::default().labels("app.kubernetes.io/name=video-stitcher"))
        .await
        .context("Failed to list stitch jobs")?;

    for stitch_job in &stitch_jobs.items {
        let succeeded = has_condition(stitch_job, "Complete");
        let failed = has_condition(stitch_job, "Failed");
        if !succeeded && !failed {
            continue;
        }

        let Some(job_id) = annotation(stitch_job, JOB_ID_ANNOTATION) else {
            tracing::warn!(job = ?stitch_job.metadata.name, "Terminal stitch job missing job-id annotation");
            continue;
        };

        report_result(
            jobs,
            result_queue,
            stitch_job,
            VideoProcessingResult {
                job_id: job_id.clone(),
                succeeded,
                terminal_stage: "stitch".to_owned(),
                failed_indexes: None,
                failure_reason: condition_message(stitch_job, "Failed"),
                completed_at: chrono_timestamp(),
            },
        )
        .await?;

        if succeeded {
            for producer_job_name in [job_name("encode", &job_id), job_name("audio", &job_id)] {
                if let Err(error) = jobs
                    .delete(&producer_job_name, &DeleteParams::background())
                    .await
                    && !is_not_found(&error)
                {
                    return Err(error).context("Failed to delete completed producer job");
                }
            }
        }
    }

    Ok(())
}

async fn rebalance_encoding_jobs(
    max_parallelism: i32,
    jobs_api: &Api<Job>,
    jobs: &[Job],
) -> Result<()> {
    let active_jobs = jobs
        .iter()
        .filter(|job| !has_condition(job, "Complete") && !has_condition(job, "Failed"))
        .collect::<Vec<_>>();

    let demands = active_jobs
        .iter()
        .filter_map(|job| {
            let name = job.metadata.name.clone()?;
            let completions = job.spec.as_ref()?.completions.unwrap_or_default();
            let succeeded = job.status.as_ref()?.succeeded.unwrap_or_default();
            Some(parallelism::EncodingJobDemand {
                name,
                remaining_segments: std::cmp::max(0, completions - succeeded),
            })
        })
        .collect::<Vec<_>>();

    let allocations = parallelism::allocate(demands, max_parallelism)?;
    for active in active_jobs {
        let Some(name) = active.metadata.name.clone() else {
            continue;
        };
        let Some(desired_parallelism) = allocations.get(&name) else {
            continue;
        };
        let current_parallelism = active
            .spec
            .as_ref()
            .and_then(|spec| spec.parallelism)
            .unwrap_or_default();
        if current_parallelism == *desired_parallelism {
            continue;
        }

        let patch = Patch::Merge(json!({
            "spec": {
                "parallelism": desired_parallelism
            }
        }));
        jobs_api
            .patch(&name, &PatchParams::default(), &patch)
            .await
            .with_context(|| format!("Failed to patch parallelism for job {name}"))?;
    }

    Ok(())
}

async fn submit_stitch_job(
    cfg: &CompletionConfig,
    jobs: &Api<Job>,
    encode_job: &Job,
) -> Result<()> {
    let annotations = encode_job
        .metadata
        .annotations
        .as_ref()
        .ok_or_else(|| anyhow!("Encode job has no annotations"))?;
    let job_id = annotations
        .get(JOB_ID_ANNOTATION)
        .cloned()
        .ok_or_else(|| anyhow!("Missing {JOB_ID_ANNOTATION} annotation"))?;
    let stitch_name = job_name("stitch", &job_id);

    match jobs.get(&stitch_name).await {
        Ok(_) => return Ok(()),
        Err(kube::Error::Api(error)) if error.code == 404 => {}
        Err(error) => return Err(error).context("Failed to check for existing stitch job"),
    }

    let segment_count = encode_job
        .spec
        .as_ref()
        .and_then(|spec| spec.completions)
        .ok_or_else(|| anyhow!("Encode job has no completion count"))?
        .to_string();
    let audio_blob_name = annotations
        .get(AUDIO_BLOB_NAME_ANNOTATION)
        .cloned()
        .ok_or_else(|| anyhow!("Missing {AUDIO_BLOB_NAME_ANNOTATION} annotation"))?;
    let output_path = annotations
        .get(OUTPUT_PATH_ANNOTATION)
        .cloned()
        .ok_or_else(|| anyhow!("Missing {OUTPUT_PATH_ANNOTATION} annotation"))?;
    let calculate_vmaf = annotations
        .get(CALCULATE_VMAF_ANNOTATION)
        .cloned()
        .unwrap_or_else(|| "false".to_owned());
    let output_type = annotations
        .get(OUTPUT_TYPE_ANNOTATION)
        .cloned()
        .unwrap_or_else(|| "mp4".to_owned());
    let encode_node_selector = encode_job
        .spec
        .as_ref()
        .and_then(|spec| spec.template.spec.as_ref())
        .and_then(|spec| spec.node_selector.as_ref());
    let use_spot = encode_node_selector
        .and_then(|selector| selector.get("kubernetes.azure.com/scalesetpriority"))
        .is_some_and(|priority| priority == "spot");
    let media_runtime = normalize_media_runtime(
        annotations
            .get(MEDIA_RUNTIME_ANNOTATION)
            .map(String::as_str)
            .unwrap_or(&cfg.default_media_runtime),
    )?;

    let mut node_selector = json!({
        "workload": "video-encoding",
        "kubernetes.azure.com/scalesetpriority": if use_spot { "spot" } else { "regular" },
        "kubernetes.io/os": "linux"
    });
    if let Some(arch) = encode_node_selector.and_then(|selector| selector.get("kubernetes.io/arch"))
    {
        node_selector["kubernetes.io/arch"] = json!(arch);
    }

    let stitch_image = required_image(media_runtime, "Stitcher")?;
    let stitch_job_json = json!({
        "apiVersion": "batch/v1",
        "kind": "Job",
        "metadata": {
            "name": stitch_name,
            "labels": {
                "app.kubernetes.io/name": "video-stitcher",
                "video/job-id": video::contracts::label_value(&job_id),
                "azure.workload.identity/use": "true"
            },
            "annotations": {
                JOB_ID_ANNOTATION: job_id,
            }
        },
        "spec": {
            "backoffLimit": 6,
            "ttlSecondsAfterFinished": 3600,
            "template": {
                "metadata": {
                    "labels": {
                        "app.kubernetes.io/name": "video-stitcher",
                        "video/job-id": video::contracts::label_value(&job_id),
                        "azure.workload.identity/use": "true"
                    }
                },
                "spec": {
                    "serviceAccountName": "video-worker",
                    "restartPolicy": "Never",
                    "terminationGracePeriodSeconds": 120,
                    "nodeSelector": node_selector,
                    "tolerations": use_spot.then(|| vec![json!({
                        "key": "kubernetes.azure.com/scalesetpriority",
                        "operator": "Equal",
                        "value": "spot",
                        "effect": "NoSchedule"
                    })]),
                    "volumes": [
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
                                    "mountOptions": "--allow-other --use-attr-cache=true --file-cache-timeout-in-seconds=30 --disable-writeback-cache=true"
                                }
                            }
                        }
                    ],
                    "containers": [
                        {
                            "name": "stitcher",
                            "image": stitch_image,
                            "env": [
                                { "name": "JOB_ID", "value": job_id },
                                { "name": "SEGMENT_COUNT", "value": segment_count },
                                { "name": "AUDIO_BLOB_NAME", "value": audio_blob_name },
                                { "name": "OUTPUT_PATH", "value": output_path },
                                { "name": "OUTPUT_TYPE", "value": output_type },
                                { "name": "CALCULATE_VMAF", "value": calculate_vmaf },
                                { "name": "OUTPUT_STORAGE_ACCOUNT_NAME", "value": cfg.output_storage_account },
                                { "name": "OUTPUT_STORAGE_CONTAINER", "value": cfg.output_storage_container },
                                { "name": "OUTPUT_MOUNT_PATH", "value": cfg.output_mount_path }
                            ],
                            "volumeMounts": [
                                { "name": "output-storage", "mountPath": cfg.output_mount_path }
                            ],
                            "resources": {
                                "requests": { "cpu": "1", "memory": "2Gi" },
                                "limits": { "cpu": "2", "memory": "4Gi" }
                            }
                        }
                    ]
                }
            }
        }
    });

    let job: Job =
        serde_json::from_value(stitch_job_json).context("Failed to serialize stitch job")?;
    match jobs.create(&PostParams::default(), &job).await {
        Ok(_) => Ok(()),
        Err(kube::Error::Api(error)) if error.code == 409 => Ok(()),
        Err(error) => Err(error).context("Failed to create stitch job"),
    }
}

async fn report_result(
    jobs: &Api<Job>,
    result_queue: &QueueClient,
    job: &Job,
    result: VideoProcessingResult,
) -> Result<()> {
    let Some(job_name) = job.metadata.name.clone() else {
        return Ok(());
    };
    if job
        .metadata
        .annotations
        .as_ref()
        .and_then(|ann| ann.get(RESULT_REPORTED_ANNOTATION))
        .is_some_and(|value| value == "true")
    {
        return Ok(());
    }

    let body = serde_json::to_string(&result)?;
    let message = QueueMessage {
        message_text: Some(body),
    };
    result_queue
        .send_message(message.try_into()?, None)
        .await
        .context("Failed to enqueue VideoProcessingResult")?;

    let patch = Patch::Merge(json!({
        "metadata": {
            "annotations": {
                RESULT_REPORTED_ANNOTATION: "true"
            }
        }
    }));
    jobs.patch(&job_name, &PatchParams::default(), &patch)
        .await
        .with_context(|| format!("Failed to mark result reported on job {job_name}"))?;

    tracing::info!(
        job_id = %result.job_id,
        succeeded = result.succeeded,
        terminal_stage = %result.terminal_stage,
        "Reported terminal video result"
    );

    Ok(())
}

fn has_condition(job: &Job, condition_type: &str) -> bool {
    job.status
        .as_ref()
        .and_then(|status| status.conditions.as_ref())
        .is_some_and(|conditions| {
            conditions
                .iter()
                .any(|condition| condition.type_ == condition_type && condition.status == "True")
        })
}

fn condition_message(job: &Job, condition_type: &str) -> Option<String> {
    job.status
        .as_ref()
        .and_then(|status| status.conditions.as_ref())
        .and_then(|conditions| {
            conditions
                .iter()
                .rev()
                .find(|condition| condition.type_ == condition_type && condition.status == "True")
                .and_then(|condition| {
                    condition
                        .message
                        .clone()
                        .or_else(|| condition.reason.clone())
                })
        })
}

fn annotation(job: &Job, name: &str) -> Option<String> {
    job.metadata
        .annotations
        .as_ref()
        .and_then(|annotations| annotations.get(name))
        .cloned()
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

fn is_not_found(error: &kube::Error) -> bool {
    matches!(error, kube::Error::Api(err) if err.code == 404)
}

fn chrono_timestamp() -> String {
    time::OffsetDateTime::now_utc()
        .format(&time::format_description::well_known::Rfc3339)
        .unwrap_or_else(|_| "1970-01-01T00:00:00Z".to_owned())
}

fn positive_interval(name: &str, default: &str) -> Result<u64> {
    let value = config::setting(name, default)
        .parse()
        .with_context(|| format!("{name} is invalid"))?;
    if value < 1 {
        bail!("{name} must be greater than zero");
    }
    Ok(value)
}
