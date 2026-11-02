const std = @import("std");

pub const Easing = enum {
    linear,
    ease_out,
    ease_in_out,

    pub fn apply(self: Easing, t: f64) f64 {
        return switch (self) {
            .linear => t,
            .ease_out => 1.0 - std.math.pow(f64, 1.0 - t, 3),
            .ease_in_out => if (t < 0.5)
                4.0 * t * t * t
            else
                1.0 - std.math.pow(f64, -2.0 * t + 2.0, 3) / 2.0,
        };
    }
};

pub const AnimationConfig = struct {
    duration_ms: u64 = 150,
    easing: Easing = .ease_out,
};

pub const SpringConfig = struct {
    stiffness: f64 = 800.0,
    damping_ratio: f64 = 1.0,
    epsilon: f64 = 0.5,
    max_duration_ms: i64 = 2000,
};

pub const ScrollAnimation = struct {
    start_value: i32 = 0,
    end_value: i32 = 0,
    start_time: i64 = 0,
    duration_ms: u64 = 150,
    easing: Easing = .ease_out,
    active: bool = false,
    spring: bool = false,
    velocity: f64 = 0,
    spring_config: SpringConfig = .{},

    pub fn start(self: *ScrollAnimation, io: std.Io, from: i32, to: i32, config: AnimationConfig) void {
        if (from == to) {
            self.active = false;
            return;
        }
        self.start_value = from;
        self.end_value = to;
        self.start_time = std.Io.Timestamp.now(io, .awake).toMilliseconds();
        self.duration_ms = config.duration_ms;
        self.easing = config.easing;
        self.spring = false;
        self.active = true;
    }

    /// Starts a critically damped spring from `from` to `to` that carries
    /// the initial `velocity` (in pixels per second) into the motion.
    pub fn startSpring(self: *ScrollAnimation, io: std.Io, from: i32, to: i32, velocity: f64, config: SpringConfig) void {
        if (from == to) {
            self.active = false;
            return;
        }
        self.start_value = from;
        self.end_value = to;
        self.start_time = std.Io.Timestamp.now(io, .awake).toMilliseconds();
        self.velocity = velocity;
        self.spring_config = config;
        self.spring = true;
        self.active = true;
    }

    fn springPosition(self: *const ScrollAnimation, elapsed_ms: i64) f64 {
        const t = @as(f64, @floatFromInt(elapsed_ms)) / 1000.0;
        const beta = self.spring_config.damping_ratio * @sqrt(self.spring_config.stiffness);
        const to: f64 = @floatFromInt(self.end_value);
        const x0 = @as(f64, @floatFromInt(self.start_value)) - to;
        return to + @exp(-beta * t) * (x0 + (beta * x0 + self.velocity) * t);
    }

    pub fn update(self: *ScrollAnimation, io: std.Io) ?i32 {
        if (!self.active) return null;

        const now = std.Io.Timestamp.now(io, .awake).toMilliseconds();
        const elapsed = now - self.start_time;

        if (self.spring) {
            const pos = self.springPosition(elapsed);
            const settled = @abs(pos - @as(f64, @floatFromInt(self.end_value))) < self.spring_config.epsilon;
            if (settled or elapsed > self.spring_config.max_duration_ms) {
                self.active = false;
                return self.end_value;
            }
            return @intFromFloat(pos);
        }

        if (elapsed >= @as(i64, @intCast(self.duration_ms))) {
            self.active = false;
            return self.end_value;
        }

        const t = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(self.duration_ms));
        const eased = self.easing.apply(t);
        const diff = @as(f64, @floatFromInt(self.end_value - self.start_value));
        const current = @as(f64, @floatFromInt(self.start_value)) + (diff * eased);

        return @intFromFloat(current);
    }

    pub fn isActive(self: *const ScrollAnimation) bool {
        return self.active;
    }

    pub fn target(self: *const ScrollAnimation) i32 {
        return self.end_value;
    }

    pub fn stop(self: *ScrollAnimation) void {
        self.active = false;
    }
};
