use super::Block;
use crate::errors::BlockError;
use std::fs;
use std::time::Duration;

pub struct Cpu {
    format: String,
    interval: Duration,
    color: u32,
    last_total: u64,
    last_idle: u64,
}

impl Cpu {
    pub fn new(format: &str, interval_secs: u64, color: u32) -> Self {
        Self {
            format: format.to_string(),
            interval: Duration::from_secs(interval_secs),
            color,
            last_total: 0,
            last_idle: 0,
        }
    }

    fn get_cpu_info(&mut self) -> Result<f32, BlockError> {
        let stat = fs::read_to_string("/proc/stat")?;
        let mut total: u64 = 0;
        let mut idle: u64 = 0;

        for line in stat.lines() {
            if line.starts_with("cpu ") {
                let parts: Vec<&str> = line.split_whitespace().collect();
                let values: Vec<u64> = parts[1..]
                    .iter()
                    .filter_map(|v| v.parse::<u64>().ok())
                    .collect();

                total = values.iter().sum();
                idle = values[3] + values.get(4).unwrap_or(&0);
                break;
            }
        }

        if self.last_total == 0 || self.last_idle == 0 {
            self.last_total = total;
            self.last_idle = idle;
            return Ok(0.0);
        }

        let total_diff = total.saturating_sub(self.last_total);
        let idle_diff = idle.saturating_sub(self.last_idle);

        self.last_total = total;
        self.last_idle = idle;

        let usage = if total_diff > 0 {
            ((total_diff - idle_diff) as f32 / total_diff as f32) * 100.0
        } else {
            0.0
        };

        Ok(usage)
    }
}

impl Block for Cpu {
    fn content(&mut self) -> Result<String, BlockError> {
        let usage = self.get_cpu_info()?;
        let result = self
            .format
            .replace("{percent}", &format!("{:.1}", usage))
            .replace("{}", &format!("{:.1}", usage));

        Ok(result)
    }

    fn interval(&self) -> Duration {
        self.interval
    }

    fn color(&self) -> u32 {
        self.color
    }
}

