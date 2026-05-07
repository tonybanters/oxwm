const std = @import("std");
const format_util = @import("format.zig");

pub const Shell = struct {
    format: []const u8,
    command: []const u8,
    interval_secs: u64,
    color: c_ulong,
    bg: c_ulong,

    pub fn init(format: []const u8, command: []const u8, interval_secs: u64, col: c_ulong, background: c_ulong) Shell {
        return .{
            .format = format,
            .command = command,
            .interval_secs = interval_secs,
            .color = col,
            .bg = background,
        };
    }

    pub fn content(self: *Shell, buffer: []u8) []const u8 {
        var cmd_output: [256]u8 = undefined;
        const result = std.process.Child.run(.{
            .allocator = std.heap.page_allocator,
            .argv = &.{ "/bin/sh", "-c", self.command },
        }) catch return buffer[0..0];
        defer std.heap.page_allocator.free(result.stdout);
        defer std.heap.page_allocator.free(result.stderr);

        var cmd_len = @min(result.stdout.len, cmd_output.len);
        @memcpy(cmd_output[0..cmd_len], result.stdout[0..cmd_len]);

        while (cmd_len > 0 and (cmd_output[cmd_len - 1] == '\n' or cmd_output[cmd_len - 1] == '\r')) {
            cmd_len -= 1;
        }

        return format_util.substitute(self.format, cmd_output[0..cmd_len], buffer);
    }

    pub fn interval(self: *Shell) u64 {
        return self.interval_secs;
    }

    pub fn getColor(self: *Shell) c_ulong {
        return self.color;
    }
};
