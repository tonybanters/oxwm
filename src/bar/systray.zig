const std = @import("std");
const xlib = @import("../x11/xlib.zig");

pub const SYSTEM_TRAY_REQUEST_DOCK: c_long = 0;
pub const SYSTEM_TRAY_BEGIN_MESSAGE: c_long = 1;
pub const SYSTEM_TRAY_CANCEL_MESSAGE: c_long = 2;

pub const XEMBED_EMBEDDED_NOTIFY: c_long = 0;
pub const XEMBED_WINDOW_ACTIVATE: c_long = 1;
pub const XEMBED_WINDOW_DEACTIVATE: c_long = 2;
pub const XEMBED_REQUEST_FOCUS: c_long = 3;
pub const XEMBED_FOCUS_IN: c_long = 4;
pub const XEMBED_FOCUS_OUT: c_long = 5;
pub const XEMBED_FOCUS_NEXT: c_long = 6;
pub const XEMBED_FOCUS_PREV: c_long = 7;
pub const XEMBED_MAPPED: c_ulong = 1 << 0;

pub const XEMBED_VERSION: c_long = 0;

pub const Icon = struct {
    window: xlib.Window,
    width: i32,
    height: i32,
    mapped: bool,
};

pub const Systray = struct {
    window: xlib.Window,
    icons: std.ArrayList(Icon),
    allocator: std.mem.Allocator,
    display: *xlib.Display,
    screen: c_int,
    icon_size: i32,
    bar_height: i32,

    net_system_tray_opcode: xlib.Atom,
    net_system_tray_orientation: xlib.Atom,
    net_system_tray_visual: xlib.Atom,
    manager_atom: xlib.Atom,
    xembed: xlib.Atom,
    xembed_info: xlib.Atom,

    pub fn init(
        allocator: std.mem.Allocator,
        display: *xlib.Display,
        screen: c_int,
        bar_win: xlib.Window,
        bar_height: i32,
        background: u32,
    ) ?*Systray {
        const self = allocator.create(Systray) catch return null;

        const root = xlib.XRootWindow(display, screen);

        self.allocator = allocator;
        self.display = display;
        self.screen = screen;
        self.bar_height = bar_height;
        self.icon_size = bar_height - 8;
        self.icons = .empty;

        self.net_system_tray_opcode = xlib.XInternAtom(display, "_NET_SYSTEM_TRAY_OPCODE", xlib.False);
        self.net_system_tray_orientation = xlib.XInternAtom(display, "_NET_SYSTEM_TRAY_ORIENTATION", xlib.False);
        self.net_system_tray_visual = xlib.XInternAtom(display, "_NET_SYSTEM_TRAY_VISUAL", xlib.False);
        self.xembed = xlib.XInternAtom(display, "_XEMBED", xlib.False);
        self.xembed_info = xlib.XInternAtom(display, "_XEMBED_INFO", xlib.False);

        var selection_name: [32]u8 = undefined;
        const name_len = std.fmt.bufPrint(&selection_name, "_NET_SYSTEM_TRAY_S{d}", .{screen}) catch return null;
        selection_name[name_len.len] = 0;
        self.manager_atom = xlib.XInternAtom(display, @ptrCast(&selection_name), xlib.False);

        const current_owner = xlib.c.XGetSelectionOwner(display, self.manager_atom);
        if (current_owner != xlib.None) {
            allocator.destroy(self);
            return null;
        }

        self.window = xlib.c.XCreateSimpleWindow(
            display,
            bar_win,
            0,
            0,
            1,
            @intCast(bar_height - 2),
            0,
            0,
            0,
        );

        var attrs: xlib.c.XSetWindowAttributes = undefined;
        attrs.event_mask = xlib.c.SubstructureNotifyMask | xlib.c.SubstructureRedirectMask | xlib.c.StructureNotifyMask | xlib.c.ExposureMask;
        attrs.override_redirect = xlib.True;
        attrs.background_pixel = background;
        _ = xlib.c.XChangeWindowAttributes(
            display,
            self.window,
            xlib.c.CWEventMask | xlib.c.CWOverrideRedirect | xlib.c.CWBackPixel,
            &attrs,
        );

        _ = xlib.c.XSetSelectionOwner(display, self.manager_atom, self.window, xlib.CurrentTime);
        if (xlib.c.XGetSelectionOwner(display, self.manager_atom) != self.window) {
            _ = xlib.c.XDestroyWindow(display, self.window);
            allocator.destroy(self);
            return null;
        }

        const orientation: c_long = 0;
        _ = xlib.XChangeProperty(
            display,
            self.window,
            self.net_system_tray_orientation,
            xlib.XA_CARDINAL,
            32,
            xlib.PropModeReplace,
            @ptrCast(&orientation),
            1,
        );

        self.sendManagerMessage(root);

        _ = xlib.XMapWindow(display, self.window);
        _ = xlib.XSync(display, xlib.False);

        return self;
    }

    pub fn deinit(self: *Systray) void {
        for (self.icons.items) |icon| {
            _ = xlib.c.XUnmapWindow(self.display, icon.window);
            _ = xlib.c.XReparentWindow(self.display, icon.window, xlib.XRootWindow(self.display, self.screen), 0, 0);
        }
        self.icons.deinit(self.allocator);
        _ = xlib.c.XDestroyWindow(self.display, self.window);
        self.allocator.destroy(self);
    }

    fn sendManagerMessage(self: *Systray, root: xlib.Window) void {
        var ev: xlib.c.XClientMessageEvent = undefined;
        ev.type = xlib.ClientMessage;
        ev.window = root;
        ev.message_type = xlib.XInternAtom(self.display, "MANAGER", xlib.False);
        ev.format = 32;
        ev.data.l[0] = xlib.CurrentTime;
        ev.data.l[1] = @intCast(self.manager_atom);
        ev.data.l[2] = @intCast(self.window);
        ev.data.l[3] = 0;
        ev.data.l[4] = 0;

        _ = xlib.XSendEvent(
            self.display,
            root,
            xlib.False,
            xlib.c.StructureNotifyMask,
            @ptrCast(&ev),
        );
    }

    fn sendXembedMessage(self: *Systray, win: xlib.Window, msg: c_long, detail: c_long, data1: c_long, data2: c_long) void {
        var ev: xlib.c.XClientMessageEvent = undefined;
        ev.type = xlib.ClientMessage;
        ev.window = win;
        ev.message_type = self.xembed;
        ev.format = 32;
        ev.data.l[0] = xlib.CurrentTime;
        ev.data.l[1] = msg;
        ev.data.l[2] = detail;
        ev.data.l[3] = data1;
        ev.data.l[4] = data2;

        _ = xlib.XSendEvent(
            self.display,
            win,
            xlib.False,
            xlib.c.NoEventMask,
            @ptrCast(&ev),
        );
    }

    fn sendConfigureNotify(self: *Systray, win: xlib.Window, x: i32, y: i32, w: i32, h: i32) void {
        var ev: xlib.c.XConfigureEvent = undefined;
        ev.type = xlib.ConfigureNotify;
        ev.event = win;
        ev.window = win;
        ev.x = x;
        ev.y = y;
        ev.width = w;
        ev.height = h;
        ev.border_width = 0;
        ev.above = xlib.None;
        ev.override_redirect = xlib.False;

        _ = xlib.XSendEvent(
            self.display,
            win,
            xlib.False,
            xlib.c.StructureNotifyMask,
            @ptrCast(&ev),
        );
    }

    fn getXembedInfo(self: *Systray, win: xlib.Window) ?struct { version: c_ulong, flags: c_ulong } {
        var actual_type: xlib.Atom = 0;
        var actual_format: c_int = 0;
        var nitems: c_ulong = 0;
        var bytes_after: c_ulong = 0;
        var data: [*c]u8 = null;

        const result = xlib.XGetWindowProperty(
            self.display,
            win,
            self.xembed_info,
            0,
            2,
            xlib.False,
            self.xembed_info,
            &actual_type,
            &actual_format,
            &nitems,
            &bytes_after,
            &data,
        );

        if (result != 0 or actual_type != self.xembed_info or actual_format != 32 or nitems < 2) {
            if (data != null) _ = xlib.XFree(data);
            return null;
        }

        const info_ptr: [*]c_ulong = @ptrCast(@alignCast(data));
        const version = info_ptr[0];
        const flags = info_ptr[1];
        _ = xlib.XFree(data);

        return .{ .version = version, .flags = flags };
    }

    pub fn handleClientMessage(self: *Systray, ev: *xlib.XClientMessageEvent) bool {
        if (ev.message_type != self.net_system_tray_opcode) return false;

        const opcode = ev.data.l[1];
        if (opcode == SYSTEM_TRAY_REQUEST_DOCK) {
            const icon_win: xlib.Window = @intCast(ev.data.l[2]);
            self.dockIcon(icon_win);
            return true;
        }

        return false;
    }

    fn updateIconGeometry(self: *Systray, icon: *Icon, w: i32, h: i32) void {
        _ = w;
        _ = h;
        icon.width = self.icon_size;
        icon.height = self.icon_size;

        _ = xlib.c.XResizeWindow(
            self.display,
            icon.window,
            @intCast(icon.width),
            @intCast(icon.height),
        );
    }

    fn dockIcon(self: *Systray, icon_win: xlib.Window) void {
        for (self.icons.items) |icon| {
            if (icon.window == icon_win) return;
        }

        var wa: xlib.XWindowAttributes = undefined;
        if (xlib.XGetWindowAttributes(self.display, icon_win, &wa) == 0) {
            return;
        }

        _ = xlib.c.XSetWindowBorderWidth(self.display, icon_win, 0);

        _ = xlib.c.XSelectInput(
            self.display,
            icon_win,
            xlib.c.StructureNotifyMask | xlib.c.PropertyChangeMask | xlib.c.ResizeRedirectMask,
        );

        _ = xlib.c.XReparentWindow(
            self.display,
            icon_win,
            self.window,
            0,
            0,
        );

        const info = self.getXembedInfo(icon_win);
        const mapped = if (info) |i| (i.flags & XEMBED_MAPPED) != 0 else true;

        var icon = Icon{
            .window = icon_win,
            .width = self.icon_size,
            .height = self.icon_size,
            .mapped = mapped,
        };

        self.updateIconGeometry(&icon, wa.width, wa.height);

        self.icons.append(self.allocator, icon) catch return;

        self.sendXembedMessage(icon_win, XEMBED_EMBEDDED_NOTIFY, 0, @intCast(self.window), XEMBED_VERSION);
        self.sendXembedMessage(icon_win, XEMBED_WINDOW_ACTIVATE, 0, 0, 0);
        self.sendXembedMessage(icon_win, XEMBED_FOCUS_IN, 0, 0, 0);

        if (mapped) {
            _ = xlib.XMapWindow(self.display, icon_win);
        }

        self.arrangeIcons();
    }

    pub fn handleConfigureRequest(self: *Systray, ev: *xlib.XConfigureRequestEvent) bool {
        for (self.icons.items) |*icon| {
            if (icon.window == ev.window) {
                if ((ev.value_mask & xlib.c.CWWidth) != 0 or (ev.value_mask & xlib.c.CWHeight) != 0) {
                    self.updateIconGeometry(icon, ev.width, ev.height);
                    self.arrangeIcons();
                }
                return true;
            }
        }
        return false;
    }

    pub fn handleResizeRequest(self: *Systray, win: xlib.Window, w: c_int, h: c_int) bool {
        for (self.icons.items) |*icon| {
            if (icon.window == win) {
                self.updateIconGeometry(icon, w, h);
                self.arrangeIcons();
                return true;
            }
        }
        return false;
    }

    pub fn handleDestroyNotify(self: *Systray, win: xlib.Window) bool {
        return self.removeIcon(win);
    }

    pub fn handleUnmapNotify(self: *Systray, win: xlib.Window) bool {
        for (self.icons.items) |*icon| {
            if (icon.window == win) {
                icon.mapped = false;
                self.arrangeIcons();
                return true;
            }
        }
        return false;
    }

    pub fn handleMapNotify(self: *Systray, win: xlib.Window) bool {
        for (self.icons.items) |*icon| {
            if (icon.window == win) {
                icon.mapped = true;
                self.arrangeIcons();
                return true;
            }
        }
        return false;
    }

    pub fn handlePropertyNotify(self: *Systray, ev: *xlib.XPropertyEvent) bool {
        if (ev.atom != self.xembed_info) return false;

        for (self.icons.items) |*icon| {
            if (icon.window == ev.window) {
                const info = self.getXembedInfo(icon.window) orelse return true;
                const should_map = (info.flags & XEMBED_MAPPED) != 0;

                if (should_map and !icon.mapped) {
                    icon.mapped = true;
                    _ = xlib.XMapWindow(self.display, icon.window);
                    self.arrangeIcons();
                } else if (!should_map and icon.mapped) {
                    icon.mapped = false;
                    _ = xlib.c.XUnmapWindow(self.display, icon.window);
                    self.arrangeIcons();
                }
                return true;
            }
        }
        return false;
    }

    pub fn handleReparentNotify(self: *Systray, win: xlib.Window, parent: xlib.Window) bool {
        if (parent != self.window) {
            return self.removeIcon(win);
        }
        return false;
    }

    fn removeIcon(self: *Systray, win: xlib.Window) bool {
        for (self.icons.items, 0..) |icon, i| {
            if (icon.window == win) {
                _ = self.icons.orderedRemove(i);
                self.arrangeIcons();
                return true;
            }
        }
        return false;
    }

    fn arrangeIcons(self: *Systray) void {
        const spacing: i32 = 4;
        var x: i32 = 0;
        const y: i32 = @divTrunc(self.bar_height - self.icon_size, 2);

        for (self.icons.items) |icon| {
            if (icon.mapped) {
                _ = xlib.XMoveWindow(self.display, icon.window, x, y);
                self.sendConfigureNotify(icon.window, x, y, icon.width, icon.height);
                x += icon.width + spacing;
            }
        }

        const total_width: u32 = if (x > 0) @intCast(x) else 1;
        _ = xlib.c.XResizeWindow(self.display, self.window, total_width, @intCast(self.bar_height - 2));
        _ = xlib.XSync(self.display, xlib.False);
    }

    pub fn width(self: *const Systray) i32 {
        const spacing: i32 = 4;
        var w: i32 = 0;
        for (self.icons.items) |icon| {
            if (icon.mapped) {
                w += icon.width + spacing;
            }
        }
        return w;
    }

    pub fn updatePosition(self: *Systray, x: i32, y: i32) void {
        _ = xlib.XMoveWindow(self.display, self.window, x, y);
    }

    pub fn isIconWindow(self: *const Systray, win: xlib.Window) bool {
        if (win == self.window) return true;
        for (self.icons.items) |icon| {
            if (icon.window == win) return true;
        }
        return false;
    }

    pub fn handleButtonPress(self: *Systray, ev: *xlib.XButtonEvent) bool {
        if (ev.window != self.window) {
            for (self.icons.items) |icon| {
                if (icon.window == ev.window) {
                    self.sendButtonEvent(icon.window, ev, true);
                    return true;
                }
            }
            return false;
        }

        const spacing: i32 = 4;
        var x: i32 = 0;
        for (self.icons.items) |icon| {
            if (icon.mapped) {
                if (ev.x >= x and ev.x < x + icon.width) {
                    self.sendButtonEvent(icon.window, ev, true);
                    return true;
                }
                x += icon.width + spacing;
            }
        }
        return false;
    }

    pub fn handleButtonRelease(self: *Systray, ev: *xlib.XButtonEvent) bool {
        if (ev.window != self.window) {
            for (self.icons.items) |icon| {
                if (icon.window == ev.window) {
                    self.sendButtonEvent(icon.window, ev, false);
                    return true;
                }
            }
            return false;
        }

        const spacing: i32 = 4;
        var x: i32 = 0;
        for (self.icons.items) |icon| {
            if (icon.mapped) {
                if (ev.x >= x and ev.x < x + icon.width) {
                    self.sendButtonEvent(icon.window, ev, false);
                    return true;
                }
                x += icon.width + spacing;
            }
        }
        return false;
    }

    fn sendButtonEvent(self: *Systray, win: xlib.Window, ev: *xlib.XButtonEvent, is_press: bool) void {
        var event: xlib.c.XButtonEvent = undefined;
        event.type = if (is_press) xlib.ButtonPress else xlib.ButtonRelease;
        event.window = win;
        event.root = xlib.XRootWindow(self.display, self.screen);
        event.subwindow = xlib.None;
        event.time = ev.time;
        event.x = ev.x;
        event.y = ev.y;
        event.x_root = ev.x_root;
        event.y_root = ev.y_root;
        event.state = ev.state;
        event.button = ev.button;
        event.same_screen = xlib.True;

        _ = xlib.XSendEvent(
            self.display,
            win,
            xlib.False,
            xlib.c.ButtonPressMask | xlib.c.ButtonReleaseMask,
            @ptrCast(&event),
        );
        _ = xlib.XSync(self.display, xlib.False);
    }
};
