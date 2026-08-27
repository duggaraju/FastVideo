use anyhow::Result;
use std::{fs, path::PathBuf};
use uuid::Uuid;
use video::{config, media, paths};

fn main() -> Result<()> {
    video::init_tracing();
    let job_id = config::required("JOB_ID")?;
    let source_uri = url::Url::parse(&config::required("SOURCE_VIDEO_URI")?)?;
    let input_path = paths::from_uri(
        &source_uri,
        &config::required("INPUT_STORAGE_ACCOUNT_NAME")?,
        &config::required("INPUT_STORAGE_CONTAINER")?,
        &PathBuf::from(config::required("INPUT_MOUNT_PATH")?),
    )?;
    let output_mount = PathBuf::from(config::required("OUTPUT_MOUNT_PATH")?);
    let output_path = paths::from_blob_name(&config::required("AUDIO_BLOB_NAME")?, &output_mount)?;
    if output_path.exists() {
        return Ok(());
    }

    let staging_dir = paths::from_blob_name(&format!("{job_id}/segments/.staging"), &output_mount)?;
    fs::create_dir_all(&staging_dir)?;
    let staging_path = staging_dir.join(format!("audio-{}.m4a", Uuid::new_v4().simple()));
    let result = (|| -> Result<()> {
        media::extract_audio(
            &input_path,
            &staging_path,
            &config::required("AUDIO_CODEC")?,
        )?;
        publish(&staging_path, &output_path)
    })();
    let _ = fs::remove_file(&staging_path);
    result
}

fn publish(staging: &std::path::Path, canonical: &std::path::Path) -> Result<()> {
    match fs::rename(staging, canonical) {
        Ok(()) => Ok(()),
        Err(_) if canonical.exists() => Ok(()),
        Err(error) => Err(error.into()),
    }
}
