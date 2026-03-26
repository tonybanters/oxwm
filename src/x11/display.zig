const std = @import("std");
const xlib = @import("xlib.zig");

pub const DisplayError = error{
    CannotOpenDisplay,
    AnotherWmRunning,
};

var wm_detected: bool = false;

pub const Display = struct {
    handle: *xlib.Display,
    screen: c_int,
    root: xlib.Window,

    pub fn open() DisplayError!Display {
        const handle = xlib.XOpenDisplay(null) orelse return DisplayError.CannotOpenDisplay;
        const screen = xlib.XDefaultScreen(handle);
        const root = xlib.XRootWindow(handle, screen);

        return Display{
            .handle = handle,
            .screen = screen,
            .root = root,
        };
    }

    pub fn close(self: *Display) void {
        _ = xlib.XCloseDisplay(self.handle);
    }

    pub fn becomeWindowManager(self: *Display) DisplayError!void {
        wm_detected = false;
        _ = xlib.XSetErrorHandler(onWmDetected);
        _ = xlib.XSelectInput(
            self.handle,
            self.root,
            xlib.SubstructureRedirectMask | xlib.SubstructureNotifyMask | xlib.StructureNotifyMask | xlib.ButtonPressMask | xlib.PointerMotionMask | xlib.EnterWindowMask,
        );
        _ = xlib.XSync(self.handle, xlib.False);

        if (wm_detected) {
            return DisplayError.AnotherWmRunning;
        }

        _ = xlib.XSetErrorHandler(onXError);
    }

    pub fn screenWidth(self: *Display) c_int {
        return xlib.XDisplayWidth(self.handle, self.screen);
    }

    pub fn screenHeight(self: *Display) c_int {
        return xlib.XDisplayHeight(self.handle, self.screen);
    }

    pub fn nextEvent(self: *Display) xlib.XEvent {
        var event: xlib.XEvent = undefined;
        _ = xlib.XNextEvent(self.handle, &event);
        return event;
    }

    pub fn pending(self: *Display) c_int {
        return xlib.XPending(self.handle);
    }

    pub fn sync(self: *Display, discard: bool) void {
        _ = xlib.XSync(self.handle, if (discard) xlib.True else xlib.False);
    }

    pub fn grabKey(
        self: *Display,
        keycode: c_int,
        modifiers: c_uint,
    ) void {
        _ = xlib.XGrabKey(
            self.handle,
            keycode,
            modifiers,
            self.root,
            xlib.True,
            xlib.GrabModeAsync,
            xlib.GrabModeAsync,
        );
    }

    pub fn keysymToKeycode(self: *Display, keysym: xlib.KeySym) c_int {
        return @intCast(xlib.XKeysymToKeycode(self.handle, keysym));
    }
};

fn onWmDetected(_: ?*xlib.Display, _: [*c]xlib.XErrorEvent) callconv(.c) c_int {
    wm_detected = true;
    return 0;
}

fn onXError(_: ?*xlib.Display, event: [*c]xlib.XErrorEvent) callconv(.c) c_int {
    std.debug.print("x11 error: request={d} error={d}\n", .{ event.*.request_code, event.*.error_code });
    return 0;
}
