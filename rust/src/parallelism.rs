use crate::contracts::VideoSegment;
use anyhow::{bail, Result};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EncodingJobDemand {
    pub name: String,
    pub remaining_segments: i32,
}

pub fn fixed_duration_segments(duration: f64, target: u32) -> Vec<VideoSegment> {
    let mut segments = Vec::new();
    let mut start = 0.0;
    while start < duration {
        let segment_duration = f64::from(target).min(duration - start);
        segments.push(VideoSegment {
            index: segments.len(),
            start_seconds: start,
            duration_seconds: segment_duration,
        });
        start += segment_duration;
    }
    segments
}

pub fn keyframe_segments(duration: f64, target: u32, mut keyframes: Vec<f64>) -> Vec<VideoSegment> {
    keyframes.retain(|value| *value >= 0.0 && *value <= duration);
    keyframes.sort_by(f64::total_cmp);
    keyframes.dedup_by(|a, b| (*a - *b).abs() < 0.000001);
    if keyframes.first().is_none_or(|value| *value > 0.0) {
        keyframes.insert(0, 0.0);
    }
    if keyframes.last().is_none_or(|value| *value < duration) {
        keyframes.push(duration);
    }

    let mut boundaries = vec![0.0];
    let mut start = 0.0;
    while start < duration - 0.0001 {
        let wanted = start + f64::from(target);
        let next = keyframes
            .iter()
            .copied()
            .rfind(|value| *value > start + 0.0001 && *value <= wanted + 0.0001)
            .or_else(|| {
                keyframes
                    .iter()
                    .copied()
                    .find(|value| *value > start + 0.0001)
            })
            .unwrap_or(duration)
            .min(duration);
        boundaries.push(next);
        start = next;
    }
    boundaries
        .windows(2)
        .enumerate()
        .map(|(index, pair)| VideoSegment {
            index,
            start_seconds: pair[0],
            duration_seconds: pair[1] - pair[0],
        })
        .collect()
}

pub fn allocate(
    jobs: impl IntoIterator<Item = EncodingJobDemand>,
    max: i32,
) -> Result<std::collections::BTreeMap<String, i32>> {
    if max < 1 {
        bail!("Max parallelism must be greater than zero");
    }
    let mut pending = jobs
        .into_iter()
        .filter(|job| job.remaining_segments > 0)
        .collect::<Vec<_>>();
    pending.sort_by(|a, b| a.name.cmp(&b.name));
    let mut result = std::collections::BTreeMap::new();
    if pending.len() as i32 >= max {
        for (index, job) in pending.into_iter().enumerate() {
            result.insert(job.name, i32::from(index < max as usize));
        }
        return Ok(result);
    }
    let mut available = max;
    while !pending.is_empty() {
        let share = available / pending.len() as i32;
        let completed = pending
            .iter()
            .filter(|job| job.remaining_segments <= share)
            .cloned()
            .collect::<Vec<_>>();
        if completed.is_empty() {
            let remainder = available % pending.len() as i32;
            for (index, job) in pending.into_iter().enumerate() {
                result.insert(
                    job.name,
                    job.remaining_segments
                        .min(share + i32::from(index < remainder as usize)),
                );
            }
            break;
        }
        for job in completed {
            result.insert(job.name.clone(), job.remaining_segments);
            available -= job.remaining_segments;
            pending.retain(|item| item.name != job.name);
        }
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn distributes_global_budget() {
        let jobs = vec![
            EncodingJobDemand {
                name: "a".into(),
                remaining_segments: 2,
            },
            EncodingJobDemand {
                name: "b".into(),
                remaining_segments: 8,
            },
        ];
        let result = allocate(jobs, 6).unwrap();
        assert_eq!(result["a"], 2);
        assert_eq!(result["b"], 4);
    }
}
