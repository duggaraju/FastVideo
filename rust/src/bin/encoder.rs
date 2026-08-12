use anyhow::{bail, Context, Result};
use std::{fs, path::PathBuf};
use uuid::Uuid;
use video::{
    config,
    contracts::{SegmentVmaf, VideoManifest},
    media, paths,
};

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
    let output_path =
        paths::from_blob_name(&format!("{job_id}/segments/{index:06}.mp4"), &output_mount)?;
    let vmaf_path = paths::from_blob_name(
        &format!("{job_id}/segments/{index:06}.vmaf.json"),
        &output_mount,
    )?;
    let calculate_vmaf: bool = config::parse("CALCULATE_VMAF")?;

    if calculate_vmaf && output_path.exists() != vmaf_path.exists() {
        remove_if_exists(&output_path)?;
        remove_if_exists(&vmaf_path)?;
    }
    if output_path.exists() && (!calculate_vmaf || vmaf_path.exists()) {
        return Ok(());
    }

    let staging_dir = paths::from_blob_name(&format!("{job_id}/segments/.staging"), &output_mount)?;
    fs::create_dir_all(&staging_dir)?;
    let staging_id = format!("{index:06}-{}", Uuid::new_v4().simple());
    let staging_path = staging_dir.join(format!("{staging_id}.mp4"));
    let staging_vmaf_path = staging_dir.join(format!("{staging_id}.vmaf.json"));
    let raw_vmaf_path = staging_dir.join(format!("{staging_id}.libvmaf.json"));
    let result = (|| -> Result<()> {
        let codec = config::required("VIDEO_CODEC")?;
        let profile = media::EncodingProfile {
            preset: config::required("PRESET")?,
            crf: config::parse("CRF")?,
            max_video_bitrate_kbps: config::parse("MAX_VIDEO_BITRATE_KBPS")?,
        };
        if calculate_vmaf {
            let score = media::encode_segment_with_vmaf(
                &input_path,
                &staging_path,
                &raw_vmaf_path,
                segment,
                &codec,
                &profile,
            )?;
            fs::write(
                &staging_vmaf_path,
                serde_json::to_vec(&SegmentVmaf { index, score })?,
            )?;
            publish(&staging_vmaf_path, &vmaf_path)?;
        } else {
            media::encode_segment(
                &input_path,
                &staging_path,
                segment,
                &codec,
                &profile.preset,
                profile.crf,
                profile.max_video_bitrate_kbps,
            )?;
        }
        publish(&staging_path, &output_path)
    })();
    let _ = remove_if_exists(&staging_path);
    let _ = remove_if_exists(&staging_vmaf_path);
    let _ = remove_if_exists(&raw_vmaf_path);
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
