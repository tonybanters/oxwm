const std = @import("std");
const xlib = @import("../x11/xlib.zig");
const client_mod = @import("../client.zig");
const monitor_mod = @import("../monitor.zig");
const tiling = @import("../layouts/tiling.zig");
const scrolling = @import("../layouts/scrolling.zig");
const window_manager = @import("wm.zig");

const config_mod = @import("../config/config.zig");

const Client = client_mod.Client;
const Monitor = monitor_mod.Monitor;
const WindowManager = window_manager.WindowManager;

pub const NormalState = window_manager.NormalState;

pub fn manage(win: xlib.Window, window_attrs: *xlib.XWindowAttributes, wm: *WindowManager) void {
    const client = client_mod.create(wm.allocator, win) orelse return;
    var trans: xlib.Window = 0;

    client.x = window_attrs.x;
    client.y = window_attrs.y;
    client.width = window_attrs.width;
    client.height = window_attrs.height;
    client.old_x = window_attrs.x;
    client.old_y = window_attrs.y;
    client.old_width = window_attrs.width;
    client.old_height = window_attrs.height;
    client.old_border_width = window_attrs.border_width;
    client.border_width = wm.config.border_width;

    updateTitle(client, wm);

    if (xlib.XGetTransientForHint(wm.display.handle, win, &trans) != 0) {
        if (client_mod.windowToClient(wm.monitors, trans)) |transient_client| {
            client.monitor = transient_client.monitor;
            client.tags = transient_client.tags;
        }
    }

    if (client.monitor == null) {
        client.monitor = wm.selected_monitor;
        if (wm.next_spawn_bypass_rules) {
            if (client.monitor) |monitor| {
                client.tags = monitor.tagset[monitor.sel_tags];
            }
            wm.next_spawn_bypass_rules = false;
        } else {
            applyRules(client, wm);
        }
    }

    if (wm.next_spawn_floating) {
        client.is_floating = true;
        wm.next_spawn_floating = false;
    }

    const monitor = client.monitor orelse return;

    if (client.x + client.width > monitor.win_x + monitor.win_w) {
        client.x = monitor.win_x + monitor.win_w - client.width - 2 * client.border_width;
    }
    if (client.y + client.height > monitor.win_y + monitor.win_h) {
        client.y = monitor.win_y + monitor.win_h - client.height - 2 * client.border_width;
    }
    client.x = @max(client.x, monitor.win_x);
    client.y = @max(client.y, monitor.win_y);

    _ = xlib.XSetWindowBorderWidth(wm.display.handle, win, @intCast(client.border_width));
    _ = xlib.XSetWindowBorder(wm.display.handle, win, wm.config.border_unfocused);
    tiling.sendConfigure(client);

    updateWindowType(client, wm);
    updateSizeHints(client, wm);
    updateWmHints(client, wm);

    _ = xlib.XSelectInput(
        wm.display.handle,
        win,
        xlib.EnterWindowMask | xlib.FocusChangeMask | xlib.PropertyChangeMask | xlib.StructureNotifyMask,
    );
    grabbuttons(client, false, wm);

    if (!client.is_floating) {
        client.is_floating = trans != 0 or client.is_fixed;
        client.old_state = client.is_floating;
    }
    if (client.is_floating) {
        positionFloating(client, monitor, wm.config.floating_position);
        _ = xlib.XRaiseWindow(wm.display.handle, client.window);
    }

    if (isScrollingLayout(monitor)) {
        client_mod.attachAfter(client, monitor.sel);
    } else {
        client_mod.attachAside(client);
    }
    client_mod.attachStack(client);

    _ = xlib.XChangeProperty(wm.display.handle, wm.display.root, wm.atoms.net_client_list, xlib.XA_WINDOW, 32, xlib.PropModeAppend, @ptrCast(&client.window), 1);
    _ = xlib.XMoveResizeWindow(wm.display.handle, client.window, client.x + 2 * wm.display.screenWidth(), client.y, @intCast(client.width), @intCast(client.height));
    setClientState(client, NormalState, wm);

    if (client.monitor == wm.selected_monitor) {
        const selmon = wm.selected_monitor orelse return;
        unfocusClient(selmon.sel, false, wm);
    }
    monitor.sel = client;

    if (isScrollingLayout(monitor)) {
        const target = scrolling.getTargetScrollForWindow(monitor, client);
        monitor.scroll_offset = target;
    }

    arrange(monitor, wm);
    _ = xlib.XMapWindow(wm.display.handle, win);
    focus(null, wm);
}

pub fn unmanage(client: *Client, wm: *WindowManager) void {
    const client_monitor = client.monitor;

    var next_focus: ?*Client = null;
    if (client_monitor) |monitor| {
        if (monitor.sel == client and isScrollingLayout(monitor)) {
            next_focus = client.next;
            if (next_focus == null) {
                var prev: ?*Client = null;
                var iter = monitor.clients;
                while (iter) |c| {
                    if (c == client) break;
                    prev = c;
                    iter = c.next;
                }
                next_focus = prev;
            }
        }
    }

    client_mod.detach(client);
    client_mod.detachStack(client);

    if (client_monitor) |monitor| {
        if (monitor.sel == client) {
            monitor.sel = if (next_focus) |nf| nf else monitor.stack;
        }
        if (isScrollingLayout(monitor) and !client.is_floating) {
            if (monitor.sel) |sel| {
                monitor.scroll_offset = scrolling.getTargetScrollForWindow(monitor, sel);
            } else {
                monitor.scroll_offset = 0;
            }
        }
        arrange(monitor, wm);
    }

    if (client_monitor) |monitor| {
        if (monitor.sel) |selected| {
            focus(selected, wm);
        }
    }

    client_mod.destroy(wm.allocator, client);
    updateClientList(wm);
    wm.invalidateBars();
}

pub fn focus(target_client: ?*Client, wm: *WindowManager) void {
    const selmon = wm.selected_monitor orelse return;

    var focus_client = target_client;
    if (focus_client == null or !client_mod.isVisible(focus_client.?)) {
        focus_client = selmon.stack;
        while (focus_client) |iter| {
            if (client_mod.isVisible(iter)) break;
            focus_client = iter.stack_next;
        }
    }

    if (selmon.sel != null and selmon.sel != focus_client) {
        unfocusClient(selmon.sel, false, wm);
    }

    if (focus_client) |client| {
        if (client.monitor != selmon) {
            wm.selected_monitor = client.monitor;
        }
        if (client.is_urgent) {
            setUrgent(client, false, wm);
        }
        client_mod.detachStack(client);
        client_mod.attachStack(client);
        grabbuttons(client, true, wm);
        _ = xlib.XSetWindowBorder(wm.display.handle, client.window, wm.config.border_focused);
        if (!client.never_focus) {
            _ = xlib.XSetInputFocus(wm.display.handle, client.window, xlib.RevertToPointerRoot, xlib.CurrentTime);
            _ = xlib.XChangeProperty(wm.display.handle, wm.display.root, wm.atoms.net_active_window, xlib.XA_WINDOW, 32, xlib.PropModeReplace, @ptrCast(&client.window), 1);
        }
        _ = sendEvent(client, wm.atoms.wm_take_focus, wm);
    } else {
        _ = xlib.XSetInputFocus(wm.display.handle, wm.display.root, xlib.RevertToPointerRoot, xlib.CurrentTime);
        _ = xlib.XDeleteProperty(wm.display.handle, wm.display.root, wm.atoms.net_active_window);
    }

    const current_selmon = wm.selected_monitor orelse return;
    current_selmon.sel = focus_client;

    if (focus_client) |client| {
        if (isScrollingLayout(current_selmon)) {
            scrollToWindow(client, true, wm);
        }
    }

    wm.invalidateBars();
}

pub fn unfocusClient(client: ?*Client, reset_input_focus: bool, wm: *WindowManager) void {
    const unfocus_target = client orelse return;
    grabbuttons(unfocus_target, false, wm);
    _ = xlib.XSetWindowBorder(wm.display.handle, unfocus_target.window, wm.config.border_unfocused);
    if (reset_input_focus) {
        _ = xlib.XSetInputFocus(wm.display.handle, wm.display.root, xlib.RevertToPointerRoot, xlib.CurrentTime);
        _ = xlib.XDeleteProperty(wm.display.handle, wm.display.root, wm.atoms.net_active_window);
    }
}

pub fn setFocus(client: *Client, wm: *WindowManager) void {
    if (!client.never_focus) {
        _ = xlib.XSetInputFocus(wm.display.handle, client.window, xlib.RevertToPointerRoot, xlib.CurrentTime);
        _ = xlib.XChangeProperty(wm.display.handle, wm.display.root, wm.atoms.net_active_window, xlib.XA_WINDOW, 32, xlib.PropModeReplace, @ptrCast(&client.window), 1);
    }
    _ = sendEvent(client, wm.atoms.wm_take_focus, wm);
}

pub fn restack(monitor: *Monitor, wm: *WindowManager) void {
    wm.invalidateBars();
    const selected_client = monitor.sel orelse return;

    if (selected_client.is_floating or monitor.lt[monitor.sel_lt] == null) {
        _ = xlib.XRaiseWindow(wm.display.handle, selected_client.window);
    }

    if (monitor.lt[monitor.sel_lt] != null) {
        var window_changes: xlib.c.XWindowChanges = undefined;
        window_changes.stack_mode = xlib.c.Below;
        window_changes.sibling = monitor.bar_win;

        var current = monitor.stack;
        while (current) |client| {
            if (!client.is_floating and client_mod.isVisible(client)) {
                _ = xlib.c.XConfigureWindow(wm.display.handle, client.window, xlib.c.CWSibling | xlib.c.CWStackMode, &window_changes);
                window_changes.sibling = client.window;
            }
            current = client.stack_next;
        }
    }

    _ = xlib.XFlush(wm.display.handle);

    var discard_event: xlib.XEvent = undefined;
    while (xlib.c.XCheckMaskEvent(wm.display.handle, xlib.EnterWindowMask, &discard_event) != 0) {}
}

pub fn arrange(monitor: *Monitor, wm: *WindowManager) void {
    showhide(monitor, wm);
    if (monitor.lt[monitor.sel_lt]) |layout| {
        if (layout.arrange_fn) |arrange_fn| {
            arrange_fn(monitor);
        }
    }
    restack(monitor, wm);
}

pub fn showhide(monitor: *Monitor, wm: *WindowManager) void {
    showhideClient(monitor.stack, wm);
}

pub fn showhideClient(client: ?*Client, wm: *WindowManager) void {
    const target = client orelse return;
    if (client_mod.isVisible(target)) {
        _ = xlib.XMoveWindow(wm.display.handle, target.window, target.x, target.y);
        const monitor = target.monitor orelse return;
        if ((monitor.lt[monitor.sel_lt] == null or target.is_floating) and !target.is_fullscreen) {
            tiling.resize(target, target.x, target.y, target.width, target.height, false);
        }
        showhideClient(target.stack_next, wm);
    } else {
        showhideClient(target.stack_next, wm);
        const monitor = target.monitor orelse return;
        const client_width = target.width + 2 * target.border_width;
        const hide_x = monitor.win_x - 2 * client_width;
        _ = xlib.XMoveWindow(wm.display.handle, target.window, hide_x, target.y);
    }
}

pub fn grabbuttons(client: *Client, focused: bool, wm: *WindowManager) void {
    wm.updateNumlockMask();
    const modifiers = [_]c_uint{ 0, xlib.LockMask, wm.numlock_mask, wm.numlock_mask | xlib.LockMask };

    _ = xlib.XUngrabButton(wm.display.handle, xlib.AnyButton, xlib.AnyModifier, client.window);
    if (!focused) {
        _ = xlib.XGrabButton(
            wm.display.handle,
            xlib.AnyButton,
            xlib.AnyModifier,
            client.window,
            xlib.False,
            xlib.ButtonPressMask | xlib.ButtonReleaseMask,
            xlib.GrabModeSync,
            xlib.GrabModeSync,
            xlib.None,
            xlib.None,
        );
    }
    for (wm.config.buttons.items) |button| {
        if (button.click == .client_win) {
            for (modifiers) |modifier| {
                _ = xlib.XGrabButton(
                    wm.display.handle,
                    @intCast(button.button),
                    button.mod_mask | modifier,
                    client.window,
                    xlib.False,
                    xlib.ButtonPressMask | xlib.ButtonReleaseMask,
                    xlib.GrabModeAsync,
                    xlib.GrabModeSync,
                    xlib.None,
                    xlib.None,
                );
            }
        }
    }
}

pub fn setClientState(client: *Client, state: c_long, wm: *WindowManager) void {
    var data: [2]c_long = .{ state, xlib.None };
    _ = xlib.c.XChangeProperty(wm.display.handle, client.window, wm.atoms.wm_state, xlib.XA_ATOM, 32, xlib.PropModeReplace, @ptrCast(&data), 2);
}

pub fn setFullscreen(client: *Client, fullscreen: bool, wm: *WindowManager) void {
    const monitor = client.monitor orelse return;

    if (fullscreen and !client.is_fullscreen) {
        var fullscreen_atom = wm.atoms.net_wm_state_fullscreen;
        _ = xlib.XChangeProperty(
            wm.display.handle,
            client.window,
            wm.atoms.net_wm_state,
            xlib.XA_ATOM,
            32,
            xlib.PropModeReplace,
            @ptrCast(&fullscreen_atom),
            1,
        );
        client.is_fullscreen = true;
        client.old_state = client.is_floating;
        client.old_border_width = client.border_width;
        client.border_width = 0;
        client.is_floating = true;

        _ = xlib.XSetWindowBorderWidth(wm.display.handle, client.window, 0);
        tiling.resizeClient(client, monitor.mon_x, monitor.mon_y, monitor.mon_w, monitor.mon_h);
        _ = xlib.XRaiseWindow(wm.display.handle, client.window);

        std.debug.print("fullscreen enabled: window=0x{x}\n", .{client.window});
    } else if (!fullscreen and client.is_fullscreen) {
        var no_atom: xlib.Atom = 0;
        _ = xlib.XChangeProperty(
            wm.display.handle,
            client.window,
            wm.atoms.net_wm_state,
            xlib.XA_ATOM,
            32,
            xlib.PropModeReplace,
            @ptrCast(&no_atom),
            0,
        );
        client.is_fullscreen = false;
        client.is_floating = client.old_state;
        client.border_width = client.old_border_width;

        client.x = client.old_x;
        client.y = client.old_y;
        client.width = client.old_width;
        client.height = client.old_height;

        tiling.resizeClient(client, client.x, client.y, client.width, client.height);
        arrange(monitor, wm);

        std.debug.print("fullscreen disabled: window=0x{x}\n", .{client.window});
    }
}

pub fn focusTopClient(monitor: *Monitor, wm: *WindowManager) void {
    var visible_client = monitor.stack;
    while (visible_client) |client| {
        if (client_mod.isVisible(client)) {
            focus(client, wm);
            return;
        }
        visible_client = client.stack_next;
    }
    monitor.sel = null;
    _ = xlib.XSetInputFocus(wm.display.handle, wm.display.root, xlib.RevertToPointerRoot, xlib.CurrentTime);
}

pub fn tickAnimations(wm: *WindowManager) void {
    if (!wm.scroll_animation.isActive()) return;

    const monitor = wm.selected_monitor orelse return;
    const result = wm.scroll_animation.update();
    if (result) |new_offset| {
        monitor.scroll_offset = new_offset;
    }

    if (!wm.scroll_animation.isActive()) {
        arrange(monitor, wm);
        var discard_event: xlib.XEvent = undefined;
        while (xlib.c.XCheckMaskEvent(wm.display.handle, xlib.EnterWindowMask | xlib.PointerMotionMask, &discard_event) != 0) {}
        return;
    }

    if (isScrollingLayout(monitor)) {
        scrolling.scrollEx(monitor, false, true);
        _ = xlib.XFlush(wm.display.handle);
    } else {
        arrange(monitor, wm);
    }
}

pub fn isScrollingLayout(monitor: *Monitor) bool {
    if (monitor.lt[monitor.sel_lt]) |layout| {
        return layout.arrange_fn == scrolling.layout.arrange_fn;
    }
    return false;
}

pub fn scrollLayout(direction: i32, wm: *WindowManager) void {
    const monitor = wm.selected_monitor orelse return;
    if (!isScrollingLayout(monitor)) return;

    const scroll_step = scrolling.getScrollStep(monitor);
    const max_scroll = scrolling.getMaxScroll(monitor);

    const current = if (wm.scroll_animation.isActive())
        wm.scroll_animation.target()
    else
        monitor.scroll_offset;

    var target = current + direction * scroll_step;
    target = @max(0, @min(target, max_scroll));

    wm.scroll_animation.start(monitor.scroll_offset, target, wm.animation_config);
}

pub fn scrollToWindow(client: *Client, animate: bool, wm: *WindowManager) void {
    const monitor = client.monitor orelse return;
    if (!isScrollingLayout(monitor)) return;

    const target = scrolling.getTargetScrollForWindow(monitor, client);

    if (animate) {
        wm.scroll_animation.start(monitor.scroll_offset, target, wm.animation_config);
    } else {
        monitor.scroll_offset = target;
        arrange(monitor, wm);
    }
}

fn positionFloating(client: *Client, monitor: *Monitor, pos: config_mod.FloatingPosition) void {
    const bw = 2 * client.border_width;
    const x: i32 = switch (pos) {
        .top_left, .center_left, .bottom_left => monitor.win_x,
        .top_center, .center, .bottom_center => monitor.win_x + @divTrunc(monitor.win_w - client.width - bw, 2),
        .top_right, .center_right, .bottom_right => monitor.win_x + monitor.win_w - client.width - bw,
    };
    const y: i32 = switch (pos) {
        .top_left, .top_center, .top_right => monitor.win_y,
        .center_left, .center, .center_right => monitor.win_y + @divTrunc(monitor.win_h - client.height - bw, 2),
        .bottom_left, .bottom_center, .bottom_right => monitor.win_y + monitor.win_h - client.height - bw,
    };
    client.x = x;
    client.y = y;
}

pub fn applyRules(client: *Client, wm: *WindowManager) void {
    var class_hint: xlib.XClassHint = .{ .res_name = null, .res_class = null };
    _ = xlib.XGetClassHint(wm.display.handle, client.window, &class_hint);

    const class_str: []const u8 = if (class_hint.res_class) |ptr| std.mem.sliceTo(ptr, 0) else "";
    const instance_str: []const u8 = if (class_hint.res_name) |ptr| std.mem.sliceTo(ptr, 0) else "";

    client.is_floating = false;
    client.tags = 0;
    var rule_focus = false;

    for (wm.config.rules.items) |rule| {
        const class_matches = if (rule.class) |rc| std.mem.indexOf(u8, class_str, rc) != null else true;
        const instance_matches = if (rule.instance) |ri| std.mem.indexOf(u8, instance_str, ri) != null else true;
        const title_matches = if (rule.title) |rt| std.mem.indexOf(u8, std.mem.sliceTo(&client.name, 0), rt) != null else true;

        if (class_matches and instance_matches and title_matches) {
            client.is_floating = rule.is_floating;
            client.tags |= rule.tags;
            if (rule.monitor >= 0) {
                var target = wm.monitors;
                var index: i32 = 0;
                while (target) |mon| {
                    if (index == rule.monitor) {
                        client.monitor = mon;
                        break;
                    }
                    index += 1;
                    target = mon.next;
                }
            }
            if (rule.focus) {
                rule_focus = true;
            }
        }
    }

    if (class_hint.res_class) |ptr| {
        _ = xlib.XFree(@ptrCast(ptr));
    }
    if (class_hint.res_name) |ptr| {
        _ = xlib.XFree(@ptrCast(ptr));
    }

    const monitor = client.monitor orelse return;
    if (client.tags == 0) {
        client.tags = monitor.tagset[monitor.sel_tags];
    }

    if (rule_focus and client.tags != 0) {
        const monitor_tagset = monitor.tagset[monitor.sel_tags];
        const is_tag_focused = (monitor_tagset & client.tags) == client.tags;
        if (!is_tag_focused) {
            view(client.tags, wm);
        }
    }
}

pub fn updateSizeHints(client: *Client, wm: *WindowManager) void {
    var size_hints: xlib.XSizeHints = undefined;
    var msize: c_long = 0;

    if (xlib.XGetWMNormalHints(wm.display.handle, client.window, &size_hints, &msize) == 0) {
        size_hints.flags = xlib.PSize;
    }

    if ((size_hints.flags & xlib.PBaseSize) != 0) {
        client.base_width = size_hints.base_width;
        client.base_height = size_hints.base_height;
    } else if ((size_hints.flags & xlib.PMinSize) != 0) {
        client.base_width = size_hints.min_width;
        client.base_height = size_hints.min_height;
    } else {
        client.base_width = 0;
        client.base_height = 0;
    }

    if ((size_hints.flags & xlib.PResizeInc) != 0) {
        client.increment_width = size_hints.width_inc;
        client.increment_height = size_hints.height_inc;
    } else {
        client.increment_width = 0;
        client.increment_height = 0;
    }

    if ((size_hints.flags & xlib.PMaxSize) != 0) {
        client.max_width = size_hints.max_width;
        client.max_height = size_hints.max_height;
    } else {
        client.max_width = 0;
        client.max_height = 0;
    }

    if ((size_hints.flags & xlib.PMinSize) != 0) {
        client.min_width = size_hints.min_width;
        client.min_height = size_hints.min_height;
    } else if ((size_hints.flags & xlib.PBaseSize) != 0) {
        client.min_width = size_hints.base_width;
        client.min_height = size_hints.base_height;
    } else {
        client.min_width = 0;
        client.min_height = 0;
    }

    if ((size_hints.flags & xlib.PAspect) != 0) {
        client.min_aspect = @as(f32, @floatFromInt(size_hints.min_aspect.y)) / @as(f32, @floatFromInt(size_hints.min_aspect.x));
        client.max_aspect = @as(f32, @floatFromInt(size_hints.max_aspect.x)) / @as(f32, @floatFromInt(size_hints.max_aspect.y));
    } else {
        client.min_aspect = 0.0;
        client.max_aspect = 0.0;
    }

    client.is_fixed = (client.max_width != 0 and client.max_height != 0 and client.max_width == client.min_width and client.max_height == client.min_height);
    client.hints_valid = true;
}

pub fn updateWmHints(client: *Client, wm: *WindowManager) void {
    const wmh = xlib.XGetWMHints(wm.display.handle, client.window);
    if (wmh) |hints| {
        defer _ = xlib.XFree(@ptrCast(hints));

        if (client == (wm.selected_monitor orelse return).sel and (hints.*.flags & xlib.XUrgencyHint) != 0) {
            hints.*.flags = hints.*.flags & ~@as(c_long, xlib.XUrgencyHint);
            _ = xlib.XSetWMHints(wm.display.handle, client.window, hints);
        } else {
            client.is_urgent = (hints.*.flags & xlib.XUrgencyHint) != 0;
        }

        if ((hints.*.flags & xlib.InputHint) != 0) {
            client.never_focus = hints.*.input == 0;
        } else {
            client.never_focus = false;
        }
    }
}

pub fn updateWindowType(client: *Client, wm: *WindowManager) void {
    const state = getAtomProp(client, wm.atoms.net_wm_state, wm);
    const window_type = getAtomProp(client, wm.atoms.net_wm_window_type, wm);

    if (state == wm.atoms.net_wm_state_fullscreen) {
        setFullscreen(client, true, wm);
    }
    if (window_type == wm.atoms.net_wm_window_type_dialog) {
        client.is_floating = true;
    }
}

pub fn updateTitle(client: *Client, wm: *WindowManager) void {
    if (!getTextProp(client.window, wm.atoms.net_wm_name, &client.name, wm)) {
        _ = getTextProp(client.window, xlib.XA_WM_NAME, &client.name, wm);
    }
    if (client.name[0] == 0) {
        @memcpy(client.name[0..6], "broken");
    }
}

pub fn getAtomProp(client: *Client, prop: xlib.Atom, wm: *WindowManager) xlib.Atom {
    var actual_type: xlib.Atom = undefined;
    var actual_format: c_int = undefined;
    var num_items: c_ulong = undefined;
    var bytes_after: c_ulong = undefined;
    var prop_data: [*c]u8 = undefined;

    if (xlib.XGetWindowProperty(wm.display.handle, client.window, prop, 0, @sizeOf(xlib.Atom), xlib.False, xlib.XA_ATOM, &actual_type, &actual_format, &num_items, &bytes_after, &prop_data) == 0 and prop_data != null) {
        const atom: xlib.Atom = @as(*xlib.Atom, @ptrCast(@alignCast(prop_data))).*;
        _ = xlib.XFree(@ptrCast(prop_data));
        return atom;
    }
    return 0;
}

pub fn getTextProp(window: xlib.Window, atom: xlib.Atom, text: *[256]u8, wm: *WindowManager) bool {
    var name: xlib.XTextProperty = undefined;
    text[0] = 0;

    if (xlib.XGetTextProperty(wm.display.handle, window, &name, atom) == 0 or name.nitems == 0) {
        return false;
    }

    if (name.encoding == xlib.XA_STRING) {
        const len = @min(name.nitems, 255);
        @memcpy(text[0..len], name.value[0..len]);
        text[len] = 0;
    } else {
        var list: [*c][*c]u8 = undefined;
        var count: c_int = undefined;
        if (xlib.XmbTextPropertyToTextList(wm.display.handle, &name, &list, &count) >= xlib.Success and count > 0 and list[0] != null) {
            const str = std.mem.sliceTo(list[0], 0);
            const copy_len = @min(str.len, 255);
            @memcpy(text[0..copy_len], str[0..copy_len]);
            text[copy_len] = 0;
            xlib.XFreeStringList(list);
        }
    }
    text[255] = 0;
    _ = xlib.XFree(@ptrCast(name.value));
    return true;
}

pub fn updateClientList(wm: *WindowManager) void {
    _ = xlib.XDeleteProperty(wm.display.handle, wm.display.root, wm.atoms.net_client_list);

    var current_monitor = wm.monitors;
    while (current_monitor) |monitor| {
        var current_client = monitor.clients;
        while (current_client) |client| {
            _ = xlib.XChangeProperty(wm.display.handle, wm.display.root, wm.atoms.net_client_list, xlib.XA_WINDOW, 32, xlib.PropModeAppend, @ptrCast(&client.window), 1);
            current_client = client.next;
        }
        current_monitor = monitor.next;
    }
}

pub fn sendEvent(client: *Client, protocol: xlib.Atom, wm: *WindowManager) bool {
    var protocols: [*c]xlib.Atom = undefined;
    var num_protocols: c_int = 0;
    var exists = false;

    if (xlib.XGetWMProtocols(wm.display.handle, client.window, &protocols, &num_protocols) != 0) {
        var index: usize = 0;
        while (index < @as(usize, @intCast(num_protocols))) : (index += 1) {
            if (protocols[index] == protocol) {
                exists = true;
                break;
            }
        }
        _ = xlib.XFree(@ptrCast(protocols));
    }

    if (exists) {
        var event: xlib.XEvent = undefined;
        event.type = xlib.ClientMessage;
        event.xclient.window = client.window;
        event.xclient.message_type = wm.atoms.wm_protocols;
        event.xclient.format = 32;
        event.xclient.data.l[0] = @intCast(protocol);
        event.xclient.data.l[1] = xlib.CurrentTime;
        _ = xlib.XSendEvent(wm.display.handle, client.window, xlib.False, xlib.NoEventMask, &event);
    }
    return exists;
}

pub fn setUrgent(client: *Client, urgent: bool, wm: *WindowManager) void {
    client.is_urgent = urgent;
    const wmh = xlib.XGetWMHints(wm.display.handle, client.window);
    if (wmh) |hints| {
        if (urgent) {
            hints.*.flags = hints.*.flags | xlib.XUrgencyHint;
        } else {
            hints.*.flags = hints.*.flags & ~@as(c_long, xlib.XUrgencyHint);
        }
        _ = xlib.XSetWMHints(wm.display.handle, client.window, hints);
        _ = xlib.XFree(@ptrCast(hints));
    }
}

pub fn hasClientsOnTag(monitor: *monitor_mod.Monitor, tag_mask: u32) bool {
    var client = monitor.clients;
    while (client) |c| {
        if ((c.tags & tag_mask) != 0) {
            return true;
        }
        client = c.next;
    }
    return false;
}

pub fn view(tag_mask: u32, wm: *WindowManager) void {
    const monitor = wm.selected_monitor orelse return;
    if (tag_mask == monitor.tagset[monitor.sel_tags]) {
        return;
    }
    monitor.sel_tags ^= 1;
    if (tag_mask != 0) {
        monitor.tagset[monitor.sel_tags] = tag_mask;
        monitor.pertag.prevtag = monitor.pertag.curtag;

        if (tag_mask == ~@as(u32, 0)) {
            monitor.pertag.curtag = 0;
        } else {
            var i: u32 = 0;
            while (i < 9) : (i += 1) {
                if ((tag_mask & (@as(u32, 1) << @intCast(i))) != 0) break;
            }
            monitor.pertag.curtag = i + 1;
        }
    } else {
        const tmp = monitor.pertag.prevtag;
        monitor.pertag.prevtag = monitor.pertag.curtag;
        monitor.pertag.curtag = tmp;
    }

    monitor.nmaster = monitor.pertag.nmasters[monitor.pertag.curtag];
    monitor.mfact = monitor.pertag.mfacts[monitor.pertag.curtag];
    monitor.sel_lt = monitor.pertag.sellts[monitor.pertag.curtag];

    const new_show_bar = monitor.pertag.showbars[monitor.pertag.curtag];
    if (new_show_bar != monitor.show_bar) {
        monitor.show_bar = new_show_bar;
        window_manager.actions.updateBarVisibility(monitor, wm);
    }

    focusTopClient(monitor, wm);
    arrange(monitor, wm);
    wm.invalidateBars();
    std.debug.print("view: tag_mask={d}\n", .{monitor.tagset[monitor.sel_tags]});
}
