const std = @import("std");
const format_util = @import("format.zig");

pub const CpuTemp = struct {
    format: []const u8,
    device: []const u8,
    interval_secs: u64,
    color: c_ulong,
    bg: c_ulong,
    cached_path: [128]u8,
    cached_path_len: usize,

    pub fn init(
        format: []const u8,
        device: []const u8,
        interval_secs: u64,
        color: c_ulong,
        background: c_ulong,
    ) CpuTemp {
        var self = CpuTemp{
            .format = format,
            .device = device,
            .interval_secs = interval_secs,
            .color = color,
            .bg = background,
            .cached_path = undefined,
            .cached_path_len = 0,
        };
        self.detectPath();
        return self;
    }

    fn detectPath(self: *CpuTemp) void {
        if (self.device.len > 0 and self.device[0] == '/') {
            if (self.device.len <= self.cached_path.len) {
                @memcpy(self.cached_path[0..self.device.len], self.device);
                self.cached_path_len = self.device.len;
            }
            return;
        }

        if (self.device.len > 0) {
            if (self.tryPath("/sys/class/thermal/{s}/temp", self.device)) return;
            if (self.tryPath("/sys/class/hwmon/{s}/temp1_input", self.device)) return;
        }

        if (self.findHwmonCpu()) return;

        if (self.tryPath("/sys/class/thermal/{s}/temp", "thermal_zone0")) return;
    }

    fn tryPath(self: *CpuTemp, comptime fmt: []const u8, device: []const u8) bool {
        const path = std.fmt.bufPrint(&self.cached_path, fmt, .{device}) catch return false;
        const file = std.fs.openFileAbsolute(path, .{}) catch return false;
        file.close();
        self.cached_path_len = path.len;
        return true;
    }

    fn findHwmonCpu(self: *CpuTemp) bool {
        var dir = std.fs.openDirAbsolute("/sys/class/hwmon", .{ .iterate = true }) catch return false;
        defer dir.close();

        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            if (entry.kind != .directory and entry.kind != .sym_link) continue;

            var name_path: [128]u8 = undefined;
            const name_path_str = std.fmt.bufPrint(&name_path, "/sys/class/hwmon/{s}/name", .{entry.name}) catch continue;

            const name_file = std.fs.openFileAbsolute(name_path_str, .{}) catch continue;
            defer name_file.close();

            var name_buf: [32]u8 = undefined;
            const name_len = name_file.read(&name_buf) catch continue;
            const name = std.mem.trim(u8, name_buf[0..name_len], " \n\r\t");

            if (std.mem.eql(u8, name, "coretemp") or std.mem.eql(u8, name, "k10temp")) {
                const temp_path = std.fmt.bufPrint(&self.cached_path, "/sys/class/hwmon/{s}/temp1_input", .{entry.name}) catch continue;
                const temp_file = std.fs.openFileAbsolute(temp_path, .{}) catch continue;
                temp_file.close();
                self.cached_path_len = temp_path.len;
                return true;
            }
        }
        return false;
    }

    pub fn content(self: *CpuTemp, buffer: []u8) []const u8 {
        if (self.cached_path_len == 0) return buffer[0..0];

        const path = self.cached_path[0..self.cached_path_len];
        const file = std.fs.openFileAbsolute(path, .{}) catch return buffer[0..0];
        defer file.close();

        var temp_buf: [16]u8 = undefined;
        const len = file.read(&temp_buf) catch return buffer[0..0];
        const temp_str = std.mem.trim(u8, temp_buf[0..len], " \n\r\t");

        const millidegrees = std.fmt.parseInt(i32, temp_str, 10) catch return buffer[0..0];
        const degrees = @divTrunc(millidegrees, 1000);

        var deg_buf: [8]u8 = undefined;
        const deg_str = std.fmt.bufPrint(&deg_buf, "{d}", .{degrees}) catch return buffer[0..0];

        return format_util.substitute(self.format, deg_str, buffer);
    }

    pub fn interval(self: *CpuTemp) u64 {
        return self.interval_secs;
    }

    pub fn getColor(self: *CpuTemp) c_ulong {
        return self.color;
    }
};
