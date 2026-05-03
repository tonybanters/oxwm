const std = @import("std");
const client_mod = @import("../client.zig");
const monitor_mod = @import("../monitor.zig");
const xlib = @import("../x11/xlib.zig");

const Client = client_mod.Client;
const Monitor = monitor_mod.Monitor;

pub const layout = monitor_mod.Layout{
    .symbol = "[]=",
    .arrange_fn = tile,
};

pub var display_handle: ?*xlib.Display = null;
pub var screen_width: i32 = 0;
pub var screen_height: i32 = 0;
pub var bar_height: i32 = 0;

pub fn setDisplay(display: *xlib.Display) void {
    display_handle = display;
}

pub fn setScreenSize(width: i32, height: i32) void {
    screen_width = width;
    screen_height = height;
}

pub fn setBarHeight(height: i32) void {
    bar_height = height;
}

pub fn tile(monitor: *Monitor) void {
    var gap_outer_h: i32 = 0;
    var gap_outer_v: i32 = 0;
    var gap_inner_h: i32 = 0;
    var gap_inner_v: i32 = 0;
    var client_count: u32 = 0;

    getGaps(monitor, &gap_outer_h, &gap_outer_v, &gap_inner_h, &gap_inner_v, &client_count);
    if (client_count == 0) return;

    const nmaster: i32 = monitor.nmaster;
    const nmaster_count: u32 = @intCast(@max(0, nmaster));

    const master_x: i32 = monitor.win_x + gap_outer_v;
    var master_y: i32 = monitor.win_y + gap_outer_h;
    const master_height: i32 = monitor.win_h - 2 * gap_outer_h - gap_inner_h * (@as(i32, @intCast(@min(client_count, nmaster_count))) - 1);
    var master_width: i32 = monitor.win_w - 2 * gap_outer_v;

    var stack_x: i32 = master_x;
    var stack_y: i32 = monitor.win_y + gap_outer_h;
    const stack_height: i32 = monitor.win_h - 2 * gap_outer_h - gap_inner_h * (@as(i32, @intCast(client_count)) - nmaster - 1);
    var stack_width: i32 = master_width;

    if (nmaster > 0 and client_count > nmaster_count) {
        stack_width = @intFromFloat(@as(f32, @floatFromInt(master_width - gap_inner_v)) * (1.0 - monitor.mfact));
        master_width = master_width - gap_inner_v - stack_width;
        stack_x = master_x + master_width + gap_inner_v;
    }

    var master_facts: f32 = 0;
    var stack_facts: f32 = 0;
    var master_rest: i32 = 0;
    var stack_rest: i32 = 0;
    getFacts(monitor, master_height, stack_height, &master_facts, &stack_facts, &master_rest, &stack_rest);

    var index: u32 = 0;
    var current = client_mod.nextTiled(monitor.clients);
    while (current) |client| : (current = client_mod.nextTiled(client.next)) {
        if (index < nmaster_count) {
            const height = @as(i32, @intFromFloat(@as(f32, @floatFromInt(master_height)) / master_facts)) + (if (index < @as(u32, @intCast(master_rest))) @as(i32, 1) else @as(i32, 0)) - 2 * client.border_width;
            resize(client, master_x, master_y, master_width - 2 * client.border_width, height, false);
            master_y += getClientHeight(client) + gap_inner_h;
        } else {
            const stack_index = index - nmaster_count;
            const height = @as(i32, @intFromFloat(@as(f32, @floatFromInt(stack_height)) / stack_facts)) + (if (stack_index < @as(u32, @intCast(stack_rest))) @as(i32, 1) else @as(i32, 0)) - 2 * client.border_width;
            resize(client, stack_x, stack_y, stack_width - 2 * client.border_width, height, false);
            stack_y += getClientHeight(client) + gap_inner_h;
        }
        index += 1;
    }
}

fn getGaps(monitor: *Monitor, gap_outer_h: *i32, gap_outer_v: *i32, gap_inner_h: *i32, gap_inner_v: *i32, client_count: *u32) void {
    var count: u32 = 0;
    var current = client_mod.nextTiled(monitor.clients);
    while (current) |client| : (current = client_mod.nextTiled(client.next)) {
        count += 1;
    }

    if (monitor.smartgaps_enabled and count == 1) {
        gap_outer_h.* = 0;
        gap_outer_v.* = 0;
    } else {
        gap_outer_h.* = monitor.gap_outer_h;
        gap_outer_v.* = monitor.gap_outer_v;
    }

    gap_inner_h.* = monitor.gap_inner_h;
    gap_inner_v.* = monitor.gap_inner_v;
    client_count.* = count;
}

fn getFacts(monitor: *Monitor, master_size: i32, stack_size: i32, master_factor: *f32, stack_factor: *f32, master_rest: *i32, stack_rest: *i32) void {
    var count: u32 = 0;
    var current = client_mod.nextTiled(monitor.clients);
    while (current) |client| : (current = client_mod.nextTiled(client.next)) {
        count += 1;
    }

    const nmaster_count: u32 = @intCast(@max(0, monitor.nmaster));
    const master_facts: f32 = @floatFromInt(@min(count, nmaster_count));
    const stack_facts: f32 = @floatFromInt(if (count > nmaster_count) count - nmaster_count else 0);

    var master_total: i32 = 0;
    var stack_total: i32 = 0;

    if (master_facts > 0) {
        master_total = @as(i32, @intFromFloat(@as(f32, @floatFromInt(master_size)) / master_facts)) * @as(i32, @intFromFloat(master_facts));
    }
    if (stack_facts > 0) {
        stack_total = @as(i32, @intFromFloat(@as(f32, @floatFromInt(stack_size)) / stack_facts)) * @as(i32, @intFromFloat(stack_facts));
    }

    master_factor.* = master_facts;
    stack_factor.* = stack_facts;
    master_rest.* = master_size - master_total;
    stack_rest.* = stack_size - stack_total;
}

fn getClientWidth(client: *Client) i32 {
    return client.width + 2 * client.border_width;
}

fn getClientHeight(client: *Client) i32 {
    return client.height + 2 * client.border_width;
}

pub fn applySizeHints(client: *Client, target_x: *i32, target_y: *i32, target_width: *i32, target_height: *i32, interact: bool) bool {
    const monitor = client.monitor orelse return false;

    target_width.* = @max(1, target_width.*);
    target_height.* = @max(1, target_height.*);

    if (interact) {
        if (target_x.* > screen_width) {
            target_x.* = screen_width - getClientWidth(client);
        }
        if (target_y.* > screen_height) {
            target_y.* = screen_height - getClientHeight(client);
        }
        if (target_x.* + target_width.* + 2 * client.border_width < 0) {
            target_x.* = 0;
        }
        if (target_y.* + target_height.* + 2 * client.border_width < 0) {
            target_y.* = 0;
        }
    } else {
        if (target_x.* >= monitor.win_x + monitor.win_w) {
            target_x.* = monitor.win_x + monitor.win_w - getClientWidth(client);
        }
        if (target_y.* >= monitor.win_y + monitor.win_h) {
            target_y.* = monitor.win_y + monitor.win_h - getClientHeight(client);
        }
        if (target_x.* + target_width.* + 2 * client.border_width <= monitor.win_x) {
            target_x.* = monitor.win_x;
        }
        if (target_y.* + target_height.* + 2 * client.border_width <= monitor.win_y) {
            target_y.* = monitor.win_y;
        }
    }

    if (target_height.* < bar_height) {
        target_height.* = bar_height;
    }
    if (target_width.* < bar_height) {
        target_width.* = bar_height;
    }

    if (client.is_floating or monitor.lt[monitor.sel_lt] == null) {
        const base_is_min = client.base_width == client.min_width and client.base_height == client.min_height;

        var adjusted_width = target_width.*;
        var adjusted_height = target_height.*;

        if (!base_is_min) {
            adjusted_width -= client.base_width;
            adjusted_height -= client.base_height;
        }

        if (client.min_aspect > 0 and client.max_aspect > 0) {
            const width_float: f32 = @floatFromInt(adjusted_width);
            const height_float: f32 = @floatFromInt(adjusted_height);
            if (client.max_aspect < width_float / height_float) {
                adjusted_width = @intFromFloat(height_float * client.max_aspect + 0.5);
            } else if (client.min_aspect < height_float / width_float) {
                adjusted_height = @intFromFloat(width_float * client.min_aspect + 0.5);
            }
        }

        if (base_is_min) {
            adjusted_width -= client.base_width;
            adjusted_height -= client.base_height;
        }

        if (client.increment_width > 0) {
            adjusted_width -= @mod(adjusted_width, client.increment_width);
        }
        if (client.increment_height > 0) {
            adjusted_height -= @mod(adjusted_height, client.increment_height);
        }

        target_width.* = @max(adjusted_width + client.base_width, client.min_width);
        target_height.* = @max(adjusted_height + client.base_height, client.min_height);

        if (client.max_width > 0) {
            target_width.* = @min(target_width.*, client.max_width);
        }
        if (client.max_height > 0) {
            target_height.* = @min(target_height.*, client.max_height);
        }
    }

    return target_x.* != client.x or target_y.* != client.y or target_width.* != client.width or target_height.* != client.height;
}

pub fn resize(client: *Client, target_x: i32, target_y: i32, target_width: i32, target_height: i32, interact: bool) void {
    var final_x = target_x;
    var final_y = target_y;
    var final_width = target_width;
    var final_height = target_height;

    if (applySizeHints(client, &final_x, &final_y, &final_width, &final_height, interact)) {
        resizeClient(client, final_x, final_y, final_width, final_height);
    }
}

pub fn resizeClient(client: *Client, target_x: i32, target_y: i32, target_width: i32, target_height: i32) void {
    client.old_x = client.x;
    client.old_y = client.y;
    client.old_width = client.width;
    client.old_height = client.height;
    client.x = target_x;
    client.y = target_y;
    client.width = target_width;
    client.height = target_height;

    const display = display_handle orelse return;

    var window_changes: xlib.c.XWindowChanges = undefined;
    window_changes.x = target_x;
    window_changes.y = target_y;
    window_changes.width = @intCast(@max(1, target_width));
    window_changes.height = @intCast(@max(1, target_height));
    window_changes.border_width = client.border_width;

    _ = xlib.c.XConfigureWindow(
        display,
        client.window,
        xlib.c.CWX | xlib.c.CWY | xlib.c.CWWidth | xlib.c.CWHeight | xlib.c.CWBorderWidth,
        &window_changes,
    );

    sendConfigure(client);
    _ = xlib.XFlush(display);
}

pub fn resizeClientAnim(client: *Client, target_x: i32, target_y: i32, target_width: i32, target_height: i32, flush: bool, animating: bool) void {
    if (animating and client.x == target_x and client.y == target_y) return;

    client.old_x = client.x;
    client.old_y = client.y;
    client.old_width = client.width;
    client.old_height = client.height;
    client.x = target_x;
    client.y = target_y;
    client.width = target_width;
    client.height = target_height;

    const display = display_handle orelse return;

    if (animating) {
        _ = xlib.XMoveWindow(display, client.window, target_x, target_y);
    } else {
        var window_changes: xlib.c.XWindowChanges = undefined;
        window_changes.x = target_x;
        window_changes.y = target_y;
        window_changes.width = @intCast(@max(1, target_width));
        window_changes.height = @intCast(@max(1, target_height));
        window_changes.border_width = client.border_width;

        _ = xlib.c.XConfigureWindow(
            display,
            client.window,
            xlib.c.CWX | xlib.c.CWY | xlib.c.CWWidth | xlib.c.CWHeight | xlib.c.CWBorderWidth,
            &window_changes,
        );

        sendConfigure(client);
    }
    if (flush) {
        _ = xlib.XFlush(display);
    }
}

pub fn sendConfigure(client: *Client) void {
    const display = display_handle orelse return;

    var configure_event: xlib.c.XConfigureEvent = undefined;
    configure_event.type = xlib.c.ConfigureNotify;
    configure_event.display = display;
    configure_event.event = client.window;
    configure_event.window = client.window;
    configure_event.x = client.x;
    configure_event.y = client.y;
    configure_event.width = client.width;
    configure_event.height = client.height;
    configure_event.border_width = client.border_width;
    configure_event.above = xlib.None;
    configure_event.override_redirect = xlib.False;

    _ = xlib.c.XSendEvent(display, client.window, xlib.False, xlib.StructureNotifyMask, @ptrCast(&configure_event));
}
