const std = @import("std");
const format_util = @import("format.zig");
const c = @cImport({
    @cInclude("time.h");
});

pub const DateTime = struct {
    format: []const u8,
    datetime_format: []const u8,
    interval_secs: u64,
    color: c_ulong,
    bg: c_ulong,

    pub fn init(format: []const u8, datetime_format: []const u8, interval_secs: u64, color: c_ulong, background: c_ulong) DateTime {
        return .{
            .format = format,
            .datetime_format = datetime_format,
            .interval_secs = interval_secs,
            .color = color,
            .bg = background,
        };
    }

    pub fn content(self: *DateTime, buffer: []u8) []const u8 {
        var now: c.time_t = c.time(null);
        const tm_ptr = c.localtime(&now);
        if (tm_ptr == null) return buffer[0..0];
        const tm = tm_ptr.*;

        const hours: u32 = @intCast(tm.tm_hour);
        const minutes: u32 = @intCast(tm.tm_min);
        const seconds: u32 = @intCast(tm.tm_sec);
        const day: u8 = @intCast(tm.tm_mday);
        const month: u8 = @intCast(tm.tm_mon + 1);
        const year: i32 = tm.tm_year + 1900;
        const dow: i32 = tm.tm_wday;

        var datetime_buf: [64]u8 = undefined;
        var dt_len: usize = 0;

        var fmt_idx: usize = 0;
        while (fmt_idx < self.datetime_format.len and dt_len < datetime_buf.len - 10) {
            if (self.datetime_format[fmt_idx] == '%' and fmt_idx + 1 < self.datetime_format.len) {
                const next = self.datetime_format[fmt_idx + 1];
                if (next == '-' and fmt_idx + 2 < self.datetime_format.len) {
                    const spec = self.datetime_format[fmt_idx + 2];
                    dt_len += formatSpec(spec, false, hours, minutes, seconds, day, month, year, dow, datetime_buf[dt_len..]);
                    fmt_idx += 3;
                } else {
                    dt_len += formatSpec(next, true, hours, minutes, seconds, day, month, year, dow, datetime_buf[dt_len..]);
                    fmt_idx += 2;
                }
            } else {
                datetime_buf[dt_len] = self.datetime_format[fmt_idx];
                dt_len += 1;
                fmt_idx += 1;
            }
        }

        return format_util.substitute(self.format, datetime_buf[0..dt_len], buffer);
    }

    fn formatSpec(spec: u8, pad: bool, hours: u32, minutes: u32, seconds: u32, day: u8, month: u8, year: i32, dow: i32, buf: []u8) usize {
        const day_names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
        const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

        return switch (spec) {
            'Y' => (std.fmt.bufPrint(buf, "{d}", .{year}) catch return 0).len,
            'm' => if (pad) (std.fmt.bufPrint(buf, "{d:0>2}", .{month}) catch return 0).len else (std.fmt.bufPrint(buf, "{d}", .{month}) catch return 0).len,
            'd' => if (pad) (std.fmt.bufPrint(buf, "{d:0>2}", .{day}) catch return 0).len else (std.fmt.bufPrint(buf, "{d}", .{day}) catch return 0).len,
            'H' => if (pad) (std.fmt.bufPrint(buf, "{d:0>2}", .{hours}) catch return 0).len else (std.fmt.bufPrint(buf, "{d}", .{hours}) catch return 0).len,
            'M' => if (pad) (std.fmt.bufPrint(buf, "{d:0>2}", .{minutes}) catch return 0).len else (std.fmt.bufPrint(buf, "{d}", .{minutes}) catch return 0).len,
            'S' => if (pad) (std.fmt.bufPrint(buf, "{d:0>2}", .{seconds}) catch return 0).len else (std.fmt.bufPrint(buf, "{d}", .{seconds}) catch return 0).len,
            'I' => blk: {
                const h12 = if (hours == 0) 12 else if (hours > 12) hours - 12 else hours;
                break :blk if (pad) (std.fmt.bufPrint(buf, "{d:0>2}", .{h12}) catch return 0).len else (std.fmt.bufPrint(buf, "{d}", .{h12}) catch return 0).len;
            },
            'p' => blk: {
                const s: []const u8 = if (hours >= 12) "PM" else "AM";
                @memcpy(buf[0..2], s);
                break :blk 2;
            },
            'P' => blk: {
                const s: []const u8 = if (hours >= 12) "pm" else "am";
                @memcpy(buf[0..2], s);
                break :blk 2;
            },
            'a' => blk: {
                const name = day_names[@intCast(dow)];
                @memcpy(buf[0..3], name);
                break :blk 3;
            },
            'b' => blk: {
                const name = month_names[month - 1];
                @memcpy(buf[0..3], name);
                break :blk 3;
            },
            else => 0,
        };
    }

    pub fn interval(self: *DateTime) u64 {
        return self.interval_secs;
    }

    pub fn getColor(self: *DateTime) c_ulong {
        return self.color;
    }
};
