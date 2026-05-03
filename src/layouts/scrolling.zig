const std = @import("std");
const client_mod = @import("../client.zig");
const monitor_mod = @import("../monitor.zig");
const xlib = @import("../x11/xlib.zig");
const tiling = @import("tiling.zig");

const Client = client_mod.Client;
const Monitor = monitor_mod.Monitor;

pub const layout = monitor_mod.Layout{
    .symbol = "[S]",
    .arrange_fn = scroll,
};

pub fn scroll(monitor: *Monitor) void {
    scrollEx(monitor, true, false);
}

pub fn scrollEx(monitor: *Monitor, flush: bool, animating: bool) void {
    var client_count: u32 = 0;
    var current = client_mod.nextTiled(monitor.clients);
    while (current) |_| : (current = client_mod.nextTiled(current.?.next)) {
        client_count += 1;
    }

    if (client_count == 0) return;

    const gap_outer_h = if (monitor.smartgaps_enabled and client_count == 1) 0 else monitor.gap_outer_h;
    const gap_outer_v = if (monitor.smartgaps_enabled and client_count == 1) 0 else monitor.gap_outer_v;
    const gap_inner_v = monitor.gap_inner_v;

    const visible_count: u32 = @intCast(@max(1, monitor.nmaster));
    const available_width = monitor.win_w - 2 * gap_outer_v;
    const available_height = monitor.win_h - 2 * gap_outer_h;

    const total_gaps = gap_inner_v * @as(i32, @intCast(if (visible_count > 1) visible_count - 1 else 0));
    const window_width = @divTrunc(available_width - total_gaps, @as(i32, @intCast(visible_count)));

    var x_pos: i32 = monitor.win_x + gap_outer_v - monitor.scroll_offset;
    const y_pos: i32 = monitor.win_y + gap_outer_h;
    const height = available_height;
    const hide_x: i32 = monitor.win_x - 2 * monitor.win_w;

    const viewport_left = monitor.win_x + gap_outer_v;
    const viewport_right = viewport_left + available_width;

    current = client_mod.nextTiled(monitor.clients);
    while (current) |client| : (current = client_mod.nextTiled(client.next)) {
        const window_right = x_pos + window_width;
        const screen_left = viewport_left;
        const screen_right = viewport_right;
        const is_visible = window_right > screen_left and x_pos < screen_right;

        const target_x: i32 = if (is_visible) x_pos else hide_x;

        tiling.resizeClientAnim(
            client,
            target_x,
            y_pos,
            window_width - 2 * client.border_width,
            height - 2 * client.border_width,
            flush,
            animating,
        );
        x_pos += window_width + gap_inner_v;
    }
}

pub fn getScrollStep(monitor: *Monitor) i32 {
    var client_count: u32 = 0;
    var current = client_mod.nextTiled(monitor.clients);
    while (current) |_| : (current = client_mod.nextTiled(current.?.next)) {
        client_count += 1;
    }

    const gap_outer_v = if (monitor.smartgaps_enabled and client_count == 1) 0 else monitor.gap_outer_v;
    const gap_inner_v = monitor.gap_inner_v;
    const visible_count: u32 = @intCast(@max(1, monitor.nmaster));
    const available_width = monitor.win_w - 2 * gap_outer_v;
    const total_gaps = gap_inner_v * @as(i32, @intCast(if (visible_count > 1) visible_count - 1 else 0));
    const window_width = @divTrunc(available_width - total_gaps, @as(i32, @intCast(visible_count)));
    return window_width + gap_inner_v;
}

pub fn getMaxScroll(monitor: *Monitor) i32 {
    var client_count: u32 = 0;
    var current = client_mod.nextTiled(monitor.clients);
    while (current) |_| : (current = client_mod.nextTiled(current.?.next)) {
        client_count += 1;
    }

    const visible_count: u32 = @intCast(@max(1, monitor.nmaster));
    if (client_count <= visible_count) return 0;

    const scroll_step = getScrollStep(monitor);
    const scrollable = client_count - visible_count;
    return scroll_step * @as(i32, @intCast(scrollable));
}

pub fn getWindowIndex(monitor: *Monitor, target: *Client) ?u32 {
    var index: u32 = 0;
    var current = client_mod.nextTiled(monitor.clients);
    while (current) |client| : (current = client_mod.nextTiled(client.next)) {
        if (client == target) return index;
        index += 1;
    }
    return null;
}

pub fn getTargetScrollForWindow(monitor: *Monitor, target: *Client) i32 {
    const index = getWindowIndex(monitor, target) orelse return 0;

    var client_count: u32 = 0;
    var current = client_mod.nextTiled(monitor.clients);
    while (current) |_| : (current = client_mod.nextTiled(current.?.next)) {
        client_count += 1;
    }

    const visible_count: u32 = @intCast(@max(1, monitor.nmaster));
    const gap_outer_v = if (monitor.smartgaps_enabled and client_count == 1) 0 else monitor.gap_outer_v;
    const gap_inner_v = monitor.gap_inner_v;
    const available_width = monitor.win_w - 2 * gap_outer_v;

    const total_gaps = gap_inner_v * @as(i32, @intCast(if (visible_count > 1) visible_count - 1 else 0));
    const window_width = @divTrunc(available_width - total_gaps, @as(i32, @intCast(visible_count)));

    const window_x_start = @as(i32, @intCast(index)) * (window_width + gap_inner_v);
    const window_x_end = window_x_start + window_width;

    const viewport_start = monitor.scroll_offset;
    const viewport_end = viewport_start + available_width;

    if (window_x_start >= viewport_start and window_x_end <= viewport_end) {
        return monitor.scroll_offset;
    }

    const max_scroll = getMaxScroll(monitor);
    if (window_x_end > viewport_end) {
        const target_scroll = window_x_end - available_width;
        return @min(@max(0, target_scroll), max_scroll);
    } else {
        const target_scroll = window_x_start;
        return @min(@max(0, target_scroll), max_scroll);
    }
}