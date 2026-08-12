use anyhow::{bail, Result};
use std::{
    collections::HashSet,
    fs,
    path::{Path, PathBuf},
};
use video::{config, contracts::VideoVmaf, media, paths};

#[tokio::main]
async fn main() -> Result<()> {
    video::init_tracing();
    let job_id = config::required("JOB_ID")?;
    let segment_count: usize = config::parse("SEGMENT_COUNT")?;
    let output_mount = PathBuf::from(config::required("OUTPUT_MOUNT_PATH")?);
    let output_uri = url::Url::parse(&config::required("OUTPUT_VIDEO_URI")?)?;
    let calculate_vmaf: bool = config::parse("CALCULATE_VMAF")?;
    let job_directory = paths::from_blob_name(&job_id, &output_mount)?;
    let working_directory = job_directory.join("_stitch");
    fs::create_dir_all(&working_directory)?;
    let mut complete = false;

    let result = async {
        let segments = (0..segment_count)
            .map(|index| {
                paths::from_blob_name(&format!("{job_id}/segments/{index:06}.mp4"), &output_mount)
            })
            .collect::<Result<Vec<_>>>()?;
        let missing = segments.iter().filter(|path| !path.exists()).count();
        if missing > 0 {
            bail!("Expected {segment_count} segments but {missing} files are missing");
        }

        let vmaf_paths = if calculate_vmaf {
            (0..segment_count)
                .map(|index| {
                    paths::from_blob_name(
                        &format!("{job_id}/segments/{index:06}.vmaf.json"),
                        &output_mount,
                    )
                })
                .collect::<Result<Vec<_>>>()?
        } else {
            vec![]
        };
        let missing_vmaf = vmaf_paths.iter().filter(|path| !path.exists()).count();
        if missing_vmaf > 0 {
            bail!("Expected {segment_count} VMAF results but {missing_vmaf} files are missing");
        }
        let mut vmaf_segments = vmaf_paths
            .iter()
            .map(|path| media::read_segment_vmaf(path))
            .collect::<Result<Vec<_>>>()?;
        vmaf_segments.sort_by_key(|segment| segment.index);
        let vmaf_score = calculate_vmaf.then(|| {
            vmaf_segments
                .iter()
                .map(|segment| segment.score)
                .sum::<f64>()
                / vmaf_segments.len() as f64
        });

        let concat_list = working_directory.join("segments.txt");
        let concat_content = segments
            .iter()
            .map(|path| format!("file '{}'", path.to_string_lossy().replace('\'', "'\\''")))
            .collect::<Vec<_>>()
            .join("\n");
        fs::write(&concat_list, concat_content)?;
        let audio = paths::from_blob_name(&config::required("AUDIO_BLOB_NAME")?, &output_mount)?;
        let output_path = paths::from_uri(
            &output_uri,
            &config::required("OUTPUT_STORAGE_ACCOUNT_NAME")?,
            &config::required("OUTPUT_STORAGE_CONTAINER")?,
            &output_mount,
        )?;
        media::stitch(&concat_list, &audio, &output_path)?;
        let length = fs::metadata(&output_path)?.len();
        if let Some(score) = vmaf_score {
            fs::write(
                output_path.with_extension("vmaf.json"),
                serde_json::to_vec(&VideoVmaf {
                    score,
                    segments: vmaf_segments,
                })?,
            )?;
        }
        tracing::info!(%job_id, %length, ?vmaf_score, "Stitching completed");
        complete = true;

        let mut cleanup = segments;
        cleanup.extend(vmaf_paths);
        cleanup.extend([audio, job_directory.join("manifest.json"), concat_list]);
        delete_intermediate(cleanup, &job_directory).await;
        Ok::<_, anyhow::Error>(())
    }
    .await;

    if !complete {
        delete_directory(&working_directory).await;
    }
    result
}

async fn delete_intermediate(paths: Vec<PathBuf>, job_directory: &Path) {
    let mut seen = HashSet::new();
    for path in paths {
        if seen.insert(path.clone()) {
            if let Err(error) = fs::remove_file(&path) {
                if error.kind() != std::io::ErrorKind::NotFound {
                    tracing::warn!(path = %path.display(), %error, "Could not delete intermediate file");
                }
            }
        }
    }
    delete_directory(job_directory).await;
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
