use anyhow::{Result, bail};
use std::path::PathBuf;

pub const TEMPLATE_DIRECTORY: &str = "/etc/video/job-templates";

pub fn normalize_media_runtime(value: &str) -> Result<&'static str> {
    match value.trim().to_ascii_lowercase().as_str() {
        "dotnet" => Ok("dotnet"),
        "rust" => Ok("rust"),
        _ => bail!("MediaRuntime must be dotnet or rust"),
    }
}

pub fn template_path(role: &str, media_runtime: &str, use_spot: bool) -> Result<PathBuf> {
    if role.trim().is_empty() {
        bail!("Job template role is required");
    }

    Ok(PathBuf::from(TEMPLATE_DIRECTORY).join(format!(
        "{role}-{}-{}.yaml",
        normalize_media_runtime(media_runtime)?,
        if use_spot { "spot" } else { "regular" }
    )))
}
