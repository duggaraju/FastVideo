use anyhow::{Context, Result, anyhow, bail};
use azure_core::credentials::TokenCredential;
use azure_core::http::Url;
use azure_identity::{DeveloperToolsCredential, WorkloadIdentityCredential};
use azure_storage_queue::models::QueueMessage;
use azure_storage_queue::{QueueClient, QueueServiceClient};
use k8s_openapi::api::batch::v1::{Job, JobSpec};
use k8s_openapi::api::coordination::v1::Lease;
use k8s_openapi::api::core::v1::{Container, PodSpec};
use k8s_openapi::apimachinery::pkg::apis::meta::v1::ObjectMeta;
use kube::api::{DeleteParams, Patch, PatchParams, PostParams};
use kube::{Api, Client};
use serde_json::json;
use std::collections::BTreeMap;
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

mod leader_election;
use leader_election::LeaseLeaderElector;

const LEADER_LEASE_NAME: &str = "video-completion-leader";

#[derive(Debug, Clone)]
struct CompletionConfig {
    namespace: String,
    output_storage_account: String,
    output_storage_container: String,
    output_mount_path: String,
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
    let jobs: Api<Job> = Api::namespaced(client.clone(), &cfg.namespace);
    let leases: Api<Lease> = Api::namespaced(client, &cfg.namespace);
    let result_queue = queue_client(&cfg.output_storage_account, &cfg.result_queue)?;

    let identity = std::env::var("POD_NAME")
        .unwrap_or_else(|_| std::env::var("HOSTNAME").unwrap_or_else(|_| "completion".to_owned()));
    let lease_duration_seconds = std::cmp::max(30, (cfg.poll_seconds as i32).saturating_mul(3));
    let mut elector =
        LeaseLeaderElector::new(leases, LEADER_LEASE_NAME, identity, lease_duration_seconds);

    tracing::info!(queue = %cfg.result_queue, "Completion worker started");
    let mut interval = tokio::time::interval(std::time::Duration::from_secs(cfg.poll_seconds));

    loop {
        tokio::select! {
            _ = interval.tick() => {}
            _ = tokio::signal::ctrl_c() => {
                tracing::info!("Shutdown signal received; releasing completion leader lease");
                if let Err(error) = elector.try_release().await {
                    tracing::warn!(%error, "Failed to release completion leader lease during shutdown");
                }
                return Ok(());
            }
        }

        let is_leader = match elector.try_acquire_or_renew().await {
            Ok(leading) => leading,
            Err(error) => {
                tracing::error!(%error, "Leader election iteration failed");
                false
            }
        };
        if !is_leader {
            tracing::debug!("Not the completion leader this cycle; skipping reconciliation");
            continue;
        }
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
    let use_spot = annotations
        .get("video.fastvideo/use-spot")
        .map(|value| value == "true")
        .unwrap_or_else(|| {
            encode_node_selector
                .and_then(|selector| selector.get("kubernetes.azure.com/scalesetpriority"))
                .is_some_and(|priority| priority == "spot")
        });
    let media_runtime = video::job_templates::normalize_media_runtime(
        annotations
            .get(MEDIA_RUNTIME_ANNOTATION)
            .map(String::as_str)
            .unwrap_or(&cfg.default_media_runtime),
    )?;

    let stitch_active_deadline_seconds: i64 =
        config::setting("Encoding__StitchJobActiveDeadlineSeconds", "21600")
            .parse()
            .context("Encoding__StitchJobActiveDeadlineSeconds is invalid")?;
    let mut job = load_job_template("stitch", media_runtime, use_spot)?;
    job.metadata.name = Some(stitch_name.clone());

    let labels = labels_mut(&mut job.metadata);
    labels.insert(
        "app.kubernetes.io/name".to_owned(),
        "video-stitcher".to_owned(),
    );
    labels.insert(
        "video/job-id".to_owned(),
        video::contracts::label_value(&job_id),
    );

    let annotations_mutable = annotations_mut(&mut job.metadata);
    annotations_mutable.insert(JOB_ID_ANNOTATION.to_owned(), job_id.clone());

    let spec = job_spec_mut(&mut job)?;
    spec.active_deadline_seconds = Some(stitch_active_deadline_seconds);

    let pod_labels = labels_mut(pod_metadata_mut(spec));
    pod_labels.insert(
        "app.kubernetes.io/name".to_owned(),
        "video-stitcher".to_owned(),
    );
    pod_labels.insert(
        "video/job-id".to_owned(),
        video::contracts::label_value(&job_id),
    );

    let pod_spec = pod_spec_mut(spec)?;
    if let Some(arch) = encode_node_selector.and_then(|selector| selector.get("kubernetes.io/arch"))
    {
        pod_spec
            .node_selector
            .get_or_insert_with(Default::default)
            .insert("kubernetes.io/arch".to_owned(), arch.clone());
    }

    let container = container_mut(pod_spec, "stitcher")?;
    set_env_var(container, "JOB_ID", &job_id)?;
    set_env_var(container, "SEGMENT_COUNT", &segment_count)?;
    set_env_var(container, "AUDIO_BLOB_NAME", &audio_blob_name)?;
    set_env_var(container, "OUTPUT_PATH", &output_path)?;
    set_env_var(container, "OUTPUT_TYPE", &output_type)?;
    set_env_var(container, "CALCULATE_VMAF", &calculate_vmaf)?;
    set_env_var(
        container,
        "OUTPUT_STORAGE_ACCOUNT_NAME",
        &cfg.output_storage_account,
    )?;
    set_env_var(
        container,
        "OUTPUT_STORAGE_CONTAINER",
        &cfg.output_storage_container,
    )?;
    set_env_var(container, "OUTPUT_MOUNT_PATH", &cfg.output_mount_path)?;

    match jobs.create(&PostParams::default(), &job).await {
        Ok(_) => Ok(()),
        Err(kube::Error::Api(error)) if error.code == 409 => Ok(()),
        Err(error) => Err(error).context("Failed to create stitch job"),
    }
}

fn load_job_template(role: &str, media_runtime: &str, use_spot: bool) -> Result<Job> {
    let path = video::job_templates::template_path(role, media_runtime, use_spot)?;
    let yaml = std::fs::read_to_string(&path)
        .with_context(|| format!("Failed to read job template '{}'", path.display()))?;
    serde_yaml::from_str(&yaml)
        .with_context(|| format!("Failed to parse job template '{}'", path.display()))
}

fn job_spec_mut(job: &mut Job) -> Result<&mut JobSpec> {
    job.spec.as_mut().ok_or_else(|| {
        anyhow!(
            "Job template '{}' is missing spec",
            metadata_name(&job.metadata)
        )
    })
}

fn pod_metadata_mut(spec: &mut JobSpec) -> &mut ObjectMeta {
    spec.template.metadata.get_or_insert_with(Default::default)
}

fn pod_spec_mut(spec: &mut JobSpec) -> Result<&mut PodSpec> {
    spec.template.spec.as_mut().ok_or_else(|| {
        anyhow!(
            "Job template '{}' is missing pod spec",
            metadata_name(
                spec.template
                    .metadata
                    .as_ref()
                    .unwrap_or(&ObjectMeta::default())
            )
        )
    })
}

fn container_mut<'a>(pod_spec: &'a mut PodSpec, name: &str) -> Result<&'a mut Container> {
    pod_spec
        .containers
        .iter_mut()
        .find(|container| container.name == name)
        .ok_or_else(|| anyhow!("Job template is missing container '{name}'"))
}

fn labels_mut(metadata: &mut ObjectMeta) -> &mut BTreeMap<String, String> {
    metadata.labels.get_or_insert_with(Default::default)
}

fn annotations_mut(metadata: &mut ObjectMeta) -> &mut BTreeMap<String, String> {
    metadata.annotations.get_or_insert_with(Default::default)
}

fn metadata_name(metadata: &ObjectMeta) -> String {
    metadata
        .name
        .clone()
        .unwrap_or_else(|| "<unnamed>".to_owned())
}

fn set_env_var(container: &mut Container, name: &str, value: &str) -> Result<()> {
    let env = container
        .env
        .as_mut()
        .ok_or_else(|| anyhow!("Container '{}' is missing env entries", container.name))?;
    let entry = env
        .iter_mut()
        .find(|candidate| candidate.name == name)
        .ok_or_else(|| anyhow!("Container '{}' is missing env var '{name}'", container.name))?;
    entry.value = Some(value.to_owned());
    entry.value_from = None;
    Ok(())
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
