const std = @import("std");
const format_util = @import("format.zig");

pub const Shell = struct {
    format: []const u8,
    command: []const u8,
    interval_secs: u64,
    color: c_ulong,
    child: ?*std.process.Child = null,
    child_buffer: [4096]u8 = undefined,
    child_buffer_len: usize = 0,
    pending: bool = false,

    pub fn init(format: []const u8, command: []const u8, interval_secs: u64, col: c_ulong) Shell {
        return .{
            .format = format,
            .command = command,
            .interval_secs = interval_secs,
            .color = col,
        };
    }

    pub fn content(self: *Shell, buffer: []u8) []const u8 {
        if (self.pending) {
            self.pollChild();
            if (!self.pending) {
                var output: [256]u8 = undefined;
                var cmd_len = @min(self.child_buffer_len, output.len);
                @memcpy(output[0..cmd_len], self.child_buffer[0..cmd_len]);

                while (cmd_len > 0 and (output[cmd_len - 1] == '\n' or output[cmd_len - 1] == '\r')) {
                    cmd_len -= 1;
                }

                return format_util.substitute(self.format, output[0..cmd_len], buffer);
            }
            return buffer[0..0];
        }

        self.spawnChild();
        return buffer[0..0];
    }

    pub fn interval(self: *Shell) u64 {
        return self.interval_secs;
    }

    pub fn getColor(self: *Shell) c_ulong {
        return self.color;
    }

    fn spawnChild(self: *Shell) void {
        const allocator = std.heap.page_allocator;
        var child = std.process.Child.init(&.{ "/bin/sh", "-c", self.command }, allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;

        child.spawn() catch return;

        const child_ptr = allocator.create(std.process.Child) catch {
            _ = child.kill() catch {};
            _ = child.wait() catch {};
            return;
        };
        child_ptr.* = child;
        self.child = child_ptr;
        self.child_buffer_len = 0;
        self.pending = true;

        self.pollChild();
    }

    fn pollChild(self: *Shell) void {
        const child_ptr = self.child orelse return;

        var buf: [4096]u8 = undefined;
        while (true) {
            const n = child_ptr.stdout.?.read(&buf) catch {
                self.reapChild();
                return;
            };
            if (n == 0) {
                self.pending = false;
                self.reapChild();
                return;
            }
            const remaining = self.child_buffer.len - self.child_buffer_len;
            const to_copy = @min(n, remaining);
            @memcpy(self.child_buffer[self.child_buffer_len .. self.child_buffer_len + to_copy], buf[0..to_copy]);
            self.child_buffer_len += to_copy;
        }
    }

    fn reapChild(self: *Shell) void {
        const child_ptr = self.child orelse return;
        _ = child_ptr.wait() catch {};
        std.heap.page_allocator.destroy(child_ptr);
        self.child = null;
    }
};