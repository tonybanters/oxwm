use super::Block;
use crate::errors::BlockError;
use std::process::Command;
use std::time::Duration;

pub struct Volume {
    format: String,
    interval: Duration,
    color: u32,
}

impl Volume {
    pub fn new(format: &str, interval_secs: u64, color: u32) -> Self {
        Self {
            format: format.to_string(),
            interval: Duration::from_secs(interval_secs),
            color,
        }
    }

    fn get_volume_percentage(&self) -> Result<Option<u32>, BlockError> {
        // Try wpctl first (PipeWire)
        if let Ok(output) = Command::new("wpctl")
            .arg("status")
            .output()
        {
            if output.status.success() {
                let stdout = String::from_utf8_lossy(&output.stdout);
                
                // Find default sink ID
                let mut sink_id: Option<u32> = None;
                let mut in_sinks = false;
                for line in stdout.lines() {
                    if line.contains("Sinks:") {
                        in_sinks = true;
                        continue;
                    }
                    if in_sinks && line.contains('*') {
                        // Extract sink ID (format: "  * 42. Sink Name")
                        for part in line.split_whitespace() {
                            if part.ends_with('.') {
                                if let Ok(id) = part.trim_end_matches('.').parse::<u32>() {
                                    sink_id = Some(id);
                                    break;
                                }
                            }
                        }
                        if sink_id.is_some() {
                            break;
                        }
                    }
                }

                if let Some(sink) = sink_id {
                    if let Ok(vol_output) = Command::new("wpctl")
                        .arg("get-volume")
                        .arg(sink.to_string())
                        .output()
                    {
                        if vol_output.status.success() {
                            let vol_stdout = String::from_utf8_lossy(&vol_output.stdout);
                            
                            // Check if muted
                            if vol_stdout.contains("MUTED") {
                                return Ok(None); // None means muted
                            }
                            
                            // Extract volume (format: "Volume: 0.50" or "Volume: 0.50 [MUTED]")
                            for part in vol_stdout.split_whitespace() {
                                if let Ok(vol) = part.parse::<f32>() {
                                    let percentage = (vol * 100.0) as u32;
                                    return Ok(Some(percentage));
                                }
                            }
                        }
                    }
                }
            }
        }

        // Fallback to pactl (PulseAudio)
        if let Ok(output) = Command::new("pactl")
            .arg("info")
            .output()
        {
            if output.status.success() {
                let stdout = String::from_utf8_lossy(&output.stdout);
                let mut default_sink: Option<String> = None;
                
                for line in stdout.lines() {
                    if line.starts_with("Default Sink:") {
                        default_sink = line.split(':').nth(1).map(|s| s.trim().to_string());
                        break;
                    }
                }

                if let Some(sink) = default_sink {
                    // Check mute status
                    if let Ok(mute_output) = Command::new("pactl")
                        .arg("get-sink-mute")
                        .arg(&sink)
                        .output()
                    {
                        if mute_output.status.success() {
                            let mute_stdout = String::from_utf8_lossy(&mute_output.stdout);
                            if mute_stdout.contains("yes") {
                                return Ok(None); // None means muted
                            }
                        }
                    }

                    // Get volume
                    if let Ok(vol_output) = Command::new("pactl")
                        .arg("get-sink-volume")
                        .arg(&sink)
                        .output()
                    {
                        if vol_output.status.success() {
                            let vol_stdout = String::from_utf8_lossy(&vol_output.stdout);
                            // Extract percentage (format: "Volume: front-left: 32768 /  50% / ...")
                            for part in vol_stdout.split_whitespace() {
                                if part.ends_with('%') {
                                    if let Ok(pct) = part.trim_end_matches('%').parse::<u32>() {
                                        return Ok(Some(pct));
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        Ok(Some(0))
    }
}

impl Block for Volume {
    fn content(&mut self) -> Result<String, BlockError> {
        match self.get_volume_percentage()? {
            Some(percentage) => Ok(self.format.replace("{}", &percentage.to_string())),
            None => Ok(self.format.replace("{}", "Muted")),
        }
    }

    fn interval(&self) -> Duration {
        self.interval
    }

    fn color(&self) -> u32 {
        self.color
    }
}

