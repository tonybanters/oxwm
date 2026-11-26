const std = @import("std");

pub const Static = struct {
    text: []const u8,
    color: c_ulong,
    bg: c_ulong,

    pub fn init(text: []const u8, color: c_ulong, background: c_ulong) Static {
        return .{ .text = text, .color = color, .bg = background };
    }

    pub fn content(self: *Static, buffer: []u8) []const u8 {
        const len = @min(self.text.len, buffer.len);
        @memcpy(buffer[0..len], self.text[0..len]);
        return buffer[0..len];
    }

    pub fn interval(_: *Static) u64 {
        return 0;
    }

    pub fn getColor(self: *Static) c_ulong {
        return self.color;
    }
};
