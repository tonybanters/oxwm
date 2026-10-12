const std = @import("std");
const xlib = @import("xlib.zig");

pub const Atoms = struct {
    // ICCCM atoms
    wm_protocols: xlib.Atom,
    wm_delete: xlib.Atom,
    wm_state: xlib.Atom,
    wm_take_focus: xlib.Atom,
    wm_change_state: xlib.Atom,

    // EWHM atoms
    net_supported: xlib.Atom,
    net_wm_name: xlib.Atom,
    net_wm_state: xlib.Atom,
    net_wm_check: xlib.Atom,
    net_wm_state_fullscreen: xlib.Atom,
    net_active_window: xlib.Atom,
    net_wm_window_type: xlib.Atom,
    net_wm_window_type_dialog: xlib.Atom,
    net_client_list: xlib.Atom,

    /// Intern all atoms and set up the EWMH check window on `root`.
    ///
    /// `check_window` is a 1×1 invisible window created solely to satisfy
    /// the _NET_SUPPORTING_WM_CHECK convention. The caller owns it and
    /// should destroy it on shutdown via `XDestroyWindow`.
    pub fn init(display: *xlib.Display, root: xlib.Window) struct {
        atoms: Atoms,
        check_window: xlib.Window,
    } {
        const intern = struct {
            fn call(dpy: *xlib.Display, name: [*:0]const u8) xlib.Atom {
                return xlib.XInternAtom(dpy, name, xlib.False);
            }
        }.call;

        const atoms = Atoms{
            .wm_protocols = intern(display, "WM_PROTOCOLS"),
            .wm_delete = intern(display, "WM_DELETE_WINDOW"),
            .wm_state = intern(display, "WM_STATE"),
            .wm_take_focus = intern(display, "WM_TAKE_FOCUS"),
            .wm_change_state = intern(display, "WM_CHANGE_STATE"),

            .net_supported = intern(display, "_NET_SUPPORTED"),
            .net_wm_name = intern(display, "_NET_WM_NAME"),
            .net_wm_state = intern(display, "_NET_WM_STATE"),
            .net_wm_check = intern(display, "_NET_SUPPORTING_WM_CHECK"),
            .net_wm_state_fullscreen = intern(display, "_NET_WM_STATE_FULLSCREEN"),
            .net_active_window = intern(display, "_NET_ACTIVE_WINDOW"),
            .net_wm_window_type = intern(display, "_NET_WM_WINDOW_TYPE"),
            .net_wm_window_type_dialog = intern(display, "_NET_WM_WINDOW_TYPE_DIALOG"),
            .net_client_list = intern(display, "_NET_CLIENT_LIST"),
        };

        const utf8_string = intern(display, "UTF8_STRING");

        // Create the EWMH check window.
        var check_win = xlib.XCreateSimpleWindow(display, root, 0, 0, 1, 1, 0, 0, 0);

        _ = xlib.XChangeProperty(display, check_win, atoms.net_wm_check, xlib.XA_WINDOW, 32, xlib.PropModeReplace, @ptrCast(&check_win), 1);
        _ = xlib.XChangeProperty(display, check_win, atoms.net_wm_name, utf8_string, 8, xlib.PropModeReplace, "oxwm", 4);
        _ = xlib.XChangeProperty(display, root, atoms.net_wm_check, xlib.XA_WINDOW, 32, xlib.PropModeReplace, @ptrCast(&check_win), 1);

        // Advertise supported EWMH hints on the root window.
        var net_atoms = [_]xlib.Atom{
            atoms.net_supported,
            atoms.net_wm_name,
            atoms.net_wm_state,
            atoms.net_wm_check,
            atoms.net_wm_state_fullscreen,
            atoms.net_active_window,
            atoms.net_wm_window_type,
            atoms.net_wm_window_type_dialog,
            atoms.net_client_list,
        };
        _ = xlib.XChangeProperty(display, root, atoms.net_supported, xlib.XA_ATOM, 32, xlib.PropModeReplace, @ptrCast(&net_atoms), net_atoms.len);

        _ = xlib.XDeleteProperty(display, root, atoms.net_client_list);

        return .{ .atoms = atoms, .check_window = check_win };
    }
};
