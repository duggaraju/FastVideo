use anyhow::{Context, Result, bail};
use std::{fs, path::PathBuf};
use uuid::Uuid;
use video::{
    config,
    contracts::{SegmentVmaf, VideoManifest},
    media, paths,
};

struct PendingProfile {
    output_path: PathBuf,
    vmaf_path: PathBuf,
    staging_path: PathBuf,
    staging_vmaf_path: PathBuf,
    raw_vmaf_path: PathBuf,
    profile: media::EncodingProfile,
}

fn main() -> Result<()> {
    video::init_tracing();
    let job_id = config::required("JOB_ID")?;
    let index: usize = config::parse("JOB_COMPLETION_INDEX")?;
    let source_uri = url::Url::parse(&config::required("SOURCE_VIDEO_URI")?)?;
    let input_path = paths::from_uri(
        &source_uri,
        &config::required("INPUT_STORAGE_ACCOUNT_NAME")?,
        &config::required("INPUT_STORAGE_CONTAINER")?,
        &PathBuf::from(config::required("INPUT_MOUNT_PATH")?),
    )?;
    let output_mount = PathBuf::from(config::required("OUTPUT_MOUNT_PATH")?);
    let manifest_path = paths::from_blob_name(&format!("{job_id}/manifest.json"), &output_mount)?;
    let manifest: VideoManifest = serde_json::from_slice(&fs::read(manifest_path)?)?;
    if index >= manifest.segment_count {
        bail!(
            "Completion index {index} is outside segment count {}",
            manifest.segment_count
        );
    }
    let segment = manifest
        .segments
        .iter()
        .find(|segment| segment.index == index)
        .with_context(|| format!("Segment definition for index {index} was not found"))?;
    let calculate_vmaf: bool = config::parse("CALCULATE_VMAF")?;

    let staging_dir = paths::from_blob_name(&format!("{job_id}/segments/.staging"), &output_mount)?;
    fs::create_dir_all(&staging_dir)?;
    let codec = config::required("VIDEO_CODEC")?;
    let mut pending = Vec::new();
    for manifest_profile in &manifest.encoding_profiles {
        let output_path = paths::from_blob_name(
            &format!("{job_id}/segments/{index:06}-{}.mp4", manifest_profile.name),
            &output_mount,
        )?;
        let vmaf_path = paths::from_blob_name(
            &format!(
                "{job_id}/segments/{index:06}-{}.vmaf.json",
                manifest_profile.name
            ),
            &output_mount,
        )?;
        if calculate_vmaf && output_path.exists() != vmaf_path.exists() {
            remove_if_exists(&output_path)?;
            remove_if_exists(&vmaf_path)?;
        }
        if output_path.exists() && (!calculate_vmaf || vmaf_path.exists()) {
            continue;
        }

        let staging_id = format!(
            "{index:06}-{}-{}",
            manifest_profile.name,
            Uuid::new_v4().simple()
        );
        let staging_path = staging_dir.join(format!("{staging_id}.mp4"));
        let staging_vmaf_path = staging_dir.join(format!("{staging_id}.vmaf.json"));
        let raw_vmaf_path = staging_dir.join(format!("{staging_id}.libvmaf.json"));
        pending.push(PendingProfile {
            output_path,
            vmaf_path,
            staging_path,
            staging_vmaf_path,
            raw_vmaf_path,
            profile: media::EncodingProfile {
                name: manifest_profile.name.clone(),
                width: manifest_profile.width,
                height: manifest_profile.height,
                preset: manifest_profile.encoder_preset.clone(),
                crf: manifest_profile.crf,
                max_video_bitrate_kbps: manifest_profile.max_video_bitrate_kbps,
            },
        });
    }

    let result = (|| -> Result<()> {
        if calculate_vmaf {
            let vmaf_outputs = pending
                .iter()
                .map(|item| {
                    (
                        item.staging_path.as_path(),
                        &item.profile,
                        item.raw_vmaf_path.as_path(),
                    )
                })
                .collect::<Vec<_>>();
            let scores = media::encode_segment_profiles_with_vmaf(
                &input_path,
                &vmaf_outputs,
                segment,
                &codec,
            )?;
            for (item, score) in pending.iter().zip(scores) {
                fs::write(
                    &item.staging_vmaf_path,
                    serde_json::to_vec(&SegmentVmaf { index, score })?,
                )?;
            }
        } else {
            let encode_outputs = pending
                .iter()
                .map(|item| (item.staging_path.as_path(), &item.profile))
                .collect::<Vec<_>>();
            media::encode_segment_profiles(&input_path, &encode_outputs, segment, &codec)?;
        }

        for item in &pending {
            publish(&item.staging_path, &item.output_path)?;
            if calculate_vmaf {
                publish(&item.staging_vmaf_path, &item.vmaf_path)?;
            }
        }
        Ok(())
    })();
    for item in &pending {
        let _ = remove_if_exists(&item.staging_path);
        let _ = remove_if_exists(&item.staging_vmaf_path);
        let _ = remove_if_exists(&item.raw_vmaf_path);
    }
    result
}

fn publish(staging: &std::path::Path, canonical: &std::path::Path) -> Result<()> {
    match fs::rename(staging, canonical) {
        Ok(()) => Ok(()),
        Err(_) if canonical.exists() => Ok(()),
        Err(error) => Err(error.into()),
    }
}

fn remove_if_exists(path: &std::path::Path) -> Result<()> {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error.into()),
    }
}
