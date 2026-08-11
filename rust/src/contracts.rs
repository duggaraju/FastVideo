use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use url::Url;

pub const ARCHITECTURE_ANNOTATION: &str = "spotvideo/architecture";
pub const JOB_ID_ANNOTATION: &str = "spotvideo/job-id";
pub const STAGE_ID_ANNOTATION: &str = "spotvideo/stage-id";
pub const USE_SPOT_ANNOTATION: &str = "spotvideo/use-spot";
pub const SEGMENT_COUNT_ANNOTATION: &str = "spotvideo/segment-count";
pub const AUDIO_BLOB_NAME_ANNOTATION: &str = "spotvideo/audio-blob-name";
pub const OUTPUT_VIDEO_URI_ANNOTATION: &str = "spotvideo/output-video-uri";
pub const CALCULATE_VMAF_ANNOTATION: &str = "spotvideo/calculate-vmaf";
pub const RESULT_REPORTED_ANNOTATION: &str = "spotvideo/result-reported";

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VideoSubmitted {
    pub job_id: String,
    pub input_video_uri: Url,
    pub output_video_uri: Url,
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
    pub parallelization_strategy: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VideoManifest {
    #[serde(alias = "JobId")]
    pub job_id: String,
    #[serde(alias = "InputVideoUri")]
    pub input_video_uri: Url,
    #[serde(alias = "OutputVideoUri")]
    pub output_video_uri: Url,
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
                "OutputVideoUri":"https://output.blob.core.windows.net/videos/output.mp4",
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
