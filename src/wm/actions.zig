const std = @import("std");

const client_mod = @import("../client.zig");
const config_mod = @import("../config/config.zig");
const lua = @import("../config/lua.zig");
const core = @import("core.zig");
const tiling = @import("../layouts/tiling.zig");
const monitor_mod = @import("../monitor.zig");
const bar_mod = @import("../bar/bar.zig");
const wm_mod = @import("wm.zig");
const xlib = @import("../x11/xlib.zig");

const Client = client_mod.Client;
const Monitor = monitor_mod.Monitor;
const WindowManager = wm_mod.WindowManager;

const snap_distance: i32 = 32;

// execvpeZ removed in zig 0.16 std lib rework (codeberg.org/ziglang/zig/issues/31694) with no replacement
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

pub fn spawnChildSetup(wm: *WindowManager) void {
    _ = std.c.setsid();
    if (wm.x11_fd >= 0) _ = std.c.close(@intCast(wm.x11_fd));
    const sigchld_handler = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = std.mem.zeroes(std.posix.sigset_t),
        .flags = 0,
    };
    std.posix.sigaction(.CHLD, &sigchld_handler, null);
}

pub fn spawnCommand(wm: *WindowManager, cmd: []const u8) void {
    std.debug.print("running cmd: {s}\n", .{cmd});
    const pid = std.c.fork();
    if (pid < 0) return;
    if (pid == 0) {
        const grandchild = std.c.fork();
        if (grandchild < 0) std.c._exit(1);
        if (grandchild != 0) std.c._exit(0);
        spawnChildSetup(wm);
        var cmd_buf: [1024]u8 = undefined;
        if (cmd.len >= cmd_buf.len) std.c._exit(1);
        @memcpy(cmd_buf[0..cmd.len], cmd);
        cmd_buf[cmd.len] = 0;
        const argv = [_:null]?[*:0]const u8{ "sh", "-c", @ptrCast(&cmd_buf) };
        _ = execvp("sh", &argv);
        std.c._exit(1);
    }
    _ = std.c.waitpid(pid, null, 0);
}

pub fn spawnTerminal(wm: *WindowManager) void {
    const pid = std.c.fork();
    if (pid < 0) return;
    if (pid == 0) {
        const grandchild = std.c.fork();
        if (grandchild < 0) std.c._exit(1);
        if (grandchild != 0) std.c._exit(0);
        spawnChildSetup(wm);
        var term_buf: [256]u8 = undefined;
        const terminal = wm.config.terminal;
        if (terminal.len >= term_buf.len) std.c._exit(1);
        @memcpy(term_buf[0..terminal.len], terminal);
        term_buf[terminal.len] = 0;
        const term_ptr: [*:0]const u8 = @ptrCast(&term_buf);
        const argv = [_:null]?[*:0]const u8{term_ptr};
        _ = execvp(term_ptr, &argv);
        std.c._exit(1);
    }
    _ = std.c.waitpid(pid, null, 0);
}

pub fn movestack(direction: i32, wm: *WindowManager) void {
    if (direction == 0) return;
    const monitor = wm.selected_monitor orelse return;
    const current = monitor.sel orelse return;

    if (current.is_floating) {
        return;
    }

    var target: ?*Client = null;

    if (direction > 0) {
        target = current.next;
        while (target) |client| {
            if (client_mod.isVisible(client) and !client.is_floating) {
                break;
            }
            target = client.next;
        }
        if (target == null) {
            target = monitor.clients;
            while (target) |client| {
                if (client == current) {
                    break;
                }
                if (client_mod.isVisible(client) and !client.is_floating) {
                    break;
                }
                target = client.next;
            }
        }
    } else {
        var prev: ?*Client = null;
        var iter = monitor.clients;
        while (iter) |client| {
            if (client == current) {
                break;
            }
            if (client_mod.isVisible(client) and !client.is_floating) {
                prev = client;
            }
            iter = client.next;
        }
        if (prev == null) {
            iter = current.next;
            while (iter) |client| {
                if (client_mod.isVisible(client) and !client.is_floating) {
                    prev = client;
                }
                iter = client.next;
            }
        }
        target = prev;
    }

    if (target) |swap_client| {
        if (swap_client != current) {
            client_mod.swapClients(current, swap_client);
            core.arrange(monitor, wm);
            core.focus(current, wm);
        }
    }
}

pub fn toggleView(tag_mask: u32, wm: *WindowManager) void {
    const monitor = wm.selected_monitor orelse return;
    const new_tags = monitor.tagset[monitor.sel_tags] ^ tag_mask;
    if (new_tags != 0) {
        monitor.tagset[monitor.sel_tags] = new_tags;

        if (new_tags == ~@as(u32, 0)) {
            monitor.pertag.prevtag = monitor.pertag.curtag;
            monitor.pertag.curtag = 0;
        }

        if ((new_tags & (@as(u32, 1) << @intCast(monitor.pertag.curtag -| 1))) == 0) {
            monitor.pertag.prevtag = monitor.pertag.curtag;
            var i: u32 = 0;
            while (i < wm.config.tag_count) : (i += 1) {
                if ((new_tags & (@as(u32, 1) << @intCast(i))) != 0) break;
            }
            monitor.pertag.curtag = i + 1;
        }

        monitor.nmaster = monitor.pertag.nmasters[monitor.pertag.curtag];
        monitor.mfact = monitor.pertag.mfacts[monitor.pertag.curtag];
        monitor.sel_lt = monitor.pertag.sellts[monitor.pertag.curtag];

        const new_show_bar = monitor.pertag.showbars[monitor.pertag.curtag];
        if (new_show_bar != monitor.show_bar) {
            monitor.show_bar = new_show_bar;
            updateBarVisibility(monitor, wm);
        }

        core.focusTopClient(monitor, wm);
        core.arrange(monitor, wm);
        wm.invalidateBars();
    }
}

pub fn toggleClientTag(tag_mask: u32, wm: *WindowManager) void {
    const monitor = wm.selected_monitor orelse return;
    const client = monitor.sel orelse return;
    const new_tags = client.tags ^ tag_mask;
    if (new_tags != 0) {
        client.tags = new_tags;
        core.focusTopClient(monitor, wm);
        core.arrange(monitor, wm);
        wm.invalidateBars();
    }
}

pub fn toggleGaps(wm: *WindowManager) void {
    const monitor = wm.selected_monitor orelse return;
    if (monitor.gap_inner_h == 0) {
        monitor.gap_inner_h = wm.config.gap_inner_h;
        monitor.gap_inner_v = wm.config.gap_inner_v;
        monitor.gap_outer_h = wm.config.gap_outer_h;
        monitor.gap_outer_v = wm.config.gap_outer_v;
    } else {
        monitor.gap_inner_h = 0;
        monitor.gap_inner_v = 0;
        monitor.gap_outer_h = 0;
        monitor.gap_outer_v = 0;
    }
    core.arrange(monitor, wm);
}

pub fn updateBarVisibility(monitor: *Monitor, wm: *WindowManager) void {
    const bar = bar_mod.windowToBar(wm.bars, monitor.bar_win) orelse return;

    if (monitor.show_bar) {
        _ = xlib.XMapWindow(wm.display.handle, bar.window);
        monitor.win_h -= bar.height;
        if (std.mem.eql(u8, wm.config.bar_position, "top")) {
            monitor.win_y += bar.height;
        }
    } else {
        _ = xlib.XUnmapWindow(wm.display.handle, bar.window);
        monitor.win_h += bar.height;
        if (std.mem.eql(u8, wm.config.bar_position, "top")) {
            monitor.win_y -= bar.height;
        }
    }
}

pub fn toggleBar(wm: *WindowManager) void {
    const monitor = wm.selected_monitor orelse return;
    monitor.show_bar = !monitor.show_bar;
    monitor.pertag.showbars[monitor.pertag.curtag] = monitor.show_bar;

    updateBarVisibility(monitor, wm);

    core.arrange(monitor, wm);
    wm.invalidateBars();
}

pub fn killFocused(wm: *WindowManager) void {
    const selected = wm.selected_monitor orelse return;
    const client = selected.sel orelse return;
    std.debug.print("killing window: 0x{x}\n", .{client.window});

    if (!core.sendEvent(client, wm.atoms.wm_delete, wm)) {
        _ = xlib.XGrabServer(wm.display.handle);
        _ = xlib.XKillClient(wm.display.handle, client.window);
        _ = xlib.XSync(wm.display.handle, xlib.False);
        _ = xlib.XUngrabServer(wm.display.handle);
    }
}

pub fn toggleFullscreen(wm: *WindowManager) void {
    const selected = wm.selected_monitor orelse return;
    const client = selected.sel orelse return;
    core.setFullscreen(client, !client.is_fullscreen, wm);
}

pub fn viewAdjacentTag(direction: i32, wm: *WindowManager) void {
    const monitor = wm.selected_monitor orelse return;
    const current_tag = monitor.pertag.curtag;
    const max_tag: i32 = @intCast(wm.config.tag_count);
    var new_tag: i32 = @intCast(current_tag);

    new_tag += direction;
    if (new_tag < 1) new_tag = max_tag;
    if (new_tag > max_tag) new_tag = 1;

    const tag_mask: u32 = @as(u32, 1) << @intCast(new_tag - 1);
    core.view(tag_mask, wm);
}

pub fn viewAdjacentNonemptyTag(direction: i32, wm: *WindowManager) void {
    const monitor = wm.selected_monitor orelse return;
    const current_tag = monitor.pertag.curtag;
    const max_tag: i32 = @intCast(wm.config.tag_count);
    var new_tag: i32 = @intCast(current_tag);

    var attempts: i32 = 0;
    while (attempts < max_tag) : (attempts += 1) {
        new_tag += direction;
        if (new_tag < 1) new_tag = max_tag;
        if (new_tag > max_tag) new_tag = 1;

        const tag_mask: u32 = @as(u32, 1) << @intCast(new_tag - 1);
        if (core.hasClientsOnTag(monitor, tag_mask)) {
            core.view(tag_mask, wm);
            return;
        }
    }
}

pub fn tagClient(tag_mask: u32, wm: *WindowManager) void {
    const monitor = wm.selected_monitor orelse return;
    const client = monitor.sel orelse return;
    if (tag_mask == 0) {
        return;
    }
    client.tags = tag_mask;
    core.focusTopClient(monitor, wm);
    core.arrange(monitor, wm);
    wm.invalidateBars();
    std.debug.print("tag_client: window=0x{x} tag_mask={d}\n", .{ client.window, tag_mask });
}

pub fn focusstack(direction: i32, wm: *WindowManager) void {
    if (direction == 0) return;
    const monitor = wm.selected_monitor orelse return;
    const current = monitor.sel orelse return;

    var next_client: ?*Client = null;

    if (direction > 0) {
        next_client = current.next;
        while (next_client) |client| {
            if (client_mod.isVisible(client)) {
                break;
            }
            next_client = client.next;
        }
        if (next_client == null) {
            next_client = monitor.clients;
            while (next_client) |client| {
                if (client_mod.isVisible(client)) {
                    break;
                }
                next_client = client.next;
            }
        }
    } else {
        var prev: ?*Client = null;
        var iter = monitor.clients;
        while (iter) |client| {
            if (client == current) {
                break;
            }
            if (client_mod.isVisible(client)) {
                prev = client;
            }
            iter = client.next;
        }
        if (prev == null) {
            iter = current.next;
            while (iter) |client| {
                if (client_mod.isVisible(client)) {
                    prev = client;
                }
                iter = client.next;
            }
        }
        next_client = prev;
    }

    if (next_client) |client| {
        core.focus(client, wm);
        if (client.monitor) |client_monitor| {
            core.restack(client_monitor, wm);
        }
    }
}

/// Direction encoding: 0=up, 1=down, 2=left, 3=right
pub fn focusDirection(direction: i32, wm: *WindowManager) void {
    const monitor = wm.selected_monitor orelse return;
    const current = monitor.sel orelse return;

    const cur_cx = current.x + @divTrunc(current.width, 2);
    const cur_cy = current.y + @divTrunc(current.height, 2);

    var best: ?*Client = null;
    var best_dist: i64 = std.math.maxInt(i64);

    var iter = monitor.clients;
    while (iter) |client| : (iter = client.next) {
        if (client == current or !client_mod.isVisible(client)) continue;

        const cx = client.x + @divTrunc(client.width, 2);
        const cy = client.y + @divTrunc(client.height, 2);

        const dx: i64 = @as(i64, cx) - @as(i64, cur_cx);
        const dy: i64 = @as(i64, cy) - @as(i64, cur_cy);

        // Check if the candidate is in the correct direction
        const in_direction = switch (direction) {
            0 => dy < 0, // up
            1 => dy > 0, // down
            2 => dx < 0, // left
            3 => dx > 0, // right
            else => false,
        };
        if (!in_direction) continue;

        // Distance metric: use squared euclidean distance, but weight the
        // perpendicular axis more heavily so we prefer windows that are
        // closely aligned with the movement direction.
        const dist = switch (direction) {
            0, 1 => dy * dy + dx * dx * 4, // vertical: penalize horizontal offset
            2, 3 => dx * dx + dy * dy * 4, // horizontal: penalize vertical offset
            else => unreachable,
        };

        if (dist < best_dist) {
            best_dist = dist;
            best = client;
        }
    }

    if (best) |client| {
        core.focus(client, wm);
        if (client.monitor) |client_monitor| {
            core.restack(client_monitor, wm);
        }
    }
}

pub fn toggleFloating(wm: *WindowManager) void {
    const monitor = wm.selected_monitor orelse return;
    const client = monitor.sel orelse return;

    if (client.is_fullscreen) {
        return;
    }

    client.is_floating = !client.is_floating;

    if (client.is_floating) {
        tiling.resize(client, client.x, client.y, client.width, client.height, false);
    }

    core.arrange(monitor, wm);
    std.debug.print("toggle_floating: window=0x{x} floating={}\n", .{ client.window, client.is_floating });
}

pub fn incnmaster(delta: i32, wm: *WindowManager) void {
    const monitor = wm.selected_monitor orelse return;
    const new_val = @max(0, monitor.nmaster + delta);
    monitor.nmaster = new_val;
    monitor.pertag.nmasters[monitor.pertag.curtag] = new_val;
    core.arrange(monitor, wm);
    std.debug.print("incnmaster: nmaster={d}\n", .{monitor.nmaster});
}

pub fn setmfact(delta: f32, wm: *WindowManager) void {
    const monitor = wm.selected_monitor orelse return;
    const new_mfact = monitor.mfact + delta;
    if (new_mfact < 0.05 or new_mfact > 0.95) {
        return;
    }
    monitor.mfact = new_mfact;
    monitor.pertag.mfacts[monitor.pertag.curtag] = new_mfact;
    core.arrange(monitor, wm);
    std.debug.print("setmfact: mfact={d:.2}\n", .{monitor.mfact});
}

pub fn cycleLayout(wm: *WindowManager) void {
    const monitor = wm.selected_monitor orelse return;
    const new_lt = (monitor.sel_lt + 1) % @as(u32, @intCast(std.meta.fields(config_mod.Layouts).len));
    monitor.sel_lt = new_lt;
    monitor.pertag.sellts[monitor.pertag.curtag] = new_lt;
    if (new_lt != @intFromEnum(config_mod.Layouts.scrolling)) {
        monitor.scroll_offset = 0;
    }
    core.arrange(monitor, wm);
    wm.invalidateBars();
    if (monitor.lt[@as(usize, monitor.sel_lt)]) |layout| {
        std.debug.print("cycle_layout: {s}\n", .{layout.symbol});
    }
}

pub fn setLayout(layout_name: ?[]const u8, wm: *WindowManager) void {
    const monitor = wm.selected_monitor orelse return;
    const name = layout_name orelse return;
    const new_lt: u32 = if (config_mod.Layouts.fromString(name)) |value|
        @intFromEnum(value)
    else {
        std.debug.print("set_layout: unknown layout '{s}'\n", .{name});
        return;
    };
    monitor.sel_lt = new_lt;
    monitor.pertag.sellts[monitor.pertag.curtag] = new_lt;
    if (new_lt != @intFromEnum(config_mod.Layouts.scrolling)) {
        monitor.scroll_offset = 0;
    }
    core.arrange(monitor, wm);
    wm.invalidateBars();
    if (monitor.lt[@as(usize, monitor.sel_lt)]) |layout| {
        std.debug.print("set_layout: {s}\n", .{layout.symbol});
    }
}

pub fn setLayoutIndex(index: u32, wm: *WindowManager) void {
    const monitor = wm.selected_monitor orelse return;
    const lt_index = index % @as(u32, @intCast(std.meta.fields(config_mod.Layouts).len));
    monitor.sel_lt = lt_index;
    monitor.pertag.sellts[monitor.pertag.curtag] = lt_index;
    if (lt_index != @intFromEnum(config_mod.Layouts.scrolling)) {
        monitor.scroll_offset = 0;
    }
    core.arrange(monitor, wm);
    wm.invalidateBars();
    if (monitor.lt[@as(usize, monitor.sel_lt)]) |layout| {
        std.debug.print("set_layout_index: {s}\n", .{layout.symbol});
    }
}

fn warpCursorToMonitor(monitor: *Monitor, wm: *WindowManager) void {
    const center_x = monitor.win_x + @divTrunc(monitor.win_w, 2);
    const center_y = monitor.win_y + @divTrunc(monitor.win_h, 2);
    _ = xlib.XWarpPointer(wm.display.handle, xlib.None, wm.display.root, 0, 0, 0, 0, center_x, center_y);
}

pub fn focusmon(direction: i32, wm: *WindowManager) void {
    const selmon = wm.selected_monitor orelse return;
    const target = monitor_mod.dirToMonitor(wm, direction) orelse return;
    if (target == selmon) {
        return;
    }
    core.unfocusClient(selmon.sel, false, wm);
    wm.selected_monitor = target;
    core.focus(null, wm);
    if (wm.config.warp_cursor_to_monitor) {
        warpCursorToMonitor(target, wm);
    }
    std.debug.print("focusmon: monitor {d}\n", .{target.num});
}

pub fn sendmon(direction: i32, wm: *WindowManager) void {
    const source_monitor = wm.selected_monitor orelse return;
    const client = source_monitor.sel orelse return;
    const target = monitor_mod.dirToMonitor(wm, direction) orelse return;

    if (target == source_monitor) {
        return;
    }

    client_mod.detach(client);
    client_mod.detachStack(client);
    client.monitor = target;
    client.tags = target.tagset[target.sel_tags];
    client_mod.attachAside(client);
    client_mod.attachStack(client);

    core.focusTopClient(source_monitor, wm);
    core.arrange(source_monitor, wm);
    core.arrange(target, wm);

    if (wm.config.warp_cursor_on_send) {
        warpCursorToMonitor(target, wm);
    }

    std.debug.print("sendmon: window=0x{x} to monitor {d}\n", .{ client.window, target.num });
}

pub fn snapX(client: *Client, new_x: i32, monitor: *Monitor) i32 {
    const client_width = client.width + 2 * client.border_width;
    if (@abs(monitor.win_x - new_x) < snap_distance) {
        return monitor.win_x;
    } else if (@abs((monitor.win_x + monitor.win_w) - (new_x + client_width)) < snap_distance) {
        return monitor.win_x + monitor.win_w - client_width;
    }
    return new_x;
}

pub fn snapY(client: *Client, new_y: i32, monitor: *Monitor) i32 {
    const client_height = client.height + 2 * client.border_width;
    if (@abs(monitor.win_y - new_y) < snap_distance) {
        return monitor.win_y;
    } else if (@abs((monitor.win_y + monitor.win_h) - (new_y + client_height)) < snap_distance) {
        return monitor.win_y + monitor.win_h - client_height;
    }
    return new_y;
}

pub fn movemouse(wm: *WindowManager) void {
    const monitor = wm.selected_monitor orelse return;
    const client = monitor.sel orelse return;

    if (client.is_fullscreen) {
        return;
    }

    core.restack(monitor, wm);

    const was_floating = client.is_floating;
    if (!client.is_floating) {
        client.is_floating = true;
    }

    var root_x: c_int = undefined;
    var root_y: c_int = undefined;
    var dummy_win: xlib.Window = undefined;
    var dummy_int: c_int = undefined;
    var dummy_uint: c_uint = undefined;

    _ = xlib.XQueryPointer(wm.display.handle, wm.display.root, &dummy_win, &dummy_win, &root_x, &root_y, &dummy_int, &dummy_int, &dummy_uint);

    const grab_result = xlib.XGrabPointer(
        wm.display.handle,
        wm.display.root,
        xlib.False,
        xlib.ButtonPressMask | xlib.ButtonReleaseMask | xlib.PointerMotionMask,
        xlib.GrabModeAsync,
        xlib.GrabModeAsync,
        xlib.None,
        wm.cursors.move,
        xlib.CurrentTime,
    );

    if (grab_result != xlib.GrabSuccess) {
        return;
    }

    const start_x = client.x;
    const start_y = client.y;
    const pointer_start_x = root_x;
    const pointer_start_y = root_y;
    var last_time: c_ulong = 0;

    var event: xlib.XEvent = undefined;
    var done = false;

    while (!done) {
        _ = xlib.XNextEvent(wm.display.handle, &event);

        switch (event.type) {
            xlib.MotionNotify => {
                const motion = &event.xmotion;
                if ((motion.time - last_time) < (1000 / 60)) {
                    continue;
                }
                last_time = motion.time;
                const delta_x = motion.x_root - pointer_start_x;
                const delta_y = motion.y_root - pointer_start_y;
                var new_x = start_x + delta_x;
                var new_y = start_y + delta_y;
                if (client.monitor) |client_monitor| {
                    new_x = snapX(client, new_x, client_monitor);
                    new_y = snapY(client, new_y, client_monitor);
                }
                tiling.resize(client, new_x, new_y, client.width, client.height, true);
            },
            xlib.ButtonRelease => {
                done = true;
            },
            else => {},
        }
    }

    _ = xlib.XUngrabPointer(wm.display.handle, xlib.CurrentTime);

    const new_mon = monitor_mod.rectToMonitor(wm, client.x, client.y, client.width, client.height);
    if (new_mon != null and new_mon != monitor) {
        client_mod.detach(client);
        client_mod.detachStack(client);
        client.monitor = new_mon;
        client.tags = new_mon.?.tagset[new_mon.?.sel_tags];
        client_mod.attachAside(client);
        client_mod.attachStack(client);
        wm.selected_monitor = new_mon;
        core.focus(client, wm);
        core.arrange(monitor, wm);
        core.arrange(new_mon.?, wm);
    } else {
        core.arrange(monitor, wm);
    }

    if (wm.config.auto_tile and !was_floating) {
        const drop_monitor = client.monitor orelse return;
        const center_x = client.x + @divTrunc(client.width, 2);
        const center_y = client.y + @divTrunc(client.height, 2);

        if (client_mod.tiledWindowAt(client, drop_monitor, center_x, center_y)) |target| {
            client_mod.insertBefore(client, target);
        }

        client.is_floating = false;
        core.arrange(drop_monitor, wm);
    }
}

pub fn resizemouse(wm: *WindowManager) void {
    const monitor = wm.selected_monitor orelse return;
    const client = monitor.sel orelse return;

    if (client.is_fullscreen) {
        return;
    }

    core.restack(monitor, wm);

    // If tiled_resize_mode is enabled and window is tiled, adjust mfact instead
    if (wm.config.tiled_resize_mode and !client.is_floating) {
        resizemouseTiled(wm, monitor);
        return;
    }

    if (!client.is_floating) {
        client.is_floating = true;
    }

    const grab_result = xlib.XGrabPointer(
        wm.display.handle,
        wm.display.root,
        xlib.False,
        xlib.ButtonPressMask | xlib.ButtonReleaseMask | xlib.PointerMotionMask,
        xlib.GrabModeAsync,
        xlib.GrabModeAsync,
        xlib.None,
        wm.cursors.resize,
        xlib.CurrentTime,
    );

    if (grab_result != xlib.GrabSuccess) {
        return;
    }

    _ = xlib.XWarpPointer(wm.display.handle, xlib.None, client.window, 0, 0, 0, 0, client.width + client.border_width - 1, client.height + client.border_width - 1);

    var event: xlib.XEvent = undefined;
    var done = false;
    var last_time: c_ulong = 0;

    while (!done) {
        _ = xlib.XNextEvent(wm.display.handle, &event);

        switch (event.type) {
            xlib.MotionNotify => {
                const motion = &event.xmotion;
                if ((motion.time - last_time) < (1000 / 60)) {
                    continue;
                }
                last_time = motion.time;
                var new_width = @max(1, motion.x_root - client.x - 2 * client.border_width + 1);
                var new_height = @max(1, motion.y_root - client.y - 2 * client.border_width + 1);
                if (client.monitor) |client_monitor| {
                    const client_right = client.x + new_width + 2 * client.border_width;
                    const client_bottom = client.y + new_height + 2 * client.border_width;
                    const mon_right = client_monitor.win_x + client_monitor.win_w;
                    const mon_bottom = client_monitor.win_y + client_monitor.win_h;
                    if (@abs(mon_right - client_right) < snap_distance) {
                        new_width = @max(1, mon_right - client.x - 2 * client.border_width);
                    }
                    if (@abs(mon_bottom - client_bottom) < snap_distance) {
                        new_height = @max(1, mon_bottom - client.y - 2 * client.border_width);
                    }
                }
                tiling.resize(client, client.x, client.y, new_width, new_height, true);
            },
            xlib.ButtonRelease => {
                done = true;
            },
            else => {},
        }
    }

    _ = xlib.XUngrabPointer(wm.display.handle, xlib.CurrentTime);
    core.arrange(monitor, wm);
}

/// Resize tiled windows by adjusting mfact with mouse drag (like Super+H/L but with mouse)
fn resizemouseTiled(wm: *WindowManager, monitor: *Monitor) void {
    const grab_result = xlib.XGrabPointer(
        wm.display.handle,
        wm.display.root,
        xlib.False,
        xlib.ButtonPressMask | xlib.ButtonReleaseMask | xlib.PointerMotionMask,
        xlib.GrabModeAsync,
        xlib.GrabModeAsync,
        xlib.None,
        wm.cursors.resize,
        xlib.CurrentTime,
    );

    if (grab_result != xlib.GrabSuccess) {
        return;
    }

    // Get initial pointer position
    var root_return: xlib.Window = undefined;
    var child_return: xlib.Window = undefined;
    var root_x: c_int = undefined;
    var root_y: c_int = undefined;
    var win_x: c_int = undefined;
    var win_y: c_int = undefined;
    var mask_return: c_uint = undefined;

    _ = xlib.XQueryPointer(
        wm.display.handle,
        wm.display.root,
        &root_return,
        &child_return,
        &root_x,
        &root_y,
        &win_x,
        &win_y,
        &mask_return,
    );

    const start_x = root_x;
    const initial_mfact = monitor.mfact;

    const total_width: f32 = @floatFromInt(monitor.win_w - 2 * monitor.gap_outer_v - monitor.gap_inner_v);

    var event: xlib.XEvent = undefined;
    var done = false;
    var last_time: c_ulong = 0;

    while (!done) {
        _ = xlib.XNextEvent(wm.display.handle, &event);

        switch (event.type) {
            xlib.MotionNotify => {
                const motion = &event.xmotion;
                if ((motion.time - last_time) < (1000 / 60)) {
                    continue;
                }
                last_time = motion.time;

                const delta_x: f32 = @floatFromInt(motion.x_root - start_x);
                const mfact_delta = delta_x / total_width;
                const new_mfact = initial_mfact + mfact_delta;

                if (new_mfact >= 0.05 and new_mfact <= 0.95) {
                    monitor.mfact = new_mfact;
                    monitor.pertag.mfacts[monitor.pertag.curtag] = new_mfact;
                    core.arrange(monitor, wm);
                }
            },
            xlib.ButtonRelease => {
                done = true;
            },
            else => {},
        }
    }

    _ = xlib.XUngrabPointer(wm.display.handle, xlib.CurrentTime);
}

/// Config-loading callback for wm.reloadConfig().
/// Re-initialises Lua and loads the config file (or falls back to defaults).
pub fn reloadLoadConfig(wm: *WindowManager) void {
    lua.deinit();
    _ = lua.init(&wm.config);

    const loaded = if (wm.config_path) |path|
        lua.loadFile(path)
    else
        lua.loadConfig(wm.env);

    if (loaded) {
        if (wm.config_path) |path| {
            std.debug.print("reloaded config from {s}\n", .{path});
        } else {
            std.debug.print("reloaded config from ~/.config/oxwm/config.lua\n", .{});
        }
    } else {
        std.debug.print("reload failed, restoring defaults\n", .{});
        config_mod.initializeDefaultConfig(&wm.config);
    }
}

pub fn executeAction(action: config_mod.Action, int_arg: i32, str_arg: ?[]const u8, wm: *WindowManager) void {
    switch (action) {
        .spawn_terminal => spawnTerminal(wm),
        .spawn => {
            if (str_arg) |cmd| spawnCommand(wm, cmd);
        },
        .kill_client => killFocused(wm),
        .quit => {
            std.debug.print("quit keybind pressed\n", .{});
            wm.running = false;
        },
        .reload_config => wm.reloadConfig(reloadLoadConfig),
        .restart => wm.reloadConfig(reloadLoadConfig),
        .show_keybinds => {
            if (wm.overlay) |overlay| {
                const mon = wm.selected_monitor orelse wm.monitors;
                if (mon) |m| {
                    overlay.toggle(m.mon_x, m.mon_y, m.mon_w, m.mon_h, &wm.config);
                }
            }
        },
        .focus_next => focusstack(if (int_arg == 0) 1 else int_arg, wm),
        .focus_prev => focusstack(-1, wm),
        .move_next => movestack(if (int_arg == 0) 1 else int_arg, wm),
        .move_prev => movestack(-1, wm),
        .resize_master => setmfact(@as(f32, @floatFromInt(int_arg)) / 1000.0, wm),
        .inc_master => incnmaster(1, wm),
        .dec_master => incnmaster(-1, wm),
        .toggle_floating => toggleFloating(wm),
        .toggle_fullscreen => toggleFullscreen(wm),
        .toggle_gaps => toggleGaps(wm),
        .toggle_bar => toggleBar(wm),
        .cycle_layout => cycleLayout(wm),
        .set_layout => setLayout(str_arg, wm),
        .set_layout_tiling => setLayoutIndex(0, wm),
        .set_layout_floating => setLayoutIndex(2, wm),
        .view_tag => {
            const tag_mask: u32 = @as(u32, 1) << @intCast(int_arg);
            core.view(tag_mask, wm);
        },
        .view_next_tag => viewAdjacentTag(1, wm),
        .view_prev_tag => viewAdjacentTag(-1, wm),
        .view_next_nonempty_tag => viewAdjacentNonemptyTag(1, wm),
        .view_prev_nonempty_tag => viewAdjacentNonemptyTag(-1, wm),
        .move_to_tag => {
            const tag_mask: u32 = @as(u32, 1) << @intCast(int_arg);
            tagClient(tag_mask, wm);
        },
        .toggle_view_tag => {
            const tag_mask: u32 = @as(u32, 1) << @intCast(int_arg);
            toggleView(tag_mask, wm);
        },
        .toggle_tag => {
            const tag_mask: u32 = @as(u32, 1) << @intCast(int_arg);
            toggleClientTag(tag_mask, wm);
        },
        .focus_monitor => focusmon(int_arg, wm),
        .send_to_monitor => sendmon(int_arg, wm),
        .scroll_left => core.scrollLayout(-1, wm),
        .scroll_right => core.scrollLayout(1, wm),
        .focus_direction => focusDirection(int_arg, wm),
        .workspace_switcher => {
            if (wm.switcher) |sw| {
                if (sw.visible) {
                    sw.hide();
                } else {
                    const mon = wm.selected_monitor orelse wm.monitors orelse return;
                    const master_mask = parseMasterMod(str_arg) orelse @as(c_uint, @intCast(xlib.Mod1Mask));
                    sw.show(mon, master_mask, &wm.config);
                }
            }
        },
    }
}

fn parseMasterMod(s: ?[]const u8) ?c_uint {
    const name = s orelse return null;
    if (std.mem.eql(u8, name, "Mod1") or std.mem.eql(u8, name, "Alt")) return @intCast(xlib.Mod1Mask);
    if (std.mem.eql(u8, name, "Mod4") or std.mem.eql(u8, name, "Super")) return @intCast(xlib.Mod4Mask);
    if (std.mem.eql(u8, name, "Mod3")) return @intCast(xlib.Mod3Mask);
    if (std.mem.eql(u8, name, "Mod5")) return @intCast(xlib.Mod5Mask);
    if (std.mem.eql(u8, name, "Shift")) return @intCast(xlib.ShiftMask);
    if (std.mem.eql(u8, name, "Ctrl") or std.mem.eql(u8, name, "Control")) return @intCast(xlib.ControlMask);
    return null;
}
