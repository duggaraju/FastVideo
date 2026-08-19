use crate::contracts::{SegmentVmaf, VideoSegment};
use anyhow::{bail, Context, Result};
use ffmpeg_sidecar::command::FfmpegCommand;
use serde::Deserialize;
use serde_json::Value;
use std::{
    fs,
    path::{Path, PathBuf},
    process::{Command, Stdio},
};

#[derive(Debug, Clone)]
pub struct MediaInfo {
    pub duration_seconds: f64,
    pub audio_duration_seconds: f64,
    pub width: i32,
    pub height: i32,
    pub frame_rate: f64,
    pub bit_rate: i64,
    pub codec_name: String,
}

#[derive(Debug, Clone)]
pub struct EncodingProfile {
    pub preset: String,
    pub crf: u32,
    pub max_video_bitrate_kbps: u32,
}

#[derive(Deserialize)]
struct ProbeDocument {
    streams: Vec<ProbeStream>,
    format: ProbeFormat,
}

#[derive(Deserialize)]
struct ProbeStream {
    codec_type: String,
    codec_name: Option<String>,
    duration: Option<String>,
    width: Option<i32>,
    height: Option<i32>,
    avg_frame_rate: Option<String>,
    r_frame_rate: Option<String>,
    bit_rate: Option<String>,
}

#[derive(Deserialize)]
struct ProbeFormat {
    duration: String,
}

#[derive(Deserialize)]
struct PacketDocument {
    packets: Vec<ProbePacket>,
}

#[derive(Deserialize)]
struct ProbePacket {
    pts_time: Option<String>,
    flags: Option<String>,
}

pub fn probe(path: &Path) -> Result<MediaInfo> {
    let document: ProbeDocument = run_ffprobe_json(&[
        "-show_entries",
        "format=duration:stream=codec_type,codec_name,duration,width,height,avg_frame_rate,r_frame_rate,bit_rate",
        path.to_string_lossy().as_ref(),
    ])?;
    let duration_seconds = document.format.duration.parse()?;
    if duration_seconds <= 0.0 {
        bail!("FFmpeg returned an invalid duration");
    }
    let audio_duration_seconds = document
        .streams
        .iter()
        .find(|stream| stream.codec_type == "audio")
        .context("Input does not contain an audio stream")?
        .duration
        .as_deref()
        .and_then(|duration| duration.parse().ok())
        .unwrap_or(duration_seconds);
    let stream = document
        .streams
        .into_iter()
        .find(|stream| stream.codec_type == "video")
        .context("Input does not contain a video stream")?;
    let frame_rate = stream
        .avg_frame_rate
        .as_deref()
        .and_then(parse_frame_rate)
        .or_else(|| stream.r_frame_rate.as_deref().and_then(parse_frame_rate))
        .filter(|fps| *fps > 0.0)
        .unwrap_or(30.0);
    Ok(MediaInfo {
        duration_seconds,
        audio_duration_seconds,
        width: stream.width.unwrap_or_default(),
        height: stream.height.unwrap_or_default(),
        frame_rate,
        bit_rate: stream
            .bit_rate
            .as_deref()
            .unwrap_or("0")
            .parse()
            .unwrap_or_default(),
        codec_name: stream.codec_name.unwrap_or_default(),
    })
}

pub fn keyframe_times(path: &Path, duration_seconds: f64) -> Result<Vec<f64>> {
    let document: PacketDocument = run_ffprobe_json(&[
        "-select_streams",
        "v:0",
        "-show_entries",
        "packet=pts_time,flags",
        path.to_string_lossy().as_ref(),
    ])?;
    Ok(document
        .packets
        .into_iter()
        .filter(|packet| {
            packet
                .flags
                .as_deref()
                .is_some_and(|flags| flags.contains('K'))
        })
        .filter_map(|packet| packet.pts_time?.parse::<f64>().ok())
        .filter(|seconds| (0.0..=duration_seconds).contains(seconds))
        .collect())
}

pub fn select_profile(
    source: &MediaInfo,
    target_codec: &str,
    preset: Option<String>,
    crf: Option<u32>,
    max_bitrate: Option<u32>,
) -> EncodingProfile {
    let pixels = i64::from(source.width) * i64::from(source.height);
    let bits_per_pixel = if source.bit_rate > 0 && pixels > 0 {
        source.bit_rate as f64 / (pixels as f64 * source.frame_rate)
    } else {
        0.08
    };
    let av1 = target_codec.to_ascii_lowercase().contains("av1");
    let mut automatic_crf = if av1 {
        if bits_per_pixel <= 0.04 {
            35
        } else if bits_per_pixel <= 0.07 {
            33
        } else if bits_per_pixel <= 0.12 {
            31
        } else {
            29
        }
    } else if bits_per_pixel <= 0.04 {
        28
    } else if bits_per_pixel <= 0.07 {
        26
    } else if bits_per_pixel <= 0.12 {
        24
    } else {
        22
    };
    if av1 && pixels >= 3840 * 2160 {
        automatic_crf += 2;
    } else if av1 && pixels >= 1920 * 1080 {
        automatic_crf += 1;
    }

    let automatic_preset = if !av1 {
        "medium"
    } else if pixels <= 1280 * 720 {
        "6"
    } else if pixels <= 1920 * 1080 {
        "7"
    } else {
        "8"
    };
    let resolution_ceiling =
        ((pixels as f64 * source.frame_rate * 0.08 / 1000.0).round() as u32).max(128);
    let efficiency = if !av1 {
        1.0
    } else {
        match source.codec_name.to_ascii_lowercase().as_str() {
            "h264" | "avc" => 0.70,
            "hevc" | "h265" | "vp9" => 0.90,
            "av1" => 1.00,
            _ => 0.80,
        }
    };
    let source_ceiling = if source.bit_rate > 0 {
        ((source.bit_rate as f64 / 1000.0 * efficiency).round() as u32).max(128)
    } else {
        resolution_ceiling
    };
    EncodingProfile {
        preset: preset
            .filter(|value| !value.trim().is_empty())
            .unwrap_or_else(|| automatic_preset.into()),
        crf: crf.unwrap_or(automatic_crf),
        max_video_bitrate_kbps: max_bitrate.unwrap_or(source_ceiling.min(resolution_ceiling)),
    }
}

pub fn extract_audio(input: &Path, output: &Path, codec: &str) -> Result<()> {
    ensure_parent(output)?;
    run_ffmpeg(
        ffmpeg_command()
            .arg("-i")
            .arg(input)
            .args(["-map", "0:a:0", "-vn", "-c:a", codec])
            .arg(output),
    )
}

pub fn encode_segment(
    input: &Path,
    output: &Path,
    segment: &VideoSegment,
    codec: &str,
    preset: &str,
    crf: u32,
    max_bitrate_kbps: u32,
) -> Result<()> {
    ensure_parent(output)?;
    let mut output_args = vec![
        "-map".to_string(),
        "0:v:0".to_string(),
        "-an".to_string(),
        "-c:v".to_string(),
        codec.to_string(),
        "-preset".to_string(),
        preset.to_string(),
        "-crf".to_string(),
        crf.to_string(),
        "-movflags".to_string(),
        "+faststart".to_string(),
        "-t".to_string(),
        segment.duration_seconds.to_string(),
    ];
    if max_bitrate_kbps > 0 {
        output_args.extend([
            "-maxrate".to_string(),
            format!("{max_bitrate_kbps}k"),
            "-bufsize".to_string(),
            format!("{}k", max_bitrate_kbps * 2),
        ]);
    }
    run_ffmpeg(
        ffmpeg_command()
            .args(["-ss", &segment.start_seconds.to_string()])
            .arg("-i")
            .arg(input)
            .args(output_args)
            .arg(output),
    )
}

pub fn encode_segment_with_vmaf(
    source: &Path,
    output: &Path,
    log_path: &Path,
    segment: &VideoSegment,
    codec: &str,
    profile: &EncodingProfile,
) -> Result<f64> {
    ensure_parent(output)?;
    let filter = format!(
        "[dec:0]setpts=PTS-STARTPTS[distorted];[0:v]setpts=PTS-STARTPTS[reference];\
         [distorted][reference]libvmaf=model=path=/opt/ffmpeg/share/vmaf/vmaf_v0.6.1.json:\
         log_fmt=json:log_path={}[vmaf]",
        escape_filter_path(log_path)
    );
    let mut command = Command::new("ffmpeg");
    command
        .args(["-hide_banner", "-nostdin", "-v", "error", "-y"])
        .args(["-ss", &segment.start_seconds.to_string()])
        .args(["-t", &segment.duration_seconds.to_string()])
        .arg("-i")
        .arg(source)
        .args([
            "-map",
            "0:v:0",
            "-an",
            "-c:v",
            codec,
            "-preset",
            &profile.preset,
        ])
        .args(["-crf", &profile.crf.to_string()]);
    if profile.max_video_bitrate_kbps > 0 {
        command.args([
            "-maxrate",
            &format!("{}k", profile.max_video_bitrate_kbps),
            "-bufsize",
            &format!("{}k", profile.max_video_bitrate_kbps * 2),
        ]);
    }
    let status = command
        .args(["-fps_mode", "passthrough", "-movflags", "+faststart"])
        .args(["-avoid_negative_ts", "make_zero"])
        .arg(output)
        .args(["-dec", "0:0", "-filter_complex", &filter])
        .args(["-map", "[vmaf]", "-f", "null", "-"])
        .status()
        .context("Failed to start FFmpeg encoding with VMAF")?;
    if !status.success() {
        bail!("FFmpeg encoding with VMAF exited with {status}");
    }
    let document: Value = serde_json::from_slice(&fs::read(log_path)?)?;
    document["pooled_metrics"]["vmaf"]["mean"]
        .as_f64()
        .context("VMAF output does not contain pooled_metrics.vmaf.mean")
}

pub fn stitch(
    concat_list: &Path,
    audio: &Path,
    output_base: &Path,
    package_directory: &Path,
    output_type: &str,
) -> Result<()> {
    ensure_parent(output_base)?;
    let mut command = ffmpeg_command();
    command
        .args(["-f", "concat", "-safe", "0", "-i"])
        .arg(concat_list)
        .arg("-i")
        .arg(audio);
    if matches!(output_type, "mp4" | "both") {
        command
            .args([
                "-map",
                "0:v:0",
                "-map",
                "1:a:0",
                "-c",
                "copy",
                "-movflags",
                "+faststart",
            ])
            .arg(append_suffix(output_base, ".mp4"));
    }
    if matches!(output_type, "cmaf" | "both") {
        fs::create_dir_all(package_directory)?;
        let base_name = output_base
            .file_name()
            .and_then(|value| value.to_str())
            .context("Output path must end in a UTF-8 base filename")?;
        command
            .args([
                "-map",
                "0:v:0",
                "-map",
                "1:a:0",
                "-c",
                "copy",
                "-f",
                "dash",
                "-seg_duration",
                "6",
                "-use_template",
                "1",
                "-use_timeline",
                "1",
                "-dash_segment_type",
                "mp4",
                "-single_file",
                "1",
                "-single_file_name",
                &format!("{base_name}-stream$RepresentationID$.cmaf"),
                "-adaptation_sets",
                "id=0,streams=v id=1,streams=a",
                "-hls_playlist",
                "1",
                "-hls_master_name",
                &format!("{base_name}.m3u8"),
            ])
            .arg(package_directory.join(format!("{base_name}.mpd")));
    }
    run_ffmpeg(&mut command)?;

    if matches!(output_type, "cmaf" | "both") {
        let base_name = output_base
            .file_name()
            .and_then(|value| value.to_str())
            .context("Output path must end in a UTF-8 base filename")?;
        rename_hls_media_playlists(package_directory, base_name)?;
        let output_directory = output_base.parent().context("Output path has no parent")?;
        for entry in fs::read_dir(package_directory)? {
            let source = entry?.path();
            let destination = output_directory.join(
                source
                    .file_name()
                    .context("Package artifact has no filename")?,
            );
            if destination.exists() {
                fs::remove_file(&destination)?;
            }
            fs::copy(source, destination)?;
        }
    }
    Ok(())
}

fn rename_hls_media_playlists(package_directory: &Path, base_name: &str) -> Result<()> {
    let master_path = package_directory.join(format!("{base_name}.m3u8"));
    let mut master_content = fs::read_to_string(&master_path)?;
    for entry in fs::read_dir(package_directory)? {
        let source = entry?.path();
        let Some(original_name) = source.file_name().and_then(|value| value.to_str()) else {
            continue;
        };
        let Some(representation_id) = original_name
            .strip_prefix("media_")
            .and_then(|value| value.strip_suffix(".m3u8"))
        else {
            continue;
        };
        let renamed_name = format!("{base_name}-stream{representation_id}.m3u8");
        fs::rename(&source, package_directory.join(&renamed_name))?;
        master_content = master_content.replace(original_name, &renamed_name);
    }
    fs::write(master_path, master_content)?;
    Ok(())
}

fn append_suffix(path: &Path, suffix: &str) -> PathBuf {
    let mut value = path.as_os_str().to_owned();
    value.push(suffix);
    PathBuf::from(value)
}

pub fn read_segment_vmaf(path: &Path) -> Result<SegmentVmaf> {
    Ok(serde_json::from_slice(&fs::read(path)?)?)
}

fn ensure_parent(path: &Path) -> Result<()> {
    fs::create_dir_all(path.parent().context("Output path has no parent")?)?;
    Ok(())
}

fn ffmpeg_command() -> FfmpegCommand {
    let mut command = FfmpegCommand::new();
    command.args(["-hide_banner", "-nostdin", "-v", "error", "-y"]);
    command
}

fn run_ffmpeg(command: &mut FfmpegCommand) -> Result<()> {
    let status = command
        .as_inner_mut()
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::inherit())
        .status()
        .context("Failed to start ffmpeg")?;
    if !status.success() {
        bail!("FFmpeg exited with {status}");
    }
    Ok(())
}

fn run_ffprobe_json<T: for<'de> Deserialize<'de>>(args: &[&str]) -> Result<T> {
    let output = Command::new("ffprobe")
        .args(["-v", "error", "-of", "json"])
        .args(args)
        .output()
        .context("Failed to start ffprobe")?;
    if !output.status.success() {
        bail!(
            "ffprobe failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }
    serde_json::from_slice(&output.stdout).context("Failed to parse ffprobe output")
}

fn parse_frame_rate(value: &str) -> Option<f64> {
    let (numerator, denominator) = value.split_once('/')?;
    let denominator = denominator.parse::<f64>().ok()?;
    if denominator == 0.0 {
        return None;
    }
    Some(numerator.parse::<f64>().ok()? / denominator)
}

fn escape_filter_path(path: &Path) -> String {
    path.to_string_lossy()
        .replace('\\', "\\\\")
        .replace(':', "\\:")
        .replace('\'', "\\'")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn automatic_av1_profile_matches_dotnet_thresholds() {
        let source = MediaInfo {
            duration_seconds: 1.0,
            audio_duration_seconds: 1.0,
            width: 1920,
            height: 1080,
            frame_rate: 30.0,
            bit_rate: 4_000_000,
            codec_name: "h264".into(),
        };
        let profile = select_profile(&source, "libsvtav1", None, None, None);
        assert_eq!(profile.preset, "7");
        assert_eq!(profile.crf, 34);
        assert_eq!(profile.max_video_bitrate_kbps, 2800);
    }
}
