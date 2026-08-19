use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use url::Url;

pub const JOB_ID_ANNOTATION: &str = "video/job-id";
pub const AUDIO_BLOB_NAME_ANNOTATION: &str = "video/audio-blob-name";
pub const AUDIO_ENCODING_REQUIRED_ANNOTATION: &str = "video/audio-encoding-required";
pub const OUTPUT_PATH_ANNOTATION: &str = "video/output-path";
pub const OUTPUT_TYPE_ANNOTATION: &str = "video/output-type";
pub const CALCULATE_VMAF_ANNOTATION: &str = "video/calculate-vmaf";
pub const MEDIA_RUNTIME_ANNOTATION: &str = "video/media-runtime";
pub const RESULT_REPORTED_ANNOTATION: &str = "video/result-reported";

pub fn normalize_output_type(value: &str) -> Result<&'static str, String> {
    match value.to_ascii_lowercase().as_str() {
        "" | "mp4" => Ok("mp4"),
        "cmaf" => Ok("cmaf"),
        "both" => Ok("both"),
        _ => Err("outputType must be mp4, cmaf, or both".to_owned()),
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VideoSubmitted {
    pub job_id: String,
    pub input_video_uri: Url,
    pub output_path: Url,
    #[serde(default = "default_segment_duration")]
    pub segment_duration_seconds: u32,
    #[serde(default = "default_video_codec")]
    pub video_codec: String,
    #[serde(default = "default_audio_codec")]
    pub audio_codec: String,
    pub preset: Option<String>,
    pub crf: Option<u32>,
    pub max_video_bitrate_kbps: Option<u32>,
    #[serde(default = "default_true")]
    pub use_spot: bool,
    #[serde(default)]
    pub calculate_vmaf: bool,
    pub media_runtime: Option<String>,
    pub architecture: Option<String>,
    pub parallelization_strategy: Option<String>,
    #[serde(default = "default_output_type")]
    pub output_type: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VideoManifest {
    #[serde(alias = "JobId")]
    pub job_id: String,
    #[serde(alias = "InputVideoUri")]
    pub input_video_uri: Url,
    #[serde(alias = "OutputPath")]
    pub output_path: Url,
    #[serde(alias = "WorkingContainer")]
    pub working_container: String,
    #[serde(alias = "AudioBlobName")]
    pub audio_blob_name: String,
    #[serde(alias = "Duration")]
    pub duration: String,
    #[serde(alias = "SegmentDurationSeconds")]
    pub segment_duration_seconds: u32,
    #[serde(alias = "SegmentCount")]
    pub segment_count: usize,
    #[serde(alias = "Segments")]
    pub segments: Vec<VideoSegment>,
    #[serde(alias = "VideoCodec")]
    pub video_codec: String,
    #[serde(alias = "AudioCodec")]
    pub audio_codec: String,
    #[serde(alias = "Preset")]
    pub preset: String,
    #[serde(alias = "Crf")]
    pub crf: u32,
    #[serde(alias = "MaxVideoBitrateKbps")]
    pub max_video_bitrate_kbps: u32,
    #[serde(alias = "UseSpot")]
    pub use_spot: bool,
    #[serde(alias = "CalculateVmaf")]
    pub calculate_vmaf: bool,
    #[serde(alias = "OutputType", default = "default_output_type")]
    pub output_type: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VideoSegment {
    #[serde(alias = "Index")]
    pub index: usize,
    #[serde(alias = "StartSeconds")]
    pub start_seconds: f64,
    #[serde(alias = "DurationSeconds")]
    pub duration_seconds: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SegmentVmaf {
    #[serde(alias = "Index")]
    pub index: usize,
    #[serde(alias = "Score")]
    pub score: f64,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct VideoVmaf {
    pub score: f64,
    pub segments: Vec<SegmentVmaf>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VideoProcessingResult {
    pub job_id: String,
    pub succeeded: bool,
    pub terminal_stage: String,
    pub failed_indexes: Option<String>,
    pub failure_reason: Option<String>,
    pub completed_at: String,
}

pub fn job_name(prefix: &str, job_id: &str) -> String {
    format!("{prefix}-{}", label_value(job_id))
}

pub fn label_value(value: &str) -> String {
    let normalized = value
        .to_ascii_lowercase()
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' || c == '.' {
                c
            } else {
                '-'
            }
        })
        .collect::<String>()
        .trim_matches(['-', '.'])
        .to_owned();
    let hash = Sha256::digest(value.as_bytes())
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>();
    let hash = &hash[..10];
    let available = 52 - hash.len();
    let prefix = normalized[..normalized.len().min(available)].trim_end_matches(['-', '.']);
    format!("{prefix}-{hash}")
}

fn default_segment_duration() -> u32 {
    60
}
fn default_video_codec() -> String {
    "libsvtav1".into()
}
fn default_audio_codec() -> String {
    "copy".into()
}
fn default_output_type() -> String {
    "mp4".into()
}
fn default_true() -> bool {
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn deserializes_dotnet_manifest() {
        let manifest: VideoManifest = serde_json::from_str(
            r#"{
                "JobId":"job-1",
                "InputVideoUri":"https://input.blob.core.windows.net/videos/input.mp4",
                "OutputPath":"https://output.blob.core.windows.net/videos/output",
                "WorkingContainer":"videos",
                "AudioBlobName":"job-1/audio.m4a",
                "Duration":"00:01:00",
                "SegmentDurationSeconds":60,
                "SegmentCount":1,
                "Segments":[{"Index":0,"StartSeconds":0.0,"DurationSeconds":60.0}],
                "VideoCodec":"libsvtav1",
                "AudioCodec":"copy",
                "Preset":"8",
                "Crf":32,
                "MaxVideoBitrateKbps":4000,
                "UseSpot":true,
                "CalculateVmaf":false
            }"#,
        )
        .unwrap();

        assert_eq!(manifest.job_id, "job-1");
        assert_eq!(manifest.segments[0].duration_seconds, 60.0);
    }

    #[test]
    fn job_labels_are_deterministic_and_valid() {
        let value = label_value("Customer/Video #42");
        assert_eq!(value.len(), 29);
        assert!(value.starts_with("customer-video--42-"));
        assert_eq!(value, label_value("Customer/Video #42"));
    }
}
