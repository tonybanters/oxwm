use std::time::Instant;
use super::{AnimationConfig, Easing};

pub struct ScrollAnimation {
    start_value: i32,
    end_value: i32,
    start_time: Instant,
    duration_ms: u64,
    easing: Easing,
    active: bool,
}

impl ScrollAnimation {
    pub fn new() -> Self {
        Self {
            start_value: 0,
            end_value: 0,
            start_time: Instant::now(),
            duration_ms: 150,
            easing: Easing::EaseOut,
            active: false,
        }
    }

    pub fn start(&mut self, from: i32, to: i32, config: &AnimationConfig) {
        if from == to {
            self.active = false;
            return;
        }
        self.start_value = from;
        self.end_value = to;
        self.start_time = Instant::now();
        self.duration_ms = config.duration.as_millis() as u64;
        self.easing = config.easing;
        self.active = true;
    }

    pub fn update(&mut self) -> Option<i32> {
        if !self.active {
            return None;
        }

        let elapsed = self.start_time.elapsed().as_millis() as u64;

        if elapsed >= self.duration_ms {
            self.active = false;
            return Some(self.end_value);
        }

        let t = elapsed as f64 / self.duration_ms as f64;
        let eased_t = self.easing.apply(t);

        let delta = (self.end_value - self.start_value) as f64;
        let current = self.start_value as f64 + delta * eased_t;

        Some(current.round() as i32)
    }

    pub fn is_active(&self) -> bool {
        self.active
    }

    pub fn target(&self) -> i32 {
        self.end_value
    }

    pub fn cancel(&mut self) {
        self.active = false;
    }
}

impl Default for ScrollAnimation {
    fn default() -> Self {
        Self::new()
    }
}

