use crate::errors::BlockError;
use std::time::Duration;

mod battery;
mod datetime;
mod ram;
mod shell;

use battery::Battery;
use datetime::DateTime;
use ram::Ram;
use shell::ShellBlock;

pub trait Block {
    fn content(&mut self) -> Result<String, BlockError>;
    fn interval(&self) -> Duration;
    fn color(&self) -> u32;
}

#[derive(Debug, Clone)]
pub struct BlockConfig {
    pub format: String,
    pub command: BlockCommand,
    pub interval_secs: u64,
    pub color: u32,
    pub underline: bool,
}

#[derive(Debug, Clone)]
pub enum BlockCommand {
    Shell(String),
    DateTime(String),
    Battery {
        format_charging: String,
        format_discharging: String,
        format_full: String,
        battery_name: Option<String>,
    },
    Ram,
    Static(String),
}

impl BlockConfig {
    pub fn to_block(&self) -> Box<dyn Block> {
        match &self.command {
            BlockCommand::Shell(cmd) => Box::new(ShellBlock::new(
                &self.format,
                cmd,
                self.interval_secs,
                self.color,
            )),
            BlockCommand::DateTime(fmt) => Box::new(DateTime::new(
                &self.format,
                fmt,
                self.interval_secs,
                self.color,
            )),
            BlockCommand::Battery {
                format_charging,
                format_discharging,
                format_full,
                battery_name,
            } => Box::new(Battery::new(
                format_charging,
                format_discharging,
                format_full,
                battery_name.as_deref(),
                self.interval_secs,
                self.color,
            )),
            BlockCommand::Ram => Box::new(Ram::new(&self.format, self.interval_secs, self.color)),
            BlockCommand::Static(text) => Box::new(StaticBlock::new(
                &format!("{}{}", self.format, text),
                self.color,
            )),
        }
    }
}

struct StaticBlock {
    text: String,
    color: u32,
}

impl StaticBlock {
    fn new(text: &str, color: u32) -> Self {
        Self {
            text: text.to_string(),
            color,
        }
    }
}

impl Block for StaticBlock {
    fn content(&mut self) -> Result<String, BlockError> {
        Ok(self.text.clone())
    }

    fn interval(&self) -> Duration {
        Duration::from_secs(u64::MAX)
    }

    fn color(&self) -> u32 {
        self.color
    }
}
