use anyhow::{Result, bail};
use std::{
    collections::HashSet,
    fs,
    path::{Path, PathBuf},
};
use video::{
    config,
    contracts::{VideoManifest, VideoVmaf, normalize_output_type},
    media, paths,
};

#[tokio::main]
async fn main() -> Result<()> {
    video::init_tracing();
    let job_id = config::required("JOB_ID")?;
    let segment_count: usize = config::parse("SEGMENT_COUNT")?;
    let output_mount = PathBuf::from(config::required("OUTPUT_MOUNT_PATH")?);
    let output_uri = url::Url::parse(&config::required("OUTPUT_PATH")?)?;
    let output_type =
        normalize_output_type(&config::required("OUTPUT_TYPE")?).map_err(anyhow::Error::msg)?;
    let calculate_vmaf: bool = config::parse("CALCULATE_VMAF")?;
    let job_directory = paths::from_blob_name(&job_id, &output_mount)?;
    let manifest: VideoManifest =
        serde_json::from_slice(&fs::read(job_directory.join("manifest.json"))?)?;
    if manifest.segment_count != segment_count {
        bail!(
            "Manifest segment count {} does not match Job count {segment_count}",
            manifest.segment_count
        );
    }
    let working_directory = job_directory.join("_stitch");
    let package_root = std::env::temp_dir().join("video-stitcher").join(&job_id);
    fs::create_dir_all(&working_directory)?;
    let mut complete = false;

    let result = async {
        let audio = paths::from_blob_name(&config::required("AUDIO_BLOB_NAME")?, &output_mount)?;
        let output_base_path = paths::from_uri(
            &output_uri,
            &config::required("OUTPUT_STORAGE_ACCOUNT_NAME")?,
            &config::required("OUTPUT_STORAGE_CONTAINER")?,
            &output_mount,
        )?;
        let output_is_in_job_directory = output_base_path.starts_with(&job_directory);
        let mut cleanup = vec![];

        for profile in &manifest.encoding_profiles {
            let segments = (0..segment_count)
                .map(|index| {
                    paths::from_blob_name(
                        &format!("{job_id}/segments/{index:06}-{}.mp4", profile.name),
                        &output_mount,
                    )
                })
                .collect::<Result<Vec<_>>>()?;
            let missing = segments.iter().filter(|path| !path.exists()).count();
            if missing > 0 {
                bail!(
                    "Expected {segment_count} {} segments but {missing} files are missing",
                    profile.name
                );
            }
            let vmaf_paths = if calculate_vmaf {
                (0..segment_count)
                    .map(|index| {
                        paths::from_blob_name(
                            &format!(
                                "{job_id}/segments/{index:06}-{}.vmaf.json",
                                profile.name
                            ),
                            &output_mount,
                        )
                    })
                    .collect::<Result<Vec<_>>>()?
            } else {
                vec![]
            };
            let missing_vmaf = vmaf_paths.iter().filter(|path| !path.exists()).count();
            if missing_vmaf > 0 {
                bail!(
                    "Expected {segment_count} {} VMAF results but {missing_vmaf} files are missing",
                    profile.name
                );
            }
            let mut vmaf_segments = vmaf_paths
                .iter()
                .map(|path| media::read_segment_vmaf(path))
                .collect::<Result<Vec<_>>>()?;
            vmaf_segments.sort_by_key(|segment| segment.index);

            let concat_list = working_directory.join(format!("segments-{}.txt", profile.name));
            let concat_content = segments
                .iter()
                .map(|path| format!("file '{}'", path.to_string_lossy().replace('\'', "'\\''")))
                .collect::<Vec<_>>()
                .join("\n");
            fs::write(&concat_list, concat_content)?;
            let profile_output_base = if manifest.preset.is_some() {
                append_suffix(&output_base_path, &format!("-{}", profile.name))
            } else {
                output_base_path.clone()
            };
            let package_directory = package_root.join(&profile.name);
            media::stitch(
                &concat_list,
                &audio,
                &profile_output_base,
                &package_directory,
                output_type,
            )?;
            if calculate_vmaf {
                let score = vmaf_segments.iter().map(|segment| segment.score).sum::<f64>()
                    / vmaf_segments.len() as f64;
                fs::write(
                    append_suffix(&profile_output_base, ".vmaf.json"),
                    serde_json::to_vec(&VideoVmaf {
                        score,
                        segments: vmaf_segments,
                    })?,
                )?;
            }
            cleanup.extend(segments);
            cleanup.extend(vmaf_paths);
            cleanup.push(concat_list);
        }
        tracing::info!(%job_id, %output_type, profile_count = manifest.encoding_profiles.len(), "Stitching completed");
        complete = true;

        cleanup.extend([audio, job_directory.join("manifest.json")]);
        delete_intermediate(cleanup).await;
        if output_is_in_job_directory {
            delete_directory(&job_directory.join("segments")).await;
            delete_directory(&working_directory).await;
        } else {
            delete_directory(&job_directory).await;
        }
        Ok::<_, anyhow::Error>(())
    }
    .await;

    delete_directory(&package_root).await;
    if !complete {
        delete_directory(&working_directory).await;
    }
    result
}

fn append_suffix(path: &Path, suffix: &str) -> PathBuf {
    let mut value = path.as_os_str().to_owned();
    value.push(suffix);
    PathBuf::from(value)
}

async fn delete_intermediate(paths: Vec<PathBuf>) {
    let mut seen = HashSet::new();
    for path in paths {
        if seen.insert(path.clone())
            && let Err(error) = fs::remove_file(&path)
            && error.kind() != std::io::ErrorKind::NotFound
        {
            tracing::warn!(path = %path.display(), %error, "Could not delete intermediate file");
        }
    }
}

async fn delete_directory(path: &Path) {
    for attempt in 0..3 {
        match fs::remove_dir_all(path) {
            Ok(()) => return,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return,
            Err(_) if attempt < 2 => tokio::time::sleep(std::time::Duration::from_secs(1)).await,
            Err(_) => return,
        }
    }
}
