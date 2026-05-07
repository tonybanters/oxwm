const std = @import("std");
const config_mod = @import("../../config/config.zig");

pub const Static = @import("static.zig").Static;
pub const DateTime = @import("datetime.zig").DateTime;
pub const Ram = @import("ram.zig").Ram;
pub const Shell = @import("shell.zig").Shell;
pub const Battery = @import("battery.zig").Battery;
pub const CpuTemp = @import("cpu_temp.zig").CpuTemp;

pub const Block = struct {
    data: Data,
    last_update: i64,
    cached_content: [256]u8,
    cached_len: usize,
    underline: bool,
    click: ?config_mod.ClickAction = null,
    x_start: i32 = 0,
    x_end: i32 = 0,

    pub const Data = union(enum) {
        static: Static,
        datetime: DateTime,
        ram: Ram,
        shell: Shell,
        battery: Battery,
        cpu_temp: CpuTemp,
    };

    pub fn initStatic(text: []const u8, col: c_ulong, background: c_ulong, ul: bool) Block {
        var block = Block{
            .data = .{ .static = Static.init(text, col, background) },
            .last_update = 0,
            .cached_content = undefined,
            .cached_len = 0,
            .underline = ul,
        };
        @memcpy(block.cached_content[0..text.len], text);
        block.cached_len = text.len;
        return block;
    }

    pub fn initDatetime(format: []const u8, datetime_format: []const u8, interval_secs: u64, col: c_ulong, background: c_ulong, ul: bool) Block {
        return .{
            .data = .{ .datetime = DateTime.init(format, datetime_format, interval_secs, col, background) },
            .last_update = 0,
            .cached_content = undefined,
            .cached_len = 0,
            .underline = ul,
        };
    }

    pub fn initRam(format: []const u8, interval_secs: u64, col: c_ulong, background: c_ulong, ul: bool) Block {
        return .{
            .data = .{ .ram = Ram.init(format, interval_secs, col, background) },
            .last_update = 0,
            .cached_content = undefined,
            .cached_len = 0,
            .underline = ul,
        };
    }

    pub fn initShell(format: []const u8, command: []const u8, interval_secs: u64, col: c_ulong, background: c_ulong, ul: bool) Block {
        return .{
            .data = .{ .shell = Shell.init(format, command, interval_secs, col, background) },
            .last_update = 0,
            .cached_content = undefined,
            .cached_len = 0,
            .underline = ul,
        };
    }

    pub fn initBattery(
        format_charging: []const u8,
        format_discharging: []const u8,
        format_full: []const u8,
        battery_name: []const u8,
        interval_secs: u64,
        col: c_ulong,
        background: c_ulong,
        ul: bool,
    ) Block {
        return .{
            .data = .{ .battery = Battery.init(format_charging, format_discharging, format_full, battery_name, interval_secs, col, background) },
            .last_update = 0,
            .cached_content = undefined,
            .cached_len = 0,
            .underline = ul,
        };
    }

    pub fn initCpuTemp(
        format: []const u8,
        thermal_zone: []const u8,
        interval_secs: u64,
        col: c_ulong,
        background: c_ulong,
        ul: bool,
    ) Block {
        return .{
            .data = .{ .cpu_temp = CpuTemp.init(format, thermal_zone, interval_secs, col, background) },
            .last_update = 0,
            .cached_content = undefined,
            .cached_len = 0,
            .underline = ul,
        };
    }

    pub fn update(self: *Block) bool {
        const interval_secs = self.interval();
        if (interval_secs == 0) return false;

        const now = std.time.timestamp();
        if (now - self.last_update < @as(i64, @intCast(interval_secs))) {
            return false;
        }

        self.last_update = now;

        const result = switch (self.data) {
            .static => |*s| s.content(&self.cached_content),
            .datetime => |*d| d.content(&self.cached_content),
            .ram => |*r| r.content(&self.cached_content),
            .shell => |*s| s.content(&self.cached_content),
            .battery => |*b| b.content(&self.cached_content),
            .cpu_temp => |*c| c.content(&self.cached_content),
        };

        self.cached_len = result.len;
        return true;
    }

    pub fn interval(self: *Block) u64 {
        return switch (self.data) {
            .static => |*s| s.interval(),
            .datetime => |*d| d.interval(),
            .ram => |*r| r.interval(),
            .shell => |*s| s.interval(),
            .battery => |*b| b.interval(),
            .cpu_temp => |*c| c.interval(),
        };
    }

    pub fn color(self: *const Block) c_ulong {
        return switch (self.data) {
            .static => |s| s.color,
            .datetime => |d| d.color,
            .ram => |r| r.color,
            .shell => |s| s.color,
            .battery => |b| b.color,
            .cpu_temp => |c| c.color,
        };
    }

    pub fn bg(self: *const Block) c_ulong {
        return switch (self.data) {
            .static => |s| s.bg,
            .datetime => |d| d.bg,
            .ram => |r| r.bg,
            .shell => |s| s.bg,
            .battery => |b| b.bg,
            .cpu_temp => |c| c.bg,
        };
    }

    pub fn getContent(self: *const Block) []const u8 {
        return self.cached_content[0..self.cached_len];
    }
};
