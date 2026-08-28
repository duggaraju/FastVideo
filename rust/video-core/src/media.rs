use crate::contracts::{SegmentVmaf, VideoSegment};
use anyhow::{Context, Result, bail};
use ffmpeg_sidecar::command::FfmpegCommand;
use serde::Deserialize;
use std::{
    collections::HashMap,
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
    pub name: String,
    pub width: i32,
    pub height: i32,
    pub preset: String,
    pub crf: u32,
    pub max_video_bitrate_kbps: u32,
}

const DEFAULT_LADDER_PROFILES_JSON: &str = include_str!("../../../deploy/ladder-profiles.json");

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct LadderRung {
    name: String,
    width: i32,
    height: i32,
    max_video_bitrate_kbps: u32,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct LadderRungDefinition {
    width: i32,
    height: i32,
    max_video_bitrate_kbps: u32,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RenditionDefinition {
    rung: Option<String>,
    name: Option<String>,
    width: Option<i32>,
    height: Option<i32>,
    max_video_bitrate_kbps: Option<u32>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(
    tag = "type",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
enum LadderPreset {
    Bounded {
        #[serde(default)]
        rungs: Option<Vec<String>>,
        max_width: i32,
        max_height: i32,
        max_video_bitrate_kbps: u32,
    },
    Custom {
        renditions: Vec<RenditionDefinition>,
    },
}

#[derive(Debug, Clone, Deserialize)]
struct LadderCatalog {
    rungs: HashMap<String, LadderRungDefinition>,
    presets: HashMap<String, LadderPreset>,
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

pub fn is_ladder_preset(value: Option<&str>) -> bool {
    maximum_preset_height(value).is_some()
}

pub fn is_configured_ladder_preset(value: Option<&str>, json: Option<&str>) -> bool {
    let Some(value) = value else { return false };
    parse_ladder(json).is_ok_and(|catalog| find_preset(&catalog, value).is_some())
        || is_ladder_preset(Some(value))
}

pub fn select_profiles(
    source: &MediaInfo,
    target_codec: &str,
    ladder_preset: Option<String>,
    mut encoder_preset: Option<String>,
    crf: Option<u32>,
    max_bitrate: Option<u32>,
    ladder_profiles_json: Option<&str>,
) -> Result<Vec<EncodingProfile>> {
    let source_pixels = i64::from(source.width) * i64::from(source.height);
    let bits_per_pixel = if source.bit_rate > 0 && source_pixels > 0 {
        source.bit_rate as f64 / (source_pixels as f64 * source.frame_rate)
    } else {
        0.08
    };
    let av1 = target_codec.to_ascii_lowercase().contains("av1");
    let ladder = parse_ladder(ladder_profiles_json)?;
    let ladder_preset = if ladder_preset.as_deref().is_some_and(|value| {
        find_preset(&ladder, value).is_none() && !is_ladder_preset(Some(value))
    }) {
        if encoder_preset.is_none() {
            encoder_preset = ladder_preset.clone();
        }
        None
    } else {
        ladder_preset
    };

    let mut profiles = select_rungs(source, ladder_preset.as_deref(), &ladder)?
        .into_iter()
        .map(|(name, width, height, rung_bitrate)| {
            select_profile(
                source,
                name,
                width,
                height,
                rung_bitrate,
                encoder_preset.clone(),
                crf,
                max_bitrate,
                bits_per_pixel,
                av1,
            )
        })
        .collect::<Vec<_>>();
    for index in 1..profiles.len() {
        profiles[index].max_video_bitrate_kbps = profiles[index].max_video_bitrate_kbps.min(
            profiles[index - 1]
                .max_video_bitrate_kbps
                .saturating_sub(1)
                .max(1),
        );
    }
    Ok(profiles)
}

#[allow(clippy::too_many_arguments)]
fn select_profile(
    source: &MediaInfo,
    name: String,
    width: i32,
    height: i32,
    rung_bitrate: u32,
    preset: Option<String>,
    crf: Option<u32>,
    max_bitrate: Option<u32>,
    bits_per_pixel: f64,
    av1: bool,
) -> EncodingProfile {
    let pixels = i64::from(width) * i64::from(height);
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
        ((source.bit_rate as f64 / 1000.0 * efficiency).floor() as u32).max(1)
    } else {
        resolution_ceiling
    };
    EncodingProfile {
        name,
        width,
        height,
        preset: preset
            .filter(|value| !value.trim().is_empty())
            .unwrap_or_else(|| automatic_preset.into()),
        crf: crf.unwrap_or(automatic_crf),
        max_video_bitrate_kbps: max_bitrate
            .unwrap_or(u32::MAX)
            .min(rung_bitrate.min(source_ceiling).min(resolution_ceiling)),
    }
}

fn select_rungs(
    source: &MediaInfo,
    preset: Option<&str>,
    catalog: &LadderCatalog,
) -> Result<Vec<(String, i32, i32, u32)>> {
    let Some(preset_name) = preset else {
        return Ok(vec![(
            format!("{}p", source.height),
            source.width,
            source.height,
            u32::MAX,
        )]);
    };

    let fallback;
    let configured = find_preset(catalog, preset_name);
    let preset = if let Some(value) = configured {
        value
    } else if let Some(max_height) = maximum_preset_height(Some(preset_name)) {
        fallback = LadderPreset::Bounded {
            rungs: None,
            max_width: i32::MAX,
            max_height,
            max_video_bitrate_kbps: u32::MAX,
        };
        &fallback
    } else {
        bail!("Unknown ladder preset '{preset_name}'");
    };

    let mut selected = match preset {
        LadderPreset::Bounded {
            rungs,
            max_width,
            max_height,
            max_video_bitrate_kbps,
        } => {
            let eligible = rungs.as_ref().map(|values| {
                values
                    .iter()
                    .map(|value| value.to_ascii_lowercase())
                    .collect::<Vec<_>>()
            });
            catalog
                .rungs
                .iter()
                .filter(|(name, rung)| {
                    eligible
                        .as_ref()
                        .is_none_or(|values| values.contains(&name.to_ascii_lowercase()))
                        && rung.width <= *max_width
                        && rung.height <= *max_height
                })
                .map(|(name, rung)| LadderRung {
                    name: name.clone(),
                    width: rung.width,
                    height: rung.height,
                    max_video_bitrate_kbps: rung
                        .max_video_bitrate_kbps
                        .min(*max_video_bitrate_kbps),
                })
                .collect::<Vec<_>>()
        }
        LadderPreset::Custom { renditions } => renditions
            .iter()
            .map(|rendition| resolve_rendition(catalog, rendition))
            .collect::<Result<Vec<_>>>()?,
    };
    selected.retain(|rung| rung.width <= source.width && rung.height <= source.height);
    selected.sort_by_key(|rung| std::cmp::Reverse(rung.height));
    if selected.is_empty() {
        return Ok(vec![(
            format!("{}p", source.height),
            source.width,
            source.height,
            800,
        )]);
    }
    Ok(selected
        .into_iter()
        .map(|rung| {
            (
                rung.name,
                rung.width,
                rung.height,
                rung.max_video_bitrate_kbps,
            )
        })
        .collect())
}

fn find_preset<'a>(catalog: &'a LadderCatalog, name: &str) -> Option<&'a LadderPreset> {
    catalog
        .presets
        .iter()
        .find(|(key, _)| key.eq_ignore_ascii_case(name))
        .map(|(_, value)| value)
}

fn resolve_rendition(
    catalog: &LadderCatalog,
    rendition: &RenditionDefinition,
) -> Result<LadderRung> {
    if let Some(reference) = &rendition.rung {
        let (name, rung) = catalog
            .rungs
            .iter()
            .find(|(name, _)| name.eq_ignore_ascii_case(reference))
            .with_context(|| format!("Unknown ladder rung reference '{reference}'"))?;
        return Ok(LadderRung {
            name: rendition.name.clone().unwrap_or_else(|| name.clone()),
            width: rendition.width.unwrap_or(rung.width),
            height: rendition.height.unwrap_or(rung.height),
            max_video_bitrate_kbps: rendition
                .max_video_bitrate_kbps
                .unwrap_or(rung.max_video_bitrate_kbps),
        });
    }
    Ok(LadderRung {
        name: rendition
            .name
            .clone()
            .context("Inline rendition requires name")?,
        width: rendition.width.context("Inline rendition requires width")?,
        height: rendition
            .height
            .context("Inline rendition requires height")?,
        max_video_bitrate_kbps: rendition
            .max_video_bitrate_kbps
            .context("Inline rendition requires maxVideoBitrateKbps")?,
    })
}

fn maximum_preset_height(value: Option<&str>) -> Option<i32> {
    let normalized = value?.trim().to_ascii_lowercase();
    if normalized == "max4k" {
        return Some(2160);
    }
    normalized
        .strip_prefix("max")?
        .strip_suffix('p')?
        .parse::<i32>()
        .ok()
        .filter(|height| *height > 0)
}

fn parse_ladder(json: Option<&str>) -> Result<LadderCatalog> {
    let catalog: LadderCatalog = serde_json::from_str(
        json.filter(|value| !value.trim().is_empty())
            .unwrap_or(DEFAULT_LADDER_PROFILES_JSON),
    )
    .context("Encoding__LadderProfiles must be valid JSON")?;
    if catalog.rungs.is_empty()
        || catalog.presets.is_empty()
        || catalog.rungs.iter().any(|(name, rung)| {
            name.trim().is_empty()
                || rung.width < 2
                || rung.height < 2
                || rung.max_video_bitrate_kbps < 1
        })
    {
        bail!(
            "Encoding__LadderProfiles must contain valid names, dimensions, and positive bitrates"
        );
    }
    for preset in catalog.presets.values() {
        match preset {
            LadderPreset::Bounded {
                max_width,
                max_height,
                max_video_bitrate_kbps,
                ..
            } if *max_width < 2 || *max_height < 2 || *max_video_bitrate_kbps < 1 => bail!(
                "Bounded presets require positive maxWidth, maxHeight, and maxVideoBitrateKbps"
            ),
            LadderPreset::Custom { renditions } if renditions.is_empty() => {
                bail!("Custom presets require at least one rendition")
            }
            LadderPreset::Custom { renditions } => renditions
                .iter()
                .try_for_each(|rendition| resolve_rendition(&catalog, rendition).map(|_| ()))?,
            _ => {}
        }
    }
    Ok(catalog)
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

pub fn encode_segment_profiles(
    input: &Path,
    outputs: &[(&Path, &EncodingProfile)],
    segment: &VideoSegment,
    codec: &str,
) -> Result<()> {
    if outputs.is_empty() {
        return Ok(());
    }
    for (output, _) in outputs {
        ensure_parent(output)?;
    }
    let profiles = outputs
        .iter()
        .map(|(_, profile)| *profile)
        .collect::<Vec<_>>();
    let mut command = Command::new("ffmpeg");
    command
        .args(["-hide_banner", "-nostdin", "-v", "error", "-y"])
        .args(["-ss", &segment.start_seconds.to_string()])
        .args(["-t", &segment.duration_seconds.to_string()])
        .arg("-i")
        .arg(input)
        .args(["-filter_complex", &build_profile_filter(&profiles)]);
    add_profile_outputs(&mut command, outputs, codec);
    run_command(&mut command, "multi-profile encoding")
}

pub fn encode_segment_profiles_with_vmaf(
    source: &Path,
    encoded_outputs: &[(&Path, &EncodingProfile, &Path)],
    segment: &VideoSegment,
    codec: &str,
) -> Result<Vec<f64>> {
    if encoded_outputs.is_empty() {
        return Ok(vec![]);
    }
    let mut command = Command::new("ffmpeg");
    command
        .args(["-hide_banner", "-nostdin", "-v", "error", "-y"])
        .args(["-ss", &segment.start_seconds.to_string()])
        .args(["-t", &segment.duration_seconds.to_string()])
        .arg("-i")
        .arg(source);
    let profiles = encoded_outputs
        .iter()
        .map(|(_, profile, _)| *profile)
        .collect::<Vec<_>>();
    let log_paths = encoded_outputs
        .iter()
        .map(|(_, _, log_path)| *log_path)
        .collect::<Vec<_>>();
    let profile_outputs = encoded_outputs
        .iter()
        .map(|(output, profile, _)| (*output, *profile))
        .collect::<Vec<_>>();
    command.args([
        "-filter_complex",
        &build_profile_and_reference_filter(&profiles),
    ]);
    add_profile_outputs(&mut command, &profile_outputs, codec);
    for index in 0..encoded_outputs.len() {
        command.args(["-dec", &format!("{index}:0")]);
    }
    command.args([
        "-filter_complex",
        &build_vmaf_comparison_filter(&profiles, &log_paths),
    ]);
    for index in 0..encoded_outputs.len() {
        command.args(["-map", &format!("[vmaf{index}]"), "-f", "null", "-"]);
    }
    run_command(&mut command, "multi-profile encoding with VMAF")?;

    log_paths.into_iter().map(read_vmaf_score).collect()
}

fn add_profile_outputs(command: &mut Command, outputs: &[(&Path, &EncodingProfile)], codec: &str) {
    for (index, (output, profile)) in outputs.iter().enumerate() {
        command
            .args(["-map", &format!("[profile{index}]")])
            .args(["-an", "-c:v", codec, "-preset", &profile.preset])
            .args(["-crf", &profile.crf.to_string()]);
        if profile.max_video_bitrate_kbps > 0 {
            command.args([
                "-maxrate",
                &format!("{}k", profile.max_video_bitrate_kbps),
                "-bufsize",
                &format!("{}k", profile.max_video_bitrate_kbps * 2),
            ]);
        }
        command
            .args(["-fps_mode", "passthrough", "-movflags", "+faststart"])
            .args(["-avoid_negative_ts", "make_zero"])
            .arg(output);
    }
}

fn build_profile_filter(profiles: &[&EncodingProfile]) -> String {
    let inputs = if profiles.len() == 1 {
        "[0:v]null[split0]".to_owned()
    } else {
        format!(
            "[0:v]split={}[{}]",
            profiles.len(),
            (0..profiles.len())
                .map(|index| format!("split{index}"))
                .collect::<Vec<_>>()
                .join("][")
        )
    };
    std::iter::once(inputs)
        .chain(profiles.iter().enumerate().map(|(index, profile)| {
            format!(
                "[split{index}]scale={}:{}:flags=lanczos,setsar=1[profile{index}]",
                profile.width, profile.height
            )
        }))
        .collect::<Vec<_>>()
        .join(";")
}

fn build_profile_and_reference_filter(profiles: &[&EncodingProfile]) -> String {
    let split_outputs = (0..profiles.len())
        .map(|index| format!("split{index}"))
        .chain((0..profiles.len()).map(|index| format!("reference{index}")))
        .collect::<Vec<_>>();
    let split = format!(
        "[0:v]split={}[{}]",
        split_outputs.len(),
        split_outputs.join("][")
    );
    std::iter::once(split)
        .chain(profiles.iter().enumerate().flat_map(|(index, profile)| {
            [
                format!(
                    "[split{index}]scale={}:{}:flags=lanczos,setsar=1[profile{index}]",
                    profile.width, profile.height
                ),
                format!(
                    "[reference{index}]scale={}:{}:flags=lanczos,setsar=1,setpts=PTS-STARTPTS[scaled{index}]",
                    profile.width, profile.height
                ),
            ]
        }))
        .collect::<Vec<_>>()
        .join(";")
}

fn build_vmaf_comparison_filter(profiles: &[&EncodingProfile], log_paths: &[&Path]) -> String {
    profiles
        .iter()
        .enumerate()
        .flat_map(|(index, _)| {
            [
                format!("[dec:{index}]setpts=PTS-STARTPTS[distorted{index}]"),
                format!(
                    "[distorted{index}][scaled{index}]libvmaf=model=path=/opt/ffmpeg/share/vmaf/vmaf_v0.6.1.json:log_fmt=json:log_path={}[vmaf{index}]",
                    escape_filter_path(log_paths[index])
                ),
            ]
        })
        .collect::<Vec<_>>()
        .join(";")
}

fn run_command(command: &mut Command, operation: &str) -> Result<()> {
    let status = command
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::inherit())
        .status()
        .with_context(|| format!("Failed to start FFmpeg {operation}"))?;
    if !status.success() {
        bail!("FFmpeg {operation} exited with {status}");
    }
    Ok(())
}

fn read_vmaf_score(log_path: &Path) -> Result<f64> {
    let document: serde_json::Value = serde_json::from_slice(&fs::read(log_path)?)?;
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

    fn test_profile(name: &str, width: i32, height: i32) -> EncodingProfile {
        EncodingProfile {
            name: name.into(),
            width,
            height,
            preset: "7".into(),
            crf: 32,
            max_video_bitrate_kbps: 2_000,
        }
    }

    #[test]
    fn vmaf_uses_one_source_decode_and_one_loopback_decoder_per_layer() {
        let profiles = [
            test_profile("720p", 1280, 720),
            test_profile("480p", 854, 480),
        ];
        let references = profiles.iter().collect::<Vec<_>>();
        let source_filter = build_profile_and_reference_filter(&references);
        let logs = [Path::new("720p.json"), Path::new("480p.json")];
        let comparison_filter = build_vmaf_comparison_filter(&references, &logs);

        assert_eq!(source_filter.matches("[0:v]").count(), 1);
        assert!(source_filter.contains("[0:v]split=4[split0][split1][reference0][reference1]"));
        assert!(comparison_filter.contains("[dec:0]setpts=PTS-STARTPTS[distorted0]"));
        assert!(comparison_filter.contains("[dec:1]setpts=PTS-STARTPTS[distorted1]"));
        assert_eq!(comparison_filter.matches("libvmaf=").count(), 2);
    }

    #[test]
    fn multi_profile_filter_decodes_once_and_splits_all_layers() {
        let profiles = [
            test_profile("1080p", 1920, 1080),
            test_profile("720p", 1280, 720),
            test_profile("480p", 854, 480),
        ];
        let references = profiles.iter().collect::<Vec<_>>();
        let filter = build_profile_filter(&references);

        assert_eq!(filter.matches("[0:v]").count(), 1);
        assert!(filter.contains("[0:v]split=3[split0][split1][split2]"));
        assert!(filter.contains("[split0]scale=1920:1080:flags=lanczos,setsar=1[profile0]"));
        assert!(filter.contains("[split1]scale=1280:720:flags=lanczos,setsar=1[profile1]"));
        assert!(filter.contains("[split2]scale=854:480:flags=lanczos,setsar=1[profile2]"));
    }

    #[test]
    fn single_profile_filter_does_not_use_invalid_single_output_split() {
        let profile = test_profile("720p", 1280, 720);
        let filter = build_profile_filter(&[&profile]);

        assert_eq!(
            filter,
            "[0:v]null[split0];[split0]scale=1280:720:flags=lanczos,setsar=1[profile0]"
        );
    }

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
        let profile = select_profiles(&source, "libsvtav1", None, None, None, None, None)
            .unwrap()
            .into_iter()
            .next()
            .unwrap();
        assert_eq!(profile.name, "1080p");
        assert_eq!(profile.preset, "7");
        assert_eq!(profile.crf, 34);
        assert_eq!(profile.max_video_bitrate_kbps, 2800);
    }

    #[test]
    fn max_4k_ladder_does_not_exceed_1080p_source() {
        let source = MediaInfo {
            duration_seconds: 1.0,
            audio_duration_seconds: 1.0,
            width: 1920,
            height: 1080,
            frame_rate: 30.0,
            bit_rate: 8_000_000,
            codec_name: "h264".into(),
        };
        let profiles = select_profiles(
            &source,
            "libsvtav1",
            Some("max4k".into()),
            None,
            None,
            None,
            None,
        );
        let profiles = profiles.unwrap();
        assert_eq!(
            profiles
                .iter()
                .map(|profile| profile.name.as_str())
                .collect::<Vec<_>>(),
            vec!["1080p", "720p", "480p", "360p"]
        );
        assert!(
            profiles
                .iter()
                .all(|profile| profile.width <= source.width && profile.height <= source.height)
        );
        assert!(profiles[0].max_video_bitrate_kbps <= source.bit_rate as u32 / 1000);
        assert!(profiles.windows(2).all(|profiles| {
            profiles[1].max_video_bitrate_kbps < profiles[0].max_video_bitrate_kbps
        }));
    }

    #[test]
    fn custom_ladder_resolves_rung_references_and_inline_renditions() {
        let source = MediaInfo {
            duration_seconds: 1.0,
            audio_duration_seconds: 1.0,
            width: 1920,
            height: 1080,
            frame_rate: 30.0,
            bit_rate: 8_000_000,
            codec_name: "h264".into(),
        };
        let catalog = r#"{
            "rungs": {
                "720p": {"width":1280,"height":720,"maxVideoBitrateKbps":2800},
                "360p": {"width":640,"height":360,"maxVideoBitrateKbps":800}
            },
            "presets": {
                "conference": {
                    "type":"custom",
                    "renditions":[
                        {"rung":"720p"},
                        {"name":"540p-low","width":960,"height":540,"maxVideoBitrateKbps":1100},
                        {"rung":"360p","maxVideoBitrateKbps":650}
                    ]
                }
            }
        }"#;

        let profiles = select_profiles(
            &source,
            "libsvtav1",
            Some("conference".into()),
            None,
            None,
            None,
            Some(catalog),
        )
        .unwrap();

        assert_eq!(
            profiles
                .iter()
                .map(|profile| profile.name.as_str())
                .collect::<Vec<_>>(),
            vec!["720p", "540p-low", "360p"]
        );
        assert!(profiles[2].max_video_bitrate_kbps <= 650);
        assert!(is_configured_ladder_preset(
            Some("conference"),
            Some(catalog)
        ));
    }
}
