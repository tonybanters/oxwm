use super::Block;
use crate::errors::BlockError;
use std::process::Command;
use std::time::Duration;

pub struct Wifi {
    format: String,
    interval: Duration,
    color: u32,
}

impl Wifi {
    pub fn new(format: &str, interval_secs: u64, color: u32) -> Self {
        Self {
            format: format.to_string(),
            interval: Duration::from_secs(interval_secs),
            color,
        }
    }

    fn get_wifi_ssid(&self) -> Result<String, BlockError> {
        // Try nmcli first (NetworkManager)
        if let Ok(output) = Command::new("nmcli")
            .arg("-t")
            .arg("-f")
            .arg("ACTIVE,SSID")
            .arg("dev")
            .arg("wifi")
            .output()
        {
            if output.status.success() {
                let stdout = String::from_utf8_lossy(&output.stdout);
                for line in stdout.lines() {
                    if line.starts_with("yes:") {
                        // Split by ':' and get the SSID (second field)
                        let parts: Vec<&str> = line.split(':').collect();
                        if parts.len() >= 2 {
                            let ssid = parts[1].trim();
                            if !ssid.is_empty() {
                                return Ok(ssid.to_string());
                            }
                        }
                    }
                }
            }
        }

        // Check if WiFi is enabled but not connected
        if let Ok(output) = Command::new("nmcli")
            .arg("-t")
            .arg("-f")
            .arg("WIFI")
            .arg("g")
            .output()
        {
            if output.status.success() {
                let wifi_state = String::from_utf8_lossy(&output.stdout).trim().to_string();
                if wifi_state == "enabled" {
                    return Ok("Disconnected".to_string());
                } else {
                    return Ok("Off".to_string());
                }
            }
        }

        Ok("N/A".to_string())
    }
}

impl Block for Wifi {
    fn content(&mut self) -> Result<String, BlockError> {
        let ssid = self.get_wifi_ssid()?;
        Ok(self.format.replace("{}", &ssid))
    }

    fn interval(&self) -> Duration {
        self.interval
    }

    fn color(&self) -> u32 {
        self.color
    }
}

