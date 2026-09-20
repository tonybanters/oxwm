const std = @import("std");
const client_mod = @import("../client.zig");
const monitor_mod = @import("../monitor.zig");
const tiling = @import("tiling.zig");

const Client = client_mod.Client;
const Monitor = monitor_mod.Monitor;

pub const layout = monitor_mod.Layout{
    .symbol = "[S]",
    .arrange_fn = scroll,
};

pub const Snap = struct {
    client: *Client,
    offset: i32,
    width: i32,
};

pub const Geometry = struct {
    outer_h: i32,
    outer_v: i32,
    inner: i32,
    available_w: i32,
    available_h: i32,
    count: u32,
};

pub fn tiledCount(monitor: *Monitor) u32 {
    var count: u32 = 0;
    var current = client_mod.nextTiled(monitor.clients);
    while (current) |client| : (current = client_mod.nextTiled(client.next)) {
        count += 1;
    }
    return count;
}

pub fn geometry(monitor: *Monitor) Geometry {
    const count = tiledCount(monitor);
    const smart = monitor.smartgaps_enabled and count == 1;
    const outer_h = if (smart) 0 else monitor.gap_outer_h;
    const outer_v = if (smart) 0 else monitor.gap_outer_v;
    return .{
        .outer_h = outer_h,
        .outer_v = outer_v,
        .inner = monitor.gap_inner_v,
        .available_w = monitor.win_w - 2 * outer_v,
        .available_h = monitor.win_h - 2 * outer_h,
        .count = count,
    };
}

/// Resolves a client's configured width into pixels. Values at or below
/// 1.0 are a proportion of the usable width, larger values are pixels.
pub fn windowWidth(monitor: *Monitor, client: *Client, geo: Geometry) i32 {
    const value: f32 = if (client.scroll_width > 0) client.scroll_width else monitor.scroll_default_width;
    const available: f32 = @floatFromInt(geo.available_w);
    const inner: f32 = @floatFromInt(geo.inner);
    const width: i32 = if (value > 1.0)
        @intFromFloat(value)
    else
        @intFromFloat((available + inner) * value - inner);
    return @max(1, @min(width, geo.available_w));
}

pub fn contentWidth(monitor: *Monitor) i32 {
    const geo = geometry(monitor);
    var offset: i32 = 0;
    var current = client_mod.nextTiled(monitor.clients);
    while (current) |client| : (current = client_mod.nextTiled(client.next)) {
        offset += windowWidth(monitor, client, geo) + geo.inner;
    }
    return @max(0, offset - geo.inner);
}

/// Largest offset that still keeps the right edge of the last window at
/// the right edge of the usable area.
pub fn maxScroll(monitor: *Monitor) i32 {
    const geo = geometry(monitor);
    return @max(0, contentWidth(monitor) - geo.available_w);
}

/// Returns the offset that puts `target` flush with the left edge of the
/// usable area, clamped to the scrollable range. Null when `target` is
/// not tiled.
pub fn snapFor(monitor: *Monitor, target: *Client) ?Snap {
    const geo = geometry(monitor);
    const max = maxScroll(monitor);
    var offset: i32 = 0;
    var current = client_mod.nextTiled(monitor.clients);
    while (current) |client| : (current = client_mod.nextTiled(client.next)) {
        const width = windowWidth(monitor, client, geo);
        if (client == target) return .{ .client = client, .offset = @min(offset, max), .width = width };
        offset += width + geo.inner;
    }
    return null;
}

/// Smallest change to `offset` that brings `target` fully into view.
pub fn offsetToReveal(monitor: *Monitor, offset: i32, target: *Client) i32 {
    const geo = geometry(monitor);
    const max = maxScroll(monitor);
    var left: i32 = 0;
    var current = client_mod.nextTiled(monitor.clients);
    while (current) |client| : (current = client_mod.nextTiled(client.next)) {
        const width = windowWidth(monitor, client, geo);
        if (client == target) {
            var result = offset;
            if (left < offset) {
                result = left;
            } else if (left + width > offset + geo.available_w) {
                result = left + width - geo.available_w;
            }
            return @max(0, @min(result, max));
        }
        left += width + geo.inner;
    }
    return @max(0, @min(offset, max));
}

/// The snap point whose offset is closest to `position`.
pub fn nearestSnap(monitor: *Monitor, position: f64) ?Snap {
    const geo = geometry(monitor);
    const max = maxScroll(monitor);
    var best: ?Snap = null;
    var best_dist: f64 = std.math.inf(f64);
    var offset: i32 = 0;
    var current = client_mod.nextTiled(monitor.clients);
    while (current) |client| : (current = client_mod.nextTiled(client.next)) {
        const width = windowWidth(monitor, client, geo);
        const snap_offset = @min(offset, max);
        const dist = @abs(@as(f64, @floatFromInt(snap_offset)) - position);
        if (dist < best_dist) {
            best_dist = dist;
            best = .{ .client = client, .offset = snap_offset, .width = width };
        }
        offset += width + geo.inner;
    }
    return best;
}

/// The first snap point strictly after (direction > 0) or before
/// (direction < 0) `position`.
pub fn adjacentSnap(monitor: *Monitor, position: i32, direction: i32) ?Snap {
    const geo = geometry(monitor);
    const max = maxScroll(monitor);
    var result: ?Snap = null;
    var offset: i32 = 0;
    var current = client_mod.nextTiled(monitor.clients);
    while (current) |client| : (current = client_mod.nextTiled(client.next)) {
        const width = windowWidth(monitor, client, geo);
        const snap_offset = @min(offset, max);
        const snap = Snap{ .client = client, .offset = snap_offset, .width = width };
        if (direction > 0) {
            if (snap_offset > position) return snap;
        } else if (snap_offset < position) {
            result = snap;
        }
        offset += width + geo.inner;
    }
    return result;
}

pub fn scroll(monitor: *Monitor) void {
    const geo = geometry(monitor);
    if (geo.count == 0) return;

    var x_pos: i32 = monitor.win_x + geo.outer_v - monitor.scroll_offset;
    const y_pos: i32 = monitor.win_y + geo.outer_h;
    const screen_left = monitor.win_x;
    const screen_right = monitor.win_x + monitor.win_w;

    var current = client_mod.nextTiled(monitor.clients);
    while (current) |client| : (current = client_mod.nextTiled(client.next)) {
        const width = windowWidth(monitor, client, geo);
        const border = 2 * client.border_width;
        const is_visible = x_pos + width > screen_left and x_pos < screen_right;

        if (is_visible) {
            tiling.resize(client, x_pos, y_pos, width - border, geo.available_h - border, false);
        } else {
            tiling.resizeClient(client, -2 * (width + border), y_pos, width - border, geo.available_h - border);
        }
        x_pos += width + geo.inner;
    }
}
