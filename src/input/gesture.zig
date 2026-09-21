const std = @import("std");
const build_options = @import("build_options");

pub const enabled = build_options.gestures;

const c = if (enabled) @cImport({
    @cInclude("libinput.h");
    @cInclude("libudev.h");
}) else struct {};

extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn close(fd: c_int) c_int;

pub const Kind = enum {
    begin,
    update,
    end,
};

pub const Event = struct {
    kind: Kind,
    fingers: u32,
    dx: f64 = 0,
    dy: f64 = 0,
    cancelled: bool = false,
};

pub const GestureError = error{
    Disabled,
    UdevFailed,
    ContextFailed,
    SeatFailed,
};

pub const Gestures = if (enabled) LibinputGestures else StubGestures;

fn openRestricted(path: [*c]const u8, flags: c_int, user_data: ?*anyopaque) callconv(.c) c_int {
    _ = user_data;
    const fd = open(path, flags);
    if (fd < 0) return -@as(c_int, @intCast(@intFromEnum(std.posix.errno(fd))));
    return fd;
}

fn closeRestricted(fd: c_int, user_data: ?*anyopaque) callconv(.c) void {
    _ = user_data;
    _ = close(fd);
}

var interface = if (enabled) c.struct_libinput_interface{
    .open_restricted = openRestricted,
    .close_restricted = closeRestricted,
} else {};

/// Reads touchpad swipe gestures straight from libinput so the window
/// manager can react to them even though X11 does not deliver gesture
/// events. Requires read access to `/dev/input`.
const LibinputGestures = struct {
    udev: *c.struct_udev,
    li: *c.struct_libinput,
    fd: c_int,

    /// Opens a libinput context on `seat0` and returns the poll fd to watch.
    pub fn init() GestureError!LibinputGestures {
        const udev = c.udev_new() orelse return GestureError.UdevFailed;
        const li = c.libinput_udev_create_context(&interface, null, udev) orelse {
            _ = c.udev_unref(udev);
            return GestureError.ContextFailed;
        };
        c.libinput_log_set_priority(li, c.LIBINPUT_LOG_PRIORITY_ERROR);
        if (c.libinput_udev_assign_seat(li, "seat0") != 0) {
            _ = c.libinput_unref(li);
            _ = c.udev_unref(udev);
            return GestureError.SeatFailed;
        }
        return LibinputGestures{
            .udev = udev,
            .li = li,
            .fd = c.libinput_get_fd(li),
        };
    }

    pub fn deinit(self: *LibinputGestures) void {
        _ = c.libinput_unref(self.li);
        _ = c.udev_unref(self.udev);
    }

    /// Drains pending libinput events and calls `callback` for every swipe.
    pub fn dispatch(self: *LibinputGestures, context: anytype, comptime callback: fn (@TypeOf(context), Event) void) void {
        if (c.libinput_dispatch(self.li) != 0) return;
        while (c.libinput_get_event(self.li)) |event| {
            defer c.libinput_event_destroy(event);
            const kind: Kind = switch (c.libinput_event_get_type(event)) {
                c.LIBINPUT_EVENT_GESTURE_SWIPE_BEGIN => .begin,
                c.LIBINPUT_EVENT_GESTURE_SWIPE_UPDATE => .update,
                c.LIBINPUT_EVENT_GESTURE_SWIPE_END => .end,
                else => continue,
            };
            const gesture = c.libinput_event_get_gesture_event(event) orelse continue;
            var ev = Event{
                .kind = kind,
                .fingers = @intCast(@max(0, c.libinput_event_gesture_get_finger_count(gesture))),
            };
            switch (kind) {
                .update => {
                    ev.dx = c.libinput_event_gesture_get_dx(gesture);
                    ev.dy = c.libinput_event_gesture_get_dy(gesture);
                },
                .end => ev.cancelled = c.libinput_event_gesture_get_cancelled(gesture) != 0,
                .begin => {},
            }
            callback(context, ev);
        }
    }
};

/// Placeholder used when oxwm is built without libinput (`-Dno_gestures`
/// or a BSD target).
const StubGestures = struct {
    fd: c_int = -1,

    pub fn init() GestureError!StubGestures {
        return GestureError.Disabled;
    }

    pub fn deinit(self: *StubGestures) void {
        _ = self;
    }

    pub fn dispatch(self: *StubGestures, context: anytype, comptime callback: fn (@TypeOf(context), Event) void) void {
        _ = self;
        _ = callback;
    }
};
