use anyhow::{Result, bail};
use std::path::PathBuf;

use crate::contracts::CapacityClass;

pub const TEMPLATE_DIRECTORY: &str = "/etc/video/job-templates";

pub fn normalize_media_runtime(value: &str) -> Result<&'static str> {
    match value.trim().to_ascii_lowercase().as_str() {
        "dotnet" => Ok("dotnet"),
        "rust" => Ok("rust"),
        _ => bail!("MediaRuntime must be dotnet or rust"),
    }
}

pub fn template_path(
    role: &str,
    media_runtime: &str,
    capacity_class: Option<CapacityClass>,
) -> Result<PathBuf> {
    if role.trim().is_empty() {
        bail!("Job template role is required");
    }

    let capacity_class_suffix = capacity_class
        .map(|value| format!("-{}", value.as_str()))
        .unwrap_or_default();
    Ok(PathBuf::from(TEMPLATE_DIRECTORY).join(format!(
        "{role}-{}{capacity_class_suffix}.yaml",
        normalize_media_runtime(media_runtime)?
    )))
}
