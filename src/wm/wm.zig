const std = @import("std");
const mem = std.mem;

const display_mod = @import("../x11/display.zig");
const xlib = @import("../x11/xlib.zig");
const atoms_mod = @import("../x11/atoms.zig");
const chord_mod = @import("../keyboard/chord.zig");
const monitor_mod = @import("../monitor.zig");
const client_mod = @import("../client.zig");
const bar_mod = @import("../bar/bar.zig");
const blocks_mod = @import("../bar/blocks/blocks.zig");
const config_mod = @import("../config/config.zig");
const overlay_mod = @import("../overlay.zig");
const animations = @import("../animations.zig");
const tiling = @import("../layouts/tiling.zig");
const monocle = @import("../layouts/monocle.zig");
const floating = @import("../layouts/floating.zig");
const scrolling = @import("../layouts/scrolling.zig");
const grid = @import("../layouts/grid.zig");

pub const core = @import("core.zig");
pub const actions = @import("actions.zig");
pub const handlers = @import("handlers.zig");

const Display = display_mod.Display;
const Atoms = atoms_mod.Atoms;
const ChordState = chord_mod.ChordState;
const Monitor = monitor_mod.Monitor;
const Bar = bar_mod.Bar;
const Config = config_mod.Config;

// Standard ICCCM WM_STATE values used by get_state and set_client_state.
pub const NormalState: c_long = 1;
pub const WithdrawnState: c_long = 0;
pub const IconicState: c_long = 3;
pub const IsViewable: c_int = 2;

pub const Cursors = struct {
    normal: xlib.Cursor,
    resize: xlib.Cursor,
    move: xlib.Cursor,

    pub fn init(display: *Display) Cursors {
        return .{
            .normal = xlib.XCreateFontCursor(display.handle, xlib.XC_left_ptr),
            .resize = xlib.XCreateFontCursor(display.handle, xlib.XC_sizing),
            .move = xlib.XCreateFontCursor(display.handle, xlib.XC_fleur),
        };
    }
};

pub const WindowManager = struct {
    allocator: mem.Allocator,

    /// The connection to the X server.
    display: Display,
    x11_fd: c_int,
    /// Invisible 1×1 window used to satisfy the _NET_SUPPORTING_WM_CHECK
    /// EWMH convention.
    wm_check_window: xlib.Window,

    atoms: Atoms,
    cursors: Cursors,
    /// Cached numlock modifier mask, refreshed before any key/button grab.
    numlock_mask: c_uint,

    config: Config,
    /// Path to the config file that was loaded.
    /// Null if using default config.
    config_path: ?[]const u8,

    /// Head of the linked list of all managed monitors.
    monitors: ?*Monitor,
    /// The monitor that currently has input focus.
    selected_monitor: ?*Monitor,

    /// Head of the linked list of status bars (one per monitor).
    bars: ?*Bar,

    chord: ChordState,

    overlay: ?*overlay_mod.KeybindOverlay,

    scroll_animation: animations.ScrollAnimation,
    animation_config: animations.AnimationConfig,

    running: bool,
    last_motion_monitor: ?*Monitor,

    /// Initialises the window manager
    ///
    /// Returns an error if the display cannot be opened or another WM is
    /// already running.
    pub fn init(allocator: mem.Allocator, config: Config, config_path: ?[]const u8) !WindowManager {
        var display = try Display.open();
        errdefer display.close();

        try display.becomeWindowManager();

        const x11_fd = xlib.XConnectionNumber(display.handle);

        const atoms_result = Atoms.init(display.handle, display.root);
        const cursors = Cursors.init(&display);
        _ = xlib.XDefineCursor(display.handle, display.root, cursors.normal);

        tiling.setDisplay(display.handle);
        tiling.setScreenSize(display.screenWidth(), display.screenHeight());

        var wm = WindowManager{
            .allocator = allocator,
            .display = display,
            .x11_fd = x11_fd,
            .wm_check_window = atoms_result.check_window,
            .atoms = atoms_result.atoms,
            .cursors = cursors,
            .numlock_mask = 0,
            .config = config,
            .config_path = config_path,
            .monitors = null,
            .selected_monitor = null,
            .bars = null,
            .chord = .{},
            .overlay = null,
            .scroll_animation = .{},
            .animation_config = .{ .duration_ms = 150, .easing = .ease_out },
            .running = true,
            .last_motion_monitor = null,
        };

        wm.setupMonitors();
        wm.setupBars();
        wm.setupOverlay();

        return wm;
    }

    /// Release all allocated memory owned by the WM.
    pub fn deinit(self: *WindowManager) void {
        bar_mod.destroyBars(self.bars, self.display.handle);
        self.bars = null;

        if (self.overlay) |o| {
            o.deinit(self.allocator);
            self.overlay = null;
        }

        var mon = self.monitors;
        while (mon) |m| {
            const next = m.next;
            monitor_mod.destroy(self.allocator, m);
            mon = next;
        }
        self.monitors = null;
        self.selected_monitor = null;

        _ = xlib.XDestroyWindow(self.display.handle, self.wm_check_window);

        self.display.close();
        self.config.deinit();
    }

    fn setupMonitors(self: *WindowManager) void {
        if (xlib.XineramaIsActive(self.display.handle) != 0) {
            var screen_count: c_int = 0;
            const screens = xlib.XineramaQueryScreens(self.display.handle, &screen_count);

            if (screen_count > 0 and screens != null) {
                var prev_monitor: ?*Monitor = null;
                var index: usize = 0;

                while (index < @as(usize, @intCast(screen_count))) : (index += 1) {
                    const screen = screens[index];
                    const mon = monitor_mod.create(self.allocator) orelse continue;

                    mon.num = @intCast(index);
                    mon.mon_x = screen.x_org;
                    mon.mon_y = screen.y_org;
                    mon.mon_w = screen.width;
                    mon.mon_h = screen.height;
                    mon.win_x = screen.x_org;
                    mon.win_y = screen.y_org;
                    mon.win_w = screen.width;
                    mon.win_h = screen.height;
                    mon.lt[0] = &tiling.layout;
                    mon.lt[1] = &monocle.layout;
                    mon.lt[2] = &floating.layout;
                    mon.lt[3] = &scrolling.layout;
                    mon.lt[4] = &grid.layout;

                    for (0..10) |i| {
                        mon.pertag.ltidxs[i][0] = mon.lt[0];
                        mon.pertag.ltidxs[i][1] = mon.lt[1];
                        mon.pertag.ltidxs[i][2] = mon.lt[2];
                        mon.pertag.ltidxs[i][3] = mon.lt[3];
                        mon.pertag.ltidxs[i][4] = mon.lt[4];
                    }

                    self.initMonitorGaps(mon);

                    if (prev_monitor) |prev| {
                        prev.next = mon;
                    } else {
                        self.monitors = mon;
                        self.selected_monitor = mon;
                    }
                    prev_monitor = mon;
                }

                _ = xlib.XFree(@ptrCast(screens));
            }
        }

        // Fallback: single monitor covering the full screen.
        if (self.monitors == null) {
            const mon = monitor_mod.create(self.allocator) orelse return;
            mon.num = 0;
            mon.mon_x = 0;
            mon.mon_y = 0;
            mon.mon_w = self.display.screenWidth();
            mon.mon_h = self.display.screenHeight();
            mon.win_x = 0;
            mon.win_y = 0;
            mon.win_w = mon.mon_w;
            mon.win_h = mon.mon_h;
            mon.lt[0] = &tiling.layout;
            mon.lt[1] = &monocle.layout;
            mon.lt[2] = &floating.layout;
            mon.lt[3] = &scrolling.layout;
            mon.lt[4] = &grid.layout;

            for (0..10) |i| {
                mon.pertag.ltidxs[i][0] = mon.lt[0];
                mon.pertag.ltidxs[i][1] = mon.lt[1];
                mon.pertag.ltidxs[i][2] = mon.lt[2];
                mon.pertag.ltidxs[i][3] = mon.lt[3];
                mon.pertag.ltidxs[i][4] = mon.lt[4];
            }

            self.initMonitorGaps(mon);
            self.monitors = mon;
            self.selected_monitor = mon;
        }
    }

    pub fn updateGeom(self: *WindowManager) bool {
        var dirty = false;

        if (xlib.XineramaIsActive(self.display.handle) != 0) {
            var n: usize = 0;
            var m = self.monitors;
            while (m) |mon| : (m = mon.next) n += 1;

            var nn: c_int = 0;
            const info = xlib.XineramaQueryScreens(self.display.handle, &nn);
            if (info == null) return false;
            defer _ = xlib.XFree(@ptrCast(info));

            const new_count: usize = @intCast(nn);

            for (n..new_count) |_| {
                var last = self.monitors;
                while (last) |mon| {
                    if (mon.next == null) break;
                    last = mon.next;
                }
                const new_mon = monitor_mod.create(self.allocator) orelse continue;
                new_mon.lt[0] = &tiling.layout;
                new_mon.lt[1] = &monocle.layout;
                new_mon.lt[2] = &floating.layout;
                new_mon.lt[3] = &scrolling.layout;
                new_mon.lt[4] = &grid.layout;
                for (0..10) |i| {
                    new_mon.pertag.ltidxs[i][0] = new_mon.lt[0];
                    new_mon.pertag.ltidxs[i][1] = new_mon.lt[1];
                    new_mon.pertag.ltidxs[i][2] = new_mon.lt[2];
                    new_mon.pertag.ltidxs[i][3] = new_mon.lt[3];
                    new_mon.pertag.ltidxs[i][4] = new_mon.lt[4];
                }
                if (last) |l| {
                    l.next = new_mon;
                } else {
                    self.monitors = new_mon;
                }
            }

            var i: usize = 0;
            m = self.monitors;
            while (m != null and i < new_count) : (i += 1) {
                const mon = m.?;
                const screen = info[i];
                if (i >= n or
                    screen.x_org != mon.mon_x or screen.y_org != mon.mon_y or
                    screen.width != mon.mon_w or screen.height != mon.mon_h)
                {
                    dirty = true;
                    mon.num = @intCast(i);
                    mon.mon_x = screen.x_org;
                    mon.mon_y = screen.y_org;
                    mon.mon_w = screen.width;
                    mon.mon_h = screen.height;
                    mon.win_x = screen.x_org;
                    mon.win_y = screen.y_org;
                    mon.win_w = screen.width;
                    mon.win_h = screen.height;
                    self.initMonitorGaps(mon);
                }
                m = mon.next;
            }

            for (new_count..n) |_| {
                var last: ?*Monitor = null;
                var iter = self.monitors;
                while (iter) |mon| {
                    if (mon.next == null) {
                        last = mon;
                        break;
                    }
                    iter = mon.next;
                }
                const removed = last orelse continue;

                while (removed.clients) |c| {
                    dirty = true;
                    removed.clients = c.next;
                    client_mod.detachStack(c);
                    c.monitor = self.monitors;
                    client_mod.attachAside(c);
                    client_mod.attachStack(c);
                }

                if (self.selected_monitor == removed) {
                    self.selected_monitor = self.monitors;
                }

                var prev: ?*Monitor = null;
                iter = self.monitors;
                while (iter) |mon| {
                    if (mon == removed) {
                        if (prev) |p| {
                            p.next = removed.next;
                        } else {
                            self.monitors = removed.next;
                        }
                        break;
                    }
                    prev = mon;
                    iter = mon.next;
                }
                monitor_mod.destroy(self.allocator, removed);
            }

            tiling.setScreenSize(info[0].width, info[0].height);
        } else {
            if (self.monitors == null) {
                const mon = monitor_mod.create(self.allocator) orelse return false;
                mon.lt[0] = &tiling.layout;
                mon.lt[1] = &monocle.layout;
                mon.lt[2] = &floating.layout;
                mon.lt[3] = &scrolling.layout;
                mon.lt[4] = &grid.layout;
                self.monitors = mon;
                self.selected_monitor = mon;
            }

            const sw = self.display.screenWidth();
            const sh = self.display.screenHeight();

            if (self.monitors) |mon| {
                if (mon.mon_w != sw or mon.mon_h != sh) {
                    dirty = true;
                    mon.mon_x = 0;
                    mon.mon_y = 0;
                    mon.mon_w = sw;
                    mon.mon_h = sh;
                    mon.win_x = 0;
                    mon.win_y = 0;
                    mon.win_w = sw;
                    mon.win_h = sh;
                    self.initMonitorGaps(mon);
                }
            }

            tiling.setScreenSize(sw, sh);
        }

        if (dirty) {
            self.selected_monitor = self.monitors;
            self.selected_monitor = monitor_mod.windowToMonitor(self, self.display.root);
        }

        return dirty;
    }

    pub fn rebuildBars(self: *WindowManager) void {
        bar_mod.destroyBars(self.bars, self.display.handle);
        self.bars = null;
        self.setupBars();
        self.rebuildBarBlocks();
    }

    fn initMonitorGaps(self: *WindowManager, mon: *Monitor) void {
        const cfg = &self.config;
        const any_gap_nonzero = cfg.gap_inner_h != 0 or cfg.gap_inner_v != 0 or
            cfg.gap_outer_h != 0 or cfg.gap_outer_v != 0;

        mon.smartgaps_enabled = cfg.smartgaps_enabled;

        if (cfg.gaps_enabled and any_gap_nonzero) {
            mon.gap_inner_h = cfg.gap_inner_h;
            mon.gap_inner_v = cfg.gap_inner_v;
            mon.gap_outer_h = cfg.gap_outer_h;
            mon.gap_outer_v = cfg.gap_outer_v;
        } else {
            mon.gap_inner_h = 0;
            mon.gap_inner_v = 0;
            mon.gap_outer_h = 0;
            mon.gap_outer_v = 0;
        }
    }

    pub fn setupBars(self: *WindowManager) void {
        var current_monitor = self.monitors;
        var last_bar: ?*Bar = null;

        while (current_monitor) |monitor| {
            const bar = Bar.create(
                self.allocator,
                self.display.handle,
                self.display.screen,
                monitor,
                self.config,
            ) orelse {
                current_monitor = monitor.next;
                continue;
            };

            if (tiling.bar_height == 0) {
                tiling.setBarHeight(bar.height);
            }

            self.populateBarBlocks(bar);

            if (last_bar) |prev| {
                prev.next = bar;
            } else {
                self.bars = bar;
            }
            last_bar = bar;

            std.debug.print("bar created for monitor {d}\n", .{monitor.num});
            current_monitor = monitor.next;
        }
    }

    pub fn populateBarBlocks(self: *WindowManager, bar: *Bar) void {
        if (self.config.blocks.items.len > 0) {
            for (self.config.blocks.items) |cfg_block| {
                bar.addBlock(configBlockToBarBlock(cfg_block));
            }
        } else {
            bar.addBlock(blocks_mod.Block.initRam("", 5, 0x7aa2f7, true));
            bar.addBlock(blocks_mod.Block.initStatic(" | ", 0x666666, false));
            bar.addBlock(blocks_mod.Block.initDatetime("", "%H:%M", 1, 0x0db9d7, true));
        }
    }

    fn setupOverlay(self: *WindowManager) void {
        self.overlay = overlay_mod.KeybindOverlay.init(
            self.display.handle,
            self.display.screen,
            self.display.root,
            self.config.font,
            self.allocator,
        );
    }

    // Wrap free functions in `bar_mod` with `self.bars` passed in.

    pub fn invalidateBars(self: *WindowManager) void {
        bar_mod.invalidateBars(self.bars);
    }

    pub fn windowToBar(self: *WindowManager, win: xlib.Window) ?*Bar {
        return bar_mod.windowToBar(self.bars, win);
    }

    /// Refreshes the cached numlock modifier bitmask from the X server's
    /// current modifier map. Called before any key or button grab so that
    /// grabs cover all numlock combinations.
    pub fn updateNumlockMask(self: *WindowManager) void {
        self.numlock_mask = 0;
        const modmap = xlib.XGetModifierMapping(self.display.handle);
        if (modmap == null) return;
        defer _ = xlib.XFreeModifiermap(modmap);

        const numlock_keycode = xlib.XKeysymToKeycode(self.display.handle, xlib.XK_Num_Lock);

        var modifier_index: usize = 0;
        while (modifier_index < 8) : (modifier_index += 1) {
            var key_index: usize = 0;
            while (key_index < @as(usize, @intCast(modmap.*.max_keypermod))) : (key_index += 1) {
                const keycode = modmap.*.modifiermap[modifier_index * @as(usize, @intCast(modmap.*.max_keypermod)) + key_index];
                if (keycode == numlock_keycode) {
                    self.numlock_mask = @as(c_uint, 1) << @intCast(modifier_index);
                }
            }
        }
    }

    /// Grabs all configured keybinds and mouse buttons from the X server.
    /// Replaces any existing grabs. Call after config load or reload.
    pub fn grabKeybinds(self: *WindowManager) void {
        self.updateNumlockMask();
        const modifiers = [_]c_uint{ 0, xlib.LockMask, self.numlock_mask, self.numlock_mask | xlib.LockMask };

        _ = xlib.XUngrabKey(self.display.handle, xlib.AnyKey, xlib.AnyModifier, self.display.root);

        for (self.config.keybinds.items) |keybind| {
            if (keybind.key_count == 0) continue;
            const first_key = keybind.keys[0];
            const keycode = xlib.XKeysymToKeycode(self.display.handle, @intCast(first_key.keysym));
            if (keycode != 0) {
                for (modifiers) |modifier| {
                    _ = xlib.XGrabKey(
                        self.display.handle,
                        keycode,
                        first_key.mod_mask | modifier,
                        self.display.root,
                        xlib.True,
                        xlib.GrabModeAsync,
                        xlib.GrabModeAsync,
                    );
                }
            }
        }

        for (self.config.buttons.items) |button| {
            if (button.click == .client_win) {
                for (modifiers) |modifier| {
                    _ = xlib.XGrabButton(
                        self.display.handle,
                        @intCast(button.button),
                        button.mod_mask | modifier,
                        self.display.root,
                        xlib.True,
                        xlib.ButtonPressMask | xlib.ButtonReleaseMask | xlib.PointerMotionMask,
                        xlib.GrabModeAsync,
                        xlib.GrabModeAsync,
                        xlib.None,
                        xlib.None,
                    );
                }
            }
        }

        std.debug.print("grabbed {d} keybinds from config\n", .{self.config.keybinds.items.len});
    }

    pub fn ungrabKeybinds(self: *WindowManager) void {
        _ = xlib.XUngrabKey(self.display.handle, xlib.AnyKey, xlib.AnyModifier, self.display.root);
    }

    /// Walk the existing window tree and call `manageFn` for each window
    /// that should be managed. Non-transient windows are processed first
    /// so transient (dialog) windows can be stacked on top.
    pub fn scanExistingWindows(self: *WindowManager, manageFn: fn (xlib.Window, *xlib.XWindowAttributes, *WindowManager) void) void {
        var root_return: xlib.Window = undefined;
        var parent_return: xlib.Window = undefined;
        var children: [*c]xlib.Window = undefined;
        var num_children: c_uint = undefined;

        if (xlib.XQueryTree(self.display.handle, self.display.root, &root_return, &parent_return, &children, &num_children) == 0) {
            return;
        }

        var index: c_uint = 0;
        while (index < num_children) : (index += 1) {
            var window_attrs: xlib.XWindowAttributes = undefined;
            if (xlib.XGetWindowAttributes(self.display.handle, children[index], &window_attrs) == 0) {
                continue;
            }
            if (window_attrs.override_redirect != 0) continue;

            var trans: xlib.Window = 0;
            if (xlib.XGetTransientForHint(self.display.handle, children[index], &trans) != 0) continue;

            if (window_attrs.map_state == IsViewable or self.getState(children[index]) == IconicState) {
                manageFn(children[index], &window_attrs, self);
            }
        }

        index = 0;
        while (index < num_children) : (index += 1) {
            var window_attrs: xlib.XWindowAttributes = undefined;
            if (xlib.XGetWindowAttributes(self.display.handle, children[index], &window_attrs) == 0) {
                continue;
            }
            var trans: xlib.Window = 0;
            if (xlib.XGetTransientForHint(self.display.handle, children[index], &trans) != 0) {
                if (window_attrs.map_state == IsViewable or self.getState(children[index]) == IconicState) {
                    manageFn(children[index], &window_attrs, self);
                }
            }
        }

        if (children != null) _ = xlib.XFree(@ptrCast(children));
    }

    /// Reads the ICCCM WM_STATE property for a window.
    /// Returns WithdrawnState if the property is absent or malformed.
    pub fn getState(self: *WindowManager, window: xlib.Window) c_long {
        var actual_type: xlib.Atom = 0;
        var actual_format: c_int = 0;
        var num_items: c_ulong = 0;
        var bytes_after: c_ulong = 0;
        var prop: [*c]u8 = null;

        const result = xlib.XGetWindowProperty(
            self.display.handle,
            window,
            self.atoms.wm_state,
            0,
            2,
            xlib.False,
            self.atoms.wm_state,
            &actual_type,
            &actual_format,
            &num_items,
            &bytes_after,
            &prop,
        );

        if (result != 0 or actual_type != self.atoms.wm_state or num_items < 1) {
            if (prop != null) _ = xlib.XFree(prop);
            return WithdrawnState;
        }

        const state: c_long = @as(*c_long, @ptrCast(@alignCast(prop))).*;
        _ = xlib.XFree(prop);
        return state;
    }

    /// Run the event loop until `self.running` is set to false.
    ///
    /// `eventFn` dispatches a single XEvent
    /// `tickFn` is called once per loop iteration to advance animations
    pub fn run(
        self: *WindowManager,
        eventFn: fn (*xlib.XEvent, *WindowManager) void,
        tickFn: fn (*WindowManager) void,
    ) void {
        var fds = [_]std.posix.pollfd{
            .{ .fd = self.x11_fd, .events = std.posix.POLL.IN, .revents = 0 },
        };

        _ = xlib.XSync(self.display.handle, xlib.False);

        while (self.running) {
            while (xlib.XPending(self.display.handle) > 0) {
                var event = self.display.nextEvent();
                eventFn(&event, self);
            }

            tickFn(self);

            var current_bar = self.bars;
            while (current_bar) |bar| {
                bar.updateBlocks();
                bar.draw(self.display.handle, self.config);
                current_bar = bar.next;
            }

            const poll_timeout: i32 = if (self.scroll_animation.isActive()) 16 else 1000;
            _ = std.posix.poll(&fds, poll_timeout) catch 0;
        }
    }

    /// Reloads the configuration
    ///
    /// `loadFn` repopulates `self.config`
    /// keys/buttons are unbound before reload and rebound after
    pub fn reloadConfig(
        self: *WindowManager,
        loadFn: fn (*WindowManager) void,
    ) void {
        std.debug.print("reloading config...\n", .{});

        self.ungrabKeybinds();

        self.config.keybinds.clearRetainingCapacity();
        self.config.buttons.clearRetainingCapacity();
        self.config.rules.clearRetainingCapacity();
        self.config.blocks.clearRetainingCapacity();

        loadFn(self);

        bar_mod.destroyBars(self.bars, self.display.handle);
        self.bars = null;
        self.setupBars();
        self.rebuildBarBlocks();

        self.grabKeybinds();
    }

    fn rebuildBarBlocks(self: *WindowManager) void {
        var current_bar = self.bars;
        while (current_bar) |bar| {
            bar.clearBlocks();
            self.populateBarBlocks(bar);
            current_bar = bar.next;
        }
    }
};

/// Converts a config block description into a live status bar block.
pub fn configBlockToBarBlock(cfg: config_mod.Block) blocks_mod.Block {
    return switch (cfg.block_type) {
        .static => blocks_mod.Block.initStatic(cfg.format, cfg.color, cfg.underline),
        .datetime => blocks_mod.Block.initDatetime(
            cfg.format,
            cfg.datetime_format orelse "%H:%M",
            cfg.interval,
            cfg.color,
            cfg.underline,
        ),
        .ram => blocks_mod.Block.initRam(cfg.format, cfg.interval, cfg.color, cfg.underline),
        .shell => blocks_mod.Block.initShell(
            cfg.format,
            cfg.command orelse "",
            cfg.interval,
            cfg.color,
            cfg.underline,
        ),
        .battery => blocks_mod.Block.initBattery(
            cfg.format_charging orelse "",
            cfg.format_discharging orelse "",
            cfg.format_full orelse "",
            cfg.battery_name orelse "BAT0",
            cfg.interval,
            cfg.color,
            cfg.underline,
        ),
        .cpu_temp => blocks_mod.Block.initCpuTemp(
            cfg.format,
            cfg.thermal_zone orelse "thermal_zone0",
            cfg.interval,
            cfg.color,
            cfg.underline,
        ),
    };
}
