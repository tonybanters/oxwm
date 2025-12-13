use super::Block;
use crate::errors::BlockError;
use std::fs;
use std::time::Duration;

pub struct Battery {
    format_charging: String,
    format_discharging: String,
    format_full: String,
    battery_name: Option<String>,
    interval: Duration,
    color: u32,
    battery_path: String,
}

impl Battery {
    pub fn new(
        format_charging: &str,
        format_discharging: &str,
        format_full: &str,
        battery_name: Option<&str>,
        interval_secs: u64,
        color: u32,
    ) -> Self {
        let battery_name = battery_name
            .filter(|s| !s.trim().is_empty())
            .unwrap_or("BAT0");
        let battery_path = format!("/sys/class/power_supply/{}", battery_name);

        Self {
            format_charging: format_charging.to_string(),
            format_discharging: format_discharging.to_string(),
            format_full: format_full.to_string(),
            battery_name: Some(battery_name.to_string()),
            interval: Duration::from_secs(interval_secs),
            color,
            battery_path,
        }
    }

    fn read_file(&self, filename: &str) -> Result<String, BlockError> {
        let path = format!("{}/{}", self.battery_path, filename);
        Ok(fs::read_to_string(path)?.trim().to_string())
    }

    fn get_capacity(&self) -> Result<u32, BlockError> {
        Ok(self.read_file("capacity")?.parse()?)
    }

    fn get_status(&self) -> Result<String, BlockError> {
        self.read_file("status")
    }
}

impl Block for Battery {
    fn content(&mut self) -> Result<String, BlockError> {
        let capacity = self.get_capacity()?;
        let status = self.get_status()?;

        let format = match status.as_str() {
            "Charging" => &self.format_charging,
            "Full" => &self.format_full,
            _ => &self.format_discharging,
        };

        Ok(format.replace("{}", &capacity.to_string()))
    }

    fn interval(&self) -> Duration {
        self.interval
    }

    fn color(&self) -> u32 {
        self.color
    }
}
