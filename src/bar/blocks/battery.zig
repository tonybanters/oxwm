const std = @import("std");
const format_util = @import("format.zig");

pub const Battery = struct {
    format_charging: []const u8,
    format_discharging: []const u8,
    format_full: []const u8,
    battery_name: []const u8,
    interval_secs: u64,
    color: c_ulong,
    bg: c_ulong,

    pub fn init(
        format_charging: []const u8,
        format_discharging: []const u8,
        format_full: []const u8,
        battery_name: []const u8,
        interval_secs: u64,
        color: c_ulong,
        background: c_ulong,
    ) Battery {
        return .{
            .format_charging = format_charging,
            .format_discharging = format_discharging,
            .format_full = format_full,
            .battery_name = if (battery_name.len > 0) battery_name else "BAT0",
            .interval_secs = interval_secs,
            .color = color,
            .bg = background,
        };
    }

    pub fn content(self: *Battery, buffer: []u8) []const u8 {
        var path_buf: [128]u8 = undefined;

        const capacity = self.readBatteryFile(&path_buf, "capacity") orelse return buffer[0..0];
        const status = self.readBatteryStatus(&path_buf) orelse return buffer[0..0];

        const format = switch (status) {
            .charging => self.format_charging,
            .discharging => self.format_discharging,
            .full => self.format_full,
        };

        var cap_buf: [8]u8 = undefined;
        const cap_str = std.fmt.bufPrint(&cap_buf, "{d}", .{capacity}) catch return buffer[0..0];

        return format_util.substitute(format, cap_str, buffer);
    }

    const Status = enum { charging, discharging, full };

    fn readBatteryStatus(self: *Battery, path_buf: *[128]u8) ?Status {
        const path = std.fmt.bufPrint(path_buf, "/sys/class/power_supply/{s}/status", .{self.battery_name}) catch return null;

        const file = std.fs.openFileAbsolute(path, .{}) catch return null;
        defer file.close();

        var buf: [32]u8 = undefined;
        const len = file.read(&buf) catch return null;
        const status_str = std.mem.trim(u8, buf[0..len], " \n\r\t");

        if (std.mem.eql(u8, status_str, "Charging")) return .charging;
        if (std.mem.eql(u8, status_str, "Discharging")) return .discharging;
        if (std.mem.eql(u8, status_str, "Full")) return .full;
        if (std.mem.eql(u8, status_str, "Not charging")) return .full;
        return .discharging;
    }

    fn readBatteryFile(self: *Battery, path_buf: *[128]u8, file_name: []const u8) ?u8 {
        const path = std.fmt.bufPrint(path_buf, "/sys/class/power_supply/{s}/{s}", .{ self.battery_name, file_name }) catch return null;

        const file = std.fs.openFileAbsolute(path, .{}) catch return null;
        defer file.close();

        var buf: [16]u8 = undefined;
        const len = file.read(&buf) catch return null;
        const value_str = std.mem.trim(u8, buf[0..len], " \n\r\t");

        return std.fmt.parseInt(u8, value_str, 10) catch null;
    }

    pub fn interval(self: *Battery) u64 {
        return self.interval_secs;
    }

    pub fn getColor(self: *Battery) c_ulong {
        return self.color;
    }
};
