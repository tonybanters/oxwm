const std = @import("std");
const VERSION = "v0.11.2";
const display_mod = @import("x11/display.zig");
const events = @import("x11/events.zig");
const xlib = @import("x11/xlib.zig");
const client_mod = @import("client.zig");
const monitor_mod = @import("monitor.zig");
const tiling = @import("layouts/tiling.zig");
const monocle = @import("layouts/monocle.zig");
const floating = @import("layouts/floating.zig");
const scrolling = @import("layouts/scrolling.zig");
const grid = @import("layouts/grid.zig");
const animations = @import("animations.zig");
const bar_mod = @import("bar/bar.zig");
const blocks_mod = @import("bar/blocks/blocks.zig");
const config_mod = @import("config/config.zig");
const lua = @import("config/lua.zig");
const overlay_mod = @import("overlay.zig");

const Display = display_mod.Display;
const Client = client_mod.Client;
const Monitor = monitor_mod.Monitor;

var running: bool = true;
var gpa = std.heap.GeneralPurposeAllocator(.{}){};

var wm_protocols: xlib.Atom = 0;
var wm_delete: xlib.Atom = 0;
var wm_state: xlib.Atom = 0;
var wm_take_focus: xlib.Atom = 0;

var net_supported: xlib.Atom = 0;
var net_wm_name: xlib.Atom = 0;
var net_wm_state: xlib.Atom = 0;
var net_wm_check: xlib.Atom = 0;
var net_wm_state_fullscreen: xlib.Atom = 0;
var net_active_window: xlib.Atom = 0;
var net_wm_window_type: xlib.Atom = 0;
var net_wm_window_type_dialog: xlib.Atom = 0;
var net_client_list: xlib.Atom = 0;

var wm_check_window: xlib.Window = 0;

var border_color_focused: c_ulong = 0x6dade3;
var border_color_unfocused: c_ulong = 0x444444;
var border_width: i32 = 2;
var gap_outer_v: i32 = 5;
var gap_outer_h: i32 = 5;
var gap_inner_h: i32 = 5;
var gap_inner_v: i32 = 5;

var tags: [9][]const u8 = .{ "1", "2", "3", "4", "5", "6", "7", "8", "9" };

var cursor_normal: xlib.Cursor = 0;
var cursor_resize: xlib.Cursor = 0;
var cursor_move: xlib.Cursor = 0;

const NormalState: c_long = 1;
const WithdrawnState: c_long = 0;
const IconicState: c_long = 3;
const IsViewable: c_int = 2;
const snap_distance: i32 = 32;

var numlock_mask: c_uint = 0;

var config: config_mod.Config = undefined;
var display_global: ?*Display = null;
var config_path_global: ?[]const u8 = null;

var scroll_animation: animations.Scroll_Animation = .{};
var animation_config: animations.Animation_Config = .{ .duration_ms = 150, .easing = .ease_out };

var chord_keys: [4]config_mod.Key_Press = [_]config_mod.Key_Press{.{}} ** 4;
var chord_index: u8 = 0;
var chord_timestamp: i64 = 0;
const chord_timeout_ms: i64 = 1000;
var keyboard_grabbed: bool = false;

var keybind_overlay: ?*overlay_mod.Keybind_Overlay = null;

fn print_help() void {
    std.debug.print(
        \\oxwm - A window manager
        \\
        \\USAGE:
        \\    oxwm [OPTIONS]
        \\
        \\OPTIONS:
        \\    --init              Create default config in ~/.config/oxwm/config.lua
        \\    --config <PATH>     Use custom config file
        \\    --validate          Validate config file without starting window manager
        \\    --version           Print version information
        \\    --help              Print this help message
        \\
        \\CONFIG:
        \\    Location: ~/.config/oxwm/config.lua
        \\    Edit the config file and use Mod+Shift+R to reload
        \\    No compilation needed - instant hot-reload!
        \\
        \\FIRST RUN:
        \\    Run 'oxwm --init' to create a config file
        \\    Or just start oxwm and it will create one automatically
        \\
    , .{});
}

fn get_config_path(allocator: std.mem.Allocator) ![]u8 {
    const config_home = std.posix.getenv("XDG_CONFIG_HOME") orelse blk: {
        const home = std.posix.getenv("HOME") orelse return error.CouldNotGetHomeDir;
        break :blk try std.fs.path.join(allocator, &.{ home, ".config" });
    };
    defer if (std.posix.getenv("XDG_CONFIG_HOME") == null) allocator.free(config_home);

    const config_path = try std.fs.path.join(allocator, &.{ config_home, "oxwm", "config.lua" });
    return config_path;
}

fn init_config(allocator: std.mem.Allocator) void {
    const config_path = get_config_path(allocator) catch return;
    defer allocator.free(config_path);

    const template = @embedFile("templates/config.lua");

    if (std.fs.path.dirname(config_path)) |dir_path| {
        var root = std.fs.openDirAbsolute("/", .{}) catch |err| {
            std.debug.print("error: could not open root directory: {}\n", .{err});
            return;
        };
        defer root.close();

        const relative_path = std.mem.trimLeft(u8, dir_path, "/");
        root.makePath(relative_path) catch |err| {
            std.debug.print("error: could not create config directory: {}\n", .{err});
            return;
        };
    }

    const file = std.fs.createFileAbsolute(config_path, .{}) catch |err| {
        std.debug.print("error: could not create config file: {}\n", .{err});
        return;
    };
    defer file.close();

    _ = file.writeAll(template) catch |err| {
        std.debug.print("error: could not write config file: {}\n", .{err});
        return;
    };

    std.debug.print("Config created at {s}\n", .{config_path});
    std.debug.print("Edit the file and reload with Mod+Shift+R\n", .{});
    std.debug.print("No compilation needed - changes take effect immediately!\n", .{});
}

fn validate_config(allocator: std.mem.Allocator, config_path: []const u8) !void {
    config = config_mod.Config.init(allocator);
    defer config.deinit();

    if (!lua.init(&config)) {
        std.debug.print("error: failed to initialize lua\n", .{});
        std.process.exit(1);
    }
    defer lua.deinit();

    _ = std.fs.cwd().statFile(config_path) catch |err| {
        std.debug.print("error: config file not found: {s}\n", .{config_path});
        std.debug.print("  {}\n", .{err});
        std.process.exit(1);
    };

    if (lua.load_file(config_path)) {
        std.debug.print("✓ config valid: {s}\n", .{config_path});
        std.process.exit(0);
    } else {
        std.debug.print("✗ config validation failed\n", .{});
        std.process.exit(1);
    }
}

pub fn main() !void {
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const default_config_path = try get_config_path(allocator);
    defer allocator.free(default_config_path);

    var config_path: []const u8 = default_config_path;
    var validate_mode: bool = false;
    var args = std.process.args();
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--config")) {
            if (args.next()) |path| config_path = path;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            print_help();
            return;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
            std.debug.print("{s}\n", .{VERSION});
            return;
        } else if (std.mem.eql(u8, arg, "--init")) {
            init_config(allocator);
            return;
        } else if (std.mem.eql(u8, arg, "--validate")) {
            validate_mode = true;
        }
    }

    if (validate_mode) {
        try validate_config(allocator, config_path);
        return;
    }

    std.debug.print("oxwm starting\n", .{});

    config = config_mod.Config.init(allocator);
    defer config.deinit();
    config_mod.set_config(&config);

    if (lua.init(&config)) {
        const loaded = if (std.fs.cwd().statFile(config_path)) |_|
            lua.load_file(config_path)
        else |_| blk: {
            init_config(allocator);
            break :blk lua.load_config();
        };

        if (loaded) {
            config_path_global = config_path;
            std.debug.print("loaded config from {s}\n", .{config_path});
            apply_config_values();
        } else {
            std.debug.print("no config found, using defaults\n", .{});
            initialize_default_config();
        }
    } else {
        std.debug.print("failed to init lua, using defaults\n", .{});
        initialize_default_config();
    }

    var display = Display.open() catch |err| {
        std.debug.print("failed to open display: {}\n", .{err});
        return;
    };
    defer display.close();

    display_global = &display;

    std.debug.print("display opened: screen={d} root=0x{x}\n", .{ display.screen, display.root });
    std.debug.print("screen size: {d}x{d}\n", .{ display.screen_width(), display.screen_height() });

    display.become_window_manager() catch |err| {
        std.debug.print("failed to become window manager: {}\n", .{err});
        return;
    };

    std.debug.print("successfully became window manager\n", .{});

    setup_atoms(&display);
    setup_cursors(&display);
    client_mod.init(allocator);
    monitor_mod.init(allocator);
    monitor_mod.set_root_window(display.root, display.handle);
    tiling.set_display(display.handle);
    tiling.set_screen_size(display.screen_width(), display.screen_height());

    setup_monitors(&display);
    setup_bars(allocator, &display);
    setup_overlay(allocator, &display);
    grab_keybinds(&display);
    scan_existing_windows(&display);

    try run_autostart_commands(allocator, config.autostart.items);
    std.debug.print("entering event loop\n", .{});
    run_event_loop(&display);

    bar_mod.destroy_bars(allocator, display.handle);

    var mon = monitor_mod.monitors;
    while (mon) |m| {
        const next = m.next;
        monitor_mod.destroy(m);
        mon = next;
    }

    if (keybind_overlay) |overlay| {
        overlay.deinit(allocator);
    }

    lua.deinit();
    std.debug.print("oxwm exiting\n", .{});
}

fn setup_atoms(display: *Display) void {
    wm_protocols = xlib.XInternAtom(display.handle, "WM_PROTOCOLS", xlib.False);
    wm_delete = xlib.XInternAtom(display.handle, "WM_DELETE_WINDOW", xlib.False);
    wm_state = xlib.XInternAtom(display.handle, "WM_STATE", xlib.False);
    wm_take_focus = xlib.XInternAtom(display.handle, "WM_TAKE_FOCUS", xlib.False);

    net_active_window = xlib.XInternAtom(display.handle, "_NET_ACTIVE_WINDOW", xlib.False);
    net_supported = xlib.XInternAtom(display.handle, "_NET_SUPPORTED", xlib.False);
    net_wm_name = xlib.XInternAtom(display.handle, "_NET_WM_NAME", xlib.False);
    net_wm_state = xlib.XInternAtom(display.handle, "_NET_WM_STATE", xlib.False);
    net_wm_check = xlib.XInternAtom(display.handle, "_NET_SUPPORTING_WM_CHECK", xlib.False);
    net_wm_state_fullscreen = xlib.XInternAtom(display.handle, "_NET_WM_STATE_FULLSCREEN", xlib.False);
    net_wm_window_type = xlib.XInternAtom(display.handle, "_NET_WM_WINDOW_TYPE", xlib.False);
    net_wm_window_type_dialog = xlib.XInternAtom(display.handle, "_NET_WM_WINDOW_TYPE_DIALOG", xlib.False);
    net_client_list = xlib.XInternAtom(display.handle, "_NET_CLIENT_LIST", xlib.False);

    const utf8_string = xlib.XInternAtom(display.handle, "UTF8_STRING", xlib.False);

    wm_check_window = xlib.XCreateSimpleWindow(display.handle, display.root, 0, 0, 1, 1, 0, 0, 0);
    _ = xlib.XChangeProperty(display.handle, wm_check_window, net_wm_check, xlib.XA_WINDOW, 32, xlib.PropModeReplace, @ptrCast(&wm_check_window), 1);
    _ = xlib.XChangeProperty(display.handle, wm_check_window, net_wm_name, utf8_string, 8, xlib.PropModeReplace, "oxwm", 6);
    _ = xlib.XChangeProperty(display.handle, display.root, net_wm_check, xlib.XA_WINDOW, 32, xlib.PropModeReplace, @ptrCast(&wm_check_window), 1);

    var net_atoms = [_]xlib.Atom{ net_supported, net_wm_name, net_wm_state, net_wm_check, net_wm_state_fullscreen, net_active_window, net_wm_window_type, net_wm_window_type_dialog, net_client_list };
    _ = xlib.XChangeProperty(display.handle, display.root, net_supported, xlib.XA_ATOM, 32, xlib.PropModeReplace, @ptrCast(&net_atoms), net_atoms.len);

    _ = xlib.XDeleteProperty(display.handle, display.root, net_client_list);

    std.debug.print("atoms initialized with EWMH support\n", .{});
}

fn setup_cursors(display: *Display) void {
    cursor_normal = xlib.XCreateFontCursor(display.handle, xlib.XC_left_ptr);
    cursor_resize = xlib.XCreateFontCursor(display.handle, xlib.XC_sizing);
    cursor_move = xlib.XCreateFontCursor(display.handle, xlib.XC_fleur);
    _ = xlib.XDefineCursor(display.handle, display.root, cursor_normal);
}

fn setup_bars(allocator: std.mem.Allocator, display: *Display) void {
    var current_monitor = monitor_mod.monitors;
    var last_bar: ?*bar_mod.Bar = null;

    while (current_monitor) |monitor| {
        const bar = bar_mod.Bar.create(allocator, display.handle, display.screen, monitor, config);
        if (bar) |created_bar| {
            if (tiling.bar_height == 0) {
                tiling.set_bar_height(created_bar.height);
            }

            if (config.blocks.items.len > 0) {
                for (config.blocks.items) |cfg_block| {
                    const block = config_block_to_bar_block(cfg_block);
                    created_bar.add_block(block);
                }
            } else {
                created_bar.add_block(blocks_mod.Block.init_ram("", 5, 0x7aa2f7, true));
                created_bar.add_block(blocks_mod.Block.init_static(" | ", 0x666666, false));
                created_bar.add_block(blocks_mod.Block.init_datetime("", "%H:%M", 1, 0x0db9d7, true));
            }

            if (last_bar) |prev| {
                prev.next = created_bar;
            } else {
                bar_mod.bars = created_bar;
            }
            last_bar = created_bar;
            std.debug.print("bar created for monitor {d}\n", .{monitor.num});
        }
        current_monitor = monitor.next;
    }
}

fn setup_overlay(allocator: std.mem.Allocator, display: *Display) void {
    keybind_overlay = overlay_mod.Keybind_Overlay.init(display.handle, display.screen, display.root, config.font, allocator);
}

fn config_block_to_bar_block(cfg: config_mod.Block) blocks_mod.Block {
    return switch (cfg.block_type) {
        .static => blocks_mod.Block.init_static(cfg.format, cfg.color, cfg.underline),
        .datetime => blocks_mod.Block.init_datetime(cfg.format, cfg.datetime_format orelse "%H:%M", cfg.interval, cfg.color, cfg.underline),
        .ram => blocks_mod.Block.init_ram(cfg.format, cfg.interval, cfg.color, cfg.underline),
        .shell => blocks_mod.Block.init_shell(cfg.format, cfg.command orelse "", cfg.interval, cfg.color, cfg.underline),
        .battery => blocks_mod.Block.init_battery(
            cfg.format_charging orelse "",
            cfg.format_discharging orelse "",
            cfg.format_full orelse "",
            cfg.battery_name orelse "BAT0",
            cfg.interval,
            cfg.color,
            if (cfg.color_charging) |c| @as(c_ulong, c) else null,
            if (cfg.color_discharging) |c| @as(c_ulong, c) else null,
            if (cfg.color_full) |c| @as(c_ulong, c) else null,
            cfg.underline,
        ),
        .cpu_temp => blocks_mod.Block.init_cpu_temp(
            cfg.format,
            cfg.thermal_zone orelse "thermal_zone0",
            cfg.interval,
            cfg.color,
            cfg.underline,
        ),
    };
}

fn setup_monitors(display: *Display) void {
    std.debug.print("checking xinerama...\n", .{});
    if (xlib.XineramaIsActive(display.handle) != 0) {
        std.debug.print("xinerama is active!\n", .{});
        var screen_count: c_int = 0;
        const screens = xlib.XineramaQueryScreens(display.handle, &screen_count);

        if (screen_count > 0 and screens != null) {
            var prev_monitor: ?*Monitor = null;
            var index: usize = 0;

            while (index < @as(usize, @intCast(screen_count))) : (index += 1) {
                const screen = screens[index];
                const mon = monitor_mod.create() orelse continue;

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

                init_monitor_gaps(mon);

                if (prev_monitor) |prev| {
                    prev.next = mon;
                } else {
                    monitor_mod.monitors = mon;
                }
                prev_monitor = mon;

                std.debug.print("monitor {d}: {d}x{d} at ({d},{d})\n", .{ index, mon.mon_w, mon.mon_h, mon.mon_x, mon.mon_y });
            }

            monitor_mod.selected_monitor = monitor_mod.monitors;
            _ = xlib.XFree(@ptrCast(screens));
            return;
        }
    } else {
        std.debug.print("xinerama not active, using single monitor\n", .{});
    }

    const mon = monitor_mod.create() orelse return;
    mon.mon_x = 0;
    mon.mon_y = 0;
    mon.mon_w = display.screen_width();
    mon.mon_h = display.screen_height();
    mon.win_x = 0;
    mon.win_y = 0;
    mon.win_w = display.screen_width();
    mon.win_h = display.screen_height();
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

    init_monitor_gaps(mon);

    monitor_mod.monitors = mon;
    monitor_mod.selected_monitor = mon;
    std.debug.print("monitor created: {d}x{d}\n", .{ mon.mon_w, mon.mon_h });
}

fn apply_config_values() void {
    border_color_focused = config.border_focused;
    border_color_unfocused = config.border_unfocused;
    border_width = config.border_width;
    gap_inner_h = config.gap_inner_h;
    gap_inner_v = config.gap_inner_v;
    gap_outer_h = config.gap_outer_h;
    gap_outer_v = config.gap_outer_v;
    tags = config.tags;
}

fn init_monitor_gaps(mon: *Monitor) void {
    const any_gap_nonzero = config.gap_inner_h != 0 or config.gap_inner_v != 0 or
                            config.gap_outer_h != 0 or config.gap_outer_v != 0;

    if (config.gaps_enabled and any_gap_nonzero) {
        mon.gap_inner_h = config.gap_inner_h;
        mon.gap_inner_v = config.gap_inner_v;
        mon.gap_outer_h = config.gap_outer_h;
        mon.gap_outer_v = config.gap_outer_v;
    } else {
        mon.gap_inner_h = 0;
        mon.gap_inner_v = 0;
        mon.gap_outer_h = 0;
        mon.gap_outer_v = 0;
    }
}

fn make_keybind(mod: u32, key: u64, action: config_mod.Action) config_mod.Keybind {
    var kb: config_mod.Keybind = .{ .action = action };
    kb.keys[0] = .{ .mod_mask = mod, .keysym = key };
    kb.key_count = 1;
    return kb;
}

fn make_keybind_int(mod: u32, key: u64, action: config_mod.Action, int_arg: i32) config_mod.Keybind {
    var kb = make_keybind(mod, key, action);
    kb.int_arg = int_arg;
    return kb;
}

fn make_keybind_str(mod: u32, key: u64, action: config_mod.Action, str_arg: []const u8) config_mod.Keybind {
    var kb = make_keybind(mod, key, action);
    kb.str_arg = str_arg;
    return kb;
}

fn initialize_default_config() void {
    const mod_key: u32 = 1 << 6;
    const shift_key: u32 = 1 << 0;
    const control_key: u32 = 1 << 2;

    config.add_keybind(make_keybind(mod_key, 0xff0d, .spawn_terminal)) catch {};
    config.add_keybind(make_keybind_str(mod_key, 'd', .spawn, "rofi -show drun")) catch {};
    config.add_keybind(make_keybind_str(mod_key, 's', .spawn, "maim -s | xclip -selection clipboard -t image/png")) catch {};
    config.add_keybind(make_keybind(mod_key, 'q', .kill_client)) catch {};
    config.add_keybind(make_keybind(mod_key | shift_key, 'q', .quit)) catch {};
    config.add_keybind(make_keybind(mod_key | shift_key, 'r', .reload_config)) catch {};
    config.add_keybind(make_keybind(mod_key, 'j', .focus_next)) catch {};
    config.add_keybind(make_keybind(mod_key, 'k', .focus_prev)) catch {};
    config.add_keybind(make_keybind(mod_key | shift_key, 'j', .move_next)) catch {};
    config.add_keybind(make_keybind(mod_key | shift_key, 'k', .move_prev)) catch {};
    config.add_keybind(make_keybind_int(mod_key, 'h', .resize_master, -50)) catch {};
    config.add_keybind(make_keybind_int(mod_key, 'l', .resize_master, 50)) catch {};
    config.add_keybind(make_keybind(mod_key, 'i', .inc_master)) catch {};
    config.add_keybind(make_keybind(mod_key, 'p', .dec_master)) catch {};
    config.add_keybind(make_keybind(mod_key, 'a', .toggle_gaps)) catch {};
    config.add_keybind(make_keybind(mod_key, 'f', .toggle_fullscreen)) catch {};
    config.add_keybind(make_keybind(mod_key, 0x0020, .toggle_floating)) catch {};
    config.add_keybind(make_keybind(mod_key, 'n', .cycle_layout)) catch {};
    config.add_keybind(make_keybind_int(mod_key, 0x002c, .focus_monitor, -1)) catch {};
    config.add_keybind(make_keybind_int(mod_key, 0x002e, .focus_monitor, 1)) catch {};
    config.add_keybind(make_keybind_int(mod_key | shift_key, 0x002c, .send_to_monitor, -1)) catch {};
    config.add_keybind(make_keybind_int(mod_key | shift_key, 0x002e, .send_to_monitor, 1)) catch {};

    var tag_index: i32 = 0;
    while (tag_index < 9) : (tag_index += 1) {
        const keysym: u64 = @as(u64, '1') + @as(u64, @intCast(tag_index));
        config.add_keybind(make_keybind_int(mod_key, keysym, .view_tag, tag_index)) catch {};
        config.add_keybind(make_keybind_int(mod_key | shift_key, keysym, .move_to_tag, tag_index)) catch {};
        config.add_keybind(make_keybind_int(mod_key | control_key, keysym, .toggle_view_tag, tag_index)) catch {};
        config.add_keybind(make_keybind_int(mod_key | control_key | shift_key, keysym, .toggle_tag, tag_index)) catch {};
    }

    config.add_button(.{ .click = .client_win, .mod_mask = mod_key, .button = 1, .action = .move_mouse }) catch {};
    config.add_button(.{ .click = .client_win, .mod_mask = mod_key, .button = 3, .action = .resize_mouse }) catch {};
}

fn grab_keybinds(display: *Display) void {
    update_numlock_mask(display);
    const modifiers = [_]c_uint{ 0, xlib.LockMask, numlock_mask, numlock_mask | xlib.LockMask };

    _ = xlib.XUngrabKey(display.handle, xlib.AnyKey, xlib.AnyModifier, display.root);

    for (config.keybinds.items) |keybind| {
        if (keybind.key_count == 0) continue;
        const first_key = keybind.keys[0];
        const keycode = xlib.XKeysymToKeycode(display.handle, @intCast(first_key.keysym));
        if (keycode != 0) {
            for (modifiers) |modifier| {
                _ = xlib.XGrabKey(
                    display.handle,
                    keycode,
                    first_key.mod_mask | modifier,
                    display.root,
                    xlib.True,
                    xlib.GrabModeAsync,
                    xlib.GrabModeAsync,
                );
            }
        }
    }

    for (config.buttons.items) |button| {
        if (button.click == .client_win) {
            for (modifiers) |modifier| {
                _ = xlib.XGrabButton(
                    display.handle,
                    @intCast(button.button),
                    button.mod_mask | modifier,
                    display.root,
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

    std.debug.print("grabbed {d} keybinds from config\n", .{config.keybinds.items.len});
}

fn get_state(display: *Display, window: xlib.Window) c_long {
    var actual_type: xlib.Atom = 0;
    var actual_format: c_int = 0;
    var num_items: c_ulong = 0;
    var bytes_after: c_ulong = 0;
    var prop: [*c]u8 = null;

    const result = xlib.XGetWindowProperty(
        display.handle,
        window,
        wm_state,
        0,
        2,
        xlib.False,
        wm_state,
        &actual_type,
        &actual_format,
        &num_items,
        &bytes_after,
        &prop,
    );

    if (result != 0 or actual_type != wm_state or num_items < 1) {
        if (prop != null) {
            _ = xlib.XFree(prop);
        }
        return WithdrawnState;
    }

    const state: c_long = @as(*c_long, @ptrCast(@alignCast(prop))).*;
    _ = xlib.XFree(prop);
    return state;
}

fn scan_existing_windows(display: *Display) void {
    var root_return: xlib.Window = undefined;
    var parent_return: xlib.Window = undefined;
    var children: [*c]xlib.Window = undefined;
    var num_children: c_uint = undefined;

    if (xlib.XQueryTree(display.handle, display.root, &root_return, &parent_return, &children, &num_children) == 0) {
        return;
    }

    var index: c_uint = 0;
    while (index < num_children) : (index += 1) {
        var window_attrs: xlib.XWindowAttributes = undefined;
        if (xlib.XGetWindowAttributes(display.handle, children[index], &window_attrs) == 0) {
            continue;
        }
        if (window_attrs.override_redirect != 0) {
            continue;
        }
        var trans: xlib.Window = 0;
        if (xlib.XGetTransientForHint(display.handle, children[index], &trans) != 0) {
            continue;
        }
        if (window_attrs.map_state == IsViewable or get_state(display, children[index]) == IconicState) {
            manage(display, children[index], &window_attrs);
        }
    }

    index = 0;
    while (index < num_children) : (index += 1) {
        var window_attrs: xlib.XWindowAttributes = undefined;
        if (xlib.XGetWindowAttributes(display.handle, children[index], &window_attrs) == 0) {
            continue;
        }
        var trans: xlib.Window = 0;
        if (xlib.XGetTransientForHint(display.handle, children[index], &trans) != 0) {
            if (window_attrs.map_state == IsViewable or get_state(display, children[index]) == IconicState) {
                manage(display, children[index], &window_attrs);
            }
        }
    }

    if (children != null) {
        _ = xlib.XFree(@ptrCast(children));
    }
}

fn run_event_loop(display: *Display) void {
    const x11_fd = xlib.XConnectionNumber(display.handle);
    var fds = [_]std.posix.pollfd{
        .{ .fd = x11_fd, .events = std.posix.POLL.IN, .revents = 0 },
    };

    _ = xlib.XSync(display.handle, xlib.False);

    while (running) {
        while (xlib.XPending(display.handle) > 0) {
            var event = display.next_event();
            handle_event(display, &event);
        }

        tick_animations();

        var current_bar = bar_mod.bars;
        while (current_bar) |bar| {
            bar.update_blocks();
            bar.draw(display.handle, &tags);
            current_bar = bar.next;
        }

        const poll_timeout: i32 = if (scroll_animation.is_active()) 16 else 1000;
        _ = std.posix.poll(&fds, poll_timeout) catch 0;
    }
}

fn handle_event(display: *Display, event: *xlib.XEvent) void {
    const event_type = events.get_event_type(event);

    if (event_type == .button_press) {
        std.debug.print("EVENT: button_press received type={d}\n", .{event.type});
    }

    switch (event_type) {
        .map_request => handle_map_request(display, &event.xmaprequest),
        .configure_request => handle_configure_request(display, &event.xconfigurerequest),
        .key_press => handle_key_press(display, &event.xkey),
        .destroy_notify => handle_destroy_notify(display, &event.xdestroywindow),
        .unmap_notify => handle_unmap_notify(display, &event.xunmap),
        .enter_notify => handle_enter_notify(display, &event.xcrossing),
        .focus_in => handle_focus_in(display, &event.xfocus),
        .motion_notify => handle_motion_notify(display, &event.xmotion),
        .client_message => handle_client_message(display, &event.xclient),
        .button_press => handle_button_press(display, &event.xbutton),
        .expose => handle_expose(display, &event.xexpose),
        .property_notify => handle_property_notify(display, &event.xproperty),
        else => {},
    }
}

fn handle_map_request(display: *Display, event: *xlib.XMapRequestEvent) void {
    std.debug.print("map_request: window=0x{x}\n", .{event.window});

    var window_attributes: xlib.XWindowAttributes = undefined;
    if (xlib.XGetWindowAttributes(display.handle, event.window, &window_attributes) == 0) {
        return;
    }
    if (window_attributes.override_redirect != 0) {
        return;
    }
    if (client_mod.window_to_client(event.window) != null) {
        return;
    }

    manage(display, event.window, &window_attributes);
}

fn manage(display: *Display, win: xlib.Window, window_attrs: *xlib.XWindowAttributes) void {
    const client = client_mod.create(win) orelse return;
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
    client.border_width = border_width;

    update_title(display, client);

    if (xlib.XGetTransientForHint(display.handle, win, &trans) != 0) {
        if (client_mod.window_to_client(trans)) |transient_client| {
            client.monitor = transient_client.monitor;
            client.tags = transient_client.tags;
        }
    }

    if (client.monitor == null) {
        client.monitor = monitor_mod.selected_monitor;
        apply_rules(display, client);
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

    _ = xlib.XSetWindowBorderWidth(display.handle, win, @intCast(client.border_width));
    _ = xlib.XSetWindowBorder(display.handle, win, border_color_unfocused);
    tiling.send_configure(client);

    update_window_type(display, client);
    update_size_hints(display, client);
    update_wm_hints(display, client);

    _ = xlib.XSelectInput(
        display.handle,
        win,
        xlib.EnterWindowMask | xlib.FocusChangeMask | xlib.PropertyChangeMask | xlib.StructureNotifyMask,
    );
    grabbuttons(display, client, false);

    if (!client.is_floating) {
        client.is_floating = trans != 0 or client.is_fixed;
        client.old_state = client.is_floating;
    }
    if (client.is_floating) {
        _ = xlib.XRaiseWindow(display.handle, client.window);
    }

    client_mod.attach_aside(client);
    client_mod.attach_stack(client);

    _ = xlib.XChangeProperty(display.handle, display.root, net_client_list, xlib.XA_WINDOW, 32, xlib.PropModeAppend, @ptrCast(&client.window), 1);
    _ = xlib.XMoveResizeWindow(display.handle, client.window, client.x + 2 * display.screen_width(), client.y, @intCast(client.width), @intCast(client.height));
    set_client_state(display, client, NormalState);

    if (client.monitor == monitor_mod.selected_monitor) {
        const selmon = monitor_mod.selected_monitor orelse return;
        unfocus_client(display, selmon.sel, false);
    }
    monitor.sel = client;

    if (is_scrolling_layout(monitor)) {
        monitor.scroll_offset = 0;
    }

    arrange(monitor);
    _ = xlib.XMapWindow(display.handle, win);
    focus(display, null);
}

fn handle_configure_request(display: *Display, event: *xlib.XConfigureRequestEvent) void {
    const client = client_mod.window_to_client(event.window);

    if (client) |managed_client| {
        if ((event.value_mask & xlib.c.CWBorderWidth) != 0) {
            managed_client.border_width = event.border_width;
        } else if (managed_client.is_floating or (managed_client.monitor != null and managed_client.monitor.?.lt[managed_client.monitor.?.sel_lt] == null)) {
            const monitor = managed_client.monitor orelse return;
            if ((event.value_mask & xlib.c.CWX) != 0) {
                managed_client.old_x = managed_client.x;
                managed_client.x = monitor.mon_x + event.x;
            }
            if ((event.value_mask & xlib.c.CWY) != 0) {
                managed_client.old_y = managed_client.y;
                managed_client.y = monitor.mon_y + event.y;
            }
            if ((event.value_mask & xlib.c.CWWidth) != 0) {
                managed_client.old_width = managed_client.width;
                managed_client.width = event.width;
            }
            if ((event.value_mask & xlib.c.CWHeight) != 0) {
                managed_client.old_height = managed_client.height;
                managed_client.height = event.height;
            }
            const client_full_width = managed_client.width + managed_client.border_width * 2;
            const client_full_height = managed_client.height + managed_client.border_width * 2;
            if ((managed_client.x + managed_client.width) > monitor.mon_x + monitor.mon_w and managed_client.is_floating) {
                managed_client.x = monitor.mon_x + @divTrunc(monitor.mon_w, 2) - @divTrunc(client_full_width, 2);
            }
            if ((managed_client.y + managed_client.height) > monitor.mon_y + monitor.mon_h and managed_client.is_floating) {
                managed_client.y = monitor.mon_y + @divTrunc(monitor.mon_h, 2) - @divTrunc(client_full_height, 2);
            }
            if (((event.value_mask & (xlib.c.CWX | xlib.c.CWY)) != 0) and ((event.value_mask & (xlib.c.CWWidth | xlib.c.CWHeight)) == 0)) {
                tiling.send_configure(managed_client);
            }
            if (client_mod.is_visible(managed_client)) {
                _ = xlib.XMoveResizeWindow(display.handle, managed_client.window, managed_client.x, managed_client.y, @intCast(managed_client.width), @intCast(managed_client.height));
            }
        } else {
            tiling.send_configure(managed_client);
        }
    } else {
        var changes: xlib.XWindowChanges = undefined;
        changes.x = event.x;
        changes.y = event.y;
        changes.width = event.width;
        changes.height = event.height;
        changes.border_width = event.border_width;
        changes.sibling = event.above;
        changes.stack_mode = event.detail;
        _ = xlib.XConfigureWindow(display.handle, event.window, @intCast(event.value_mask), &changes);
    }
    _ = xlib.XSync(display.handle, xlib.False);
}

fn reset_chord_state() void {
    chord_index = 0;
    chord_keys = [_]config_mod.Key_Press{.{}} ** 4;
    chord_timestamp = 0;
    if (keyboard_grabbed) {
        if (display_global) |dsp| {
            _ = xlib.XUngrabKeyboard(dsp.handle, xlib.CurrentTime);
        }
        keyboard_grabbed = false;
    }
}

fn handle_key_press(display: *Display, event: *xlib.XKeyEvent) void {
    const keysym = xlib.XKeycodeToKeysym(display.handle, @intCast(event.keycode), 0);

    if (keybind_overlay) |overlay| {
        if (overlay.handle_key(keysym)) {
            return;
        }
    }

    const clean_state = event.state & ~@as(c_uint, xlib.LockMask | xlib.Mod2Mask);
    const current_time = std.time.milliTimestamp();

    if (chord_index > 0 and (current_time - chord_timestamp) > chord_timeout_ms) {
        reset_chord_state();
    }

    chord_keys[chord_index] = .{ .mod_mask = clean_state, .keysym = keysym };
    chord_index += 1;
    chord_timestamp = current_time;

    for (config.keybinds.items) |keybind| {
        if (keybind.key_count == 0) continue;

        if (keybind.key_count == chord_index) {
            var matches = true;
            var i: u8 = 0;
            while (i < keybind.key_count) : (i += 1) {
                if (chord_keys[i].keysym != keybind.keys[i].keysym or
                    chord_keys[i].mod_mask != keybind.keys[i].mod_mask)
                {
                    matches = false;
                    break;
                }
            }
            if (matches) {
                execute_action(display, keybind.action, keybind.int_arg, keybind.str_arg);
                reset_chord_state();
                return;
            }
        }
    }

    var has_partial_match = false;
    for (config.keybinds.items) |keybind| {
        if (keybind.key_count > chord_index) {
            var matches = true;
            var i: u8 = 0;
            while (i < chord_index) : (i += 1) {
                if (chord_keys[i].keysym != keybind.keys[i].keysym or
                    chord_keys[i].mod_mask != keybind.keys[i].mod_mask)
                {
                    matches = false;
                    break;
                }
            }
            if (matches) {
                has_partial_match = true;
                break;
            }
        }
    }

    if (has_partial_match and !keyboard_grabbed) {
        const grab_result = xlib.XGrabKeyboard(
            display.handle,
            display.root,
            xlib.True,
            xlib.GrabModeAsync,
            xlib.GrabModeAsync,
            xlib.CurrentTime,
        );
        if (grab_result == xlib.GrabSuccess) {
            keyboard_grabbed = true;
        }
    } else if (!has_partial_match) {
        reset_chord_state();
    }
}

fn execute_action(display: *Display, action: config_mod.Action, int_arg: i32, str_arg: ?[]const u8) void {
    switch (action) {
        .spawn_terminal => spawn_terminal(),
        .spawn => {
            if (str_arg) |cmd| {
                spawn_command(cmd);
            }
        },
        .kill_client => kill_focused(display),
        .quit => {
            std.debug.print("quit keybind pressed\n", .{});
            running = false;
        },
        .reload_config => reload_config(display),
        .restart => reload_config(display),
        .show_keybinds => {
            if (keybind_overlay) |overlay| {
                const mon = monitor_mod.selected_monitor orelse monitor_mod.monitors;
                if (mon) |m| {
                    overlay.toggle(m.mon_x, m.mon_y, m.mon_w, m.mon_h);
                }
            }
        },
        .focus_next => focusstack(display, 1),
        .focus_prev => focusstack(display, -1),
        .move_next => movestack(display, 1),
        .move_prev => movestack(display, -1),
        .resize_master => setmfact(@as(f32, @floatFromInt(int_arg)) / 1000.0),
        .inc_master => incnmaster(1),
        .dec_master => incnmaster(-1),
        .toggle_floating => toggle_floating(display),
        .toggle_fullscreen => toggle_fullscreen(display),
        .toggle_gaps => toggle_gaps(),
        .cycle_layout => cycle_layout(),
        .set_layout => set_layout(str_arg),
        .set_layout_tiling => set_layout_index(0),
        .set_layout_floating => set_layout_index(2),
        .view_tag => {
            const tag_mask: u32 = @as(u32, 1) << @intCast(int_arg);
            view(display, tag_mask);
        },
        .view_next_tag => view_adjacent_tag(display, 1),
        .view_prev_tag => view_adjacent_tag(display, -1),
        .view_next_nonempty_tag => view_adjacent_nonempty_tag(display, 1),
        .view_prev_nonempty_tag => view_adjacent_nonempty_tag(display, -1),
        .move_to_tag => {
            const tag_mask: u32 = @as(u32, 1) << @intCast(int_arg);
            tag_client(display, tag_mask);
        },
        .toggle_view_tag => {
            const tag_mask: u32 = @as(u32, 1) << @intCast(int_arg);
            toggle_view(display, tag_mask);
        },
        .toggle_tag => {
            const tag_mask: u32 = @as(u32, 1) << @intCast(int_arg);
            toggle_client_tag(display, tag_mask);
        },
        .focus_monitor => focusmon(display, int_arg),
        .send_to_monitor => sendmon(display, int_arg),
        .scroll_left => {
            scroll_layout(-1);
        },
        .scroll_right => {
            scroll_layout(1);
        },
    }
}

fn reload_config(display: *Display) void {
    std.debug.print("reloading config...\n", .{});

    ungrab_keybinds(display);

    config.keybinds.clearRetainingCapacity();
    config.buttons.clearRetainingCapacity();
    config.rules.clearRetainingCapacity();
    config.blocks.clearRetainingCapacity();

    lua.deinit();
    _ = lua.init(&config);

    const loaded = if (config_path_global) |path|
        lua.load_file(path)
    else
        lua.load_config();

    if (loaded) {
        if (config_path_global) |path| {
            std.debug.print("reloaded config from {s}\n", .{path});
        } else {
            std.debug.print("reloaded config from ~/.config/oxwm/config.lua\n", .{});
        }
        apply_config_values();
    } else {
        std.debug.print("reload failed, restoring defaults\n", .{});
        initialize_default_config();
    }

    bar_mod.destroy_bars(gpa.allocator(), display.handle);
    setup_bars(gpa.allocator(), display);
    rebuild_bar_blocks();

    grab_keybinds(display);
}

fn rebuild_bar_blocks() void {
    var current_bar = bar_mod.bars;
    while (current_bar) |bar| {
        bar.clear_blocks();
        if (config.blocks.items.len > 0) {
            for (config.blocks.items) |cfg_block| {
                const block = config_block_to_bar_block(cfg_block);
                bar.add_block(block);
            }
        } else {
            bar.add_block(blocks_mod.Block.init_ram("", 5, 0x7aa2f7, true));
            bar.add_block(blocks_mod.Block.init_static(" | ", 0x666666, false));
            bar.add_block(blocks_mod.Block.init_datetime("", "%H:%M", 1, 0x0db9d7, true));
        }
        current_bar = bar.next;
    }
}

fn ungrab_keybinds(display: *Display) void {
    _ = xlib.XUngrabKey(display.handle, xlib.AnyKey, xlib.AnyModifier, display.root);
}

fn spawn_child_setup() void {
    _ = std.c.setsid();
    if (display_global) |display| {
        const display_fd = xlib.XConnectionNumber(display.handle);
        std.posix.close(@intCast(display_fd));
    }
    const sigchld_handler = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = std.mem.zeroes(std.posix.sigset_t),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.CHLD, &sigchld_handler, null);
}

fn spawn_command(cmd: []const u8) void {
    std.debug.print("running cmd: {s}\n", .{cmd});
    const pid = std.posix.fork() catch return;
    if (pid == 0) {
        spawn_child_setup();
        var cmd_buf: [1024]u8 = undefined;
        if (cmd.len >= cmd_buf.len) {
            std.posix.exit(1);
        }
        @memcpy(cmd_buf[0..cmd.len], cmd);
        cmd_buf[cmd.len] = 0;
        const argv = [_:null]?[*:0]const u8{ "sh", "-c", @ptrCast(&cmd_buf) };
        _ = std.posix.execvpeZ("sh", &argv, std.c.environ) catch {};
        std.posix.exit(1);
    }
}

fn spawn_terminal() void {
    const pid = std.posix.fork() catch return;
    if (pid == 0) {
        spawn_child_setup();
        var term_buf: [256]u8 = undefined;
        const terminal = config.terminal;
        if (terminal.len >= term_buf.len) {
            std.posix.exit(1);
        }
        @memcpy(term_buf[0..terminal.len], terminal);
        term_buf[terminal.len] = 0;
        const term_ptr: [*:0]const u8 = @ptrCast(&term_buf);
        const argv = [_:null]?[*:0]const u8{term_ptr};
        _ = std.posix.execvpeZ(term_ptr, &argv, std.c.environ) catch {};
        std.posix.exit(1);
    }
}

fn movestack(display: *Display, direction: i32) void {
    const monitor = monitor_mod.selected_monitor orelse return;
    const current = monitor.sel orelse return;

    if (current.is_floating) {
        return;
    }

    var target: ?*Client = null;

    if (direction > 0) {
        target = current.next;
        while (target) |client| {
            if (client_mod.is_visible(client) and !client.is_floating) {
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
                if (client_mod.is_visible(client) and !client.is_floating) {
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
            if (client_mod.is_visible(client) and !client.is_floating) {
                prev = client;
            }
            iter = client.next;
        }
        if (prev == null) {
            iter = current.next;
            while (iter) |client| {
                if (client_mod.is_visible(client) and !client.is_floating) {
                    prev = client;
                }
                iter = client.next;
            }
        }
        target = prev;
    }

    if (target) |swap_client| {
        if (swap_client != current) {
            client_mod.swap_clients(current, swap_client);
            arrange(monitor);
            focus(display, current);
        }
    }
}

fn toggle_view(display: *Display, tag_mask: u32) void {
    const monitor = monitor_mod.selected_monitor orelse return;
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
            while (i < 9) : (i += 1) {
                if ((new_tags & (@as(u32, 1) << @intCast(i))) != 0) break;
            }
            monitor.pertag.curtag = i + 1;
        }

        monitor.nmaster = monitor.pertag.nmasters[monitor.pertag.curtag];
        monitor.mfact = monitor.pertag.mfacts[monitor.pertag.curtag];
        monitor.sel_lt = monitor.pertag.sellts[monitor.pertag.curtag];

        focus_top_client(display, monitor);
        arrange(monitor);
        bar_mod.invalidate_bars();
    }
}

fn toggle_client_tag(display: *Display, tag_mask: u32) void {
    const monitor = monitor_mod.selected_monitor orelse return;
    const client = monitor.sel orelse return;
    const new_tags = client.tags ^ tag_mask;
    if (new_tags != 0) {
        client.tags = new_tags;
        focus_top_client(display, monitor);
        arrange(monitor);
        bar_mod.invalidate_bars();
    }
}

fn toggle_gaps() void {
    const monitor = monitor_mod.selected_monitor orelse return;
    if (monitor.gap_inner_h == 0) {
        monitor.gap_inner_h = gap_inner_v;
        monitor.gap_inner_v = gap_inner_v;
        monitor.gap_outer_h = gap_outer_h;
        monitor.gap_outer_v = gap_outer_v;
    } else {
        monitor.gap_inner_h = 0;
        monitor.gap_inner_v = 0;
        monitor.gap_outer_h = 0;
        monitor.gap_outer_v = 0;
    }
    arrange(monitor);
}

fn kill_focused(display: *Display) void {
    const selected = monitor_mod.selected_monitor orelse return;
    const client = selected.sel orelse return;
    std.debug.print("killing window: 0x{x}\n", .{client.window});

    if (!send_event(display, client, wm_delete)) {
        _ = xlib.XGrabServer(display.handle);
        _ = xlib.XKillClient(display.handle, client.window);
        _ = xlib.XSync(display.handle, xlib.False);
        _ = xlib.XUngrabServer(display.handle);
    }
}

fn toggle_fullscreen(display: *Display) void {
    const selected = monitor_mod.selected_monitor orelse return;
    const client = selected.sel orelse return;
    set_fullscreen(display, client, !client.is_fullscreen);
}

fn set_fullscreen(display: *Display, client: *Client, fullscreen: bool) void {
    const monitor = client.monitor orelse return;

    if (fullscreen and !client.is_fullscreen) {
        var fullscreen_atom = net_wm_state_fullscreen;
        _ = xlib.XChangeProperty(
            display.handle,
            client.window,
            net_wm_state,
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

        _ = xlib.XSetWindowBorderWidth(display.handle, client.window, 0);
        tiling.resize_client(client, monitor.mon_x, monitor.mon_y, monitor.mon_w, monitor.mon_h);
        _ = xlib.XRaiseWindow(display.handle, client.window);

        std.debug.print("fullscreen enabled: window=0x{x}\n", .{client.window});
    } else if (!fullscreen and client.is_fullscreen) {
        var no_atom: xlib.Atom = 0;
        _ = xlib.XChangeProperty(
            display.handle,
            client.window,
            net_wm_state,
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

        tiling.resize_client(client, client.x, client.y, client.width, client.height);
        arrange(monitor);

        std.debug.print("fullscreen disabled: window=0x{x}\n", .{client.window});
    }
}

fn view(display: *Display, tag_mask: u32) void {
    const monitor = monitor_mod.selected_monitor orelse return;
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

    focus_top_client(display, monitor);
    arrange(monitor);
    bar_mod.invalidate_bars();
    std.debug.print("view: tag_mask={d}\n", .{monitor.tagset[monitor.sel_tags]});
}

fn view_adjacent_tag(display: *Display, direction: i32) void {
    const monitor = monitor_mod.selected_monitor orelse return;
    const current_tag = monitor.pertag.curtag;
    var new_tag: i32 = @intCast(current_tag);

    new_tag += direction;
    if (new_tag < 1) new_tag = 9;
    if (new_tag > 9) new_tag = 1;

    const tag_mask: u32 = @as(u32, 1) << @intCast(new_tag - 1);
    view(display, tag_mask);
}

fn view_adjacent_nonempty_tag(display: *Display, direction: i32) void {
    const monitor = monitor_mod.selected_monitor orelse return;
    const current_tag = monitor.pertag.curtag;
    var new_tag: i32 = @intCast(current_tag);

    var attempts: i32 = 0;
    while (attempts < 9) : (attempts += 1) {
        new_tag += direction;
        if (new_tag < 1) new_tag = 9;
        if (new_tag > 9) new_tag = 1;

        const tag_mask: u32 = @as(u32, 1) << @intCast(new_tag - 1);
        if (has_clients_on_tag(monitor, tag_mask)) {
            view(display, tag_mask);
            return;
        }
    }
}

fn has_clients_on_tag(monitor: *monitor_mod.Monitor, tag_mask: u32) bool {
    var client = monitor.clients;
    while (client) |c| {
        if ((c.tags & tag_mask) != 0) {
            return true;
        }
        client = c.next;
    }
    return false;
}

fn tag_client(display: *Display, tag_mask: u32) void {
    const monitor = monitor_mod.selected_monitor orelse return;
    const client = monitor.sel orelse return;
    if (tag_mask == 0) {
        return;
    }
    client.tags = tag_mask;
    focus_top_client(display, monitor);
    arrange(monitor);
    bar_mod.invalidate_bars();
    std.debug.print("tag_client: window=0x{x} tag_mask={d}\n", .{ client.window, tag_mask });
}

fn focus_top_client(display: *Display, monitor: *Monitor) void {
    var visible_client = monitor.stack;
    while (visible_client) |client| {
        if (client_mod.is_visible(client)) {
            focus(display, client);
            return;
        }
        visible_client = client.stack_next;
    }
    monitor.sel = null;
    _ = xlib.XSetInputFocus(display.handle, display.root, xlib.RevertToPointerRoot, xlib.CurrentTime);
}

fn focusstack(display: *Display, direction: i32) void {
    const monitor = monitor_mod.selected_monitor orelse return;
    const current = monitor.sel orelse return;

    var next_client: ?*Client = null;

    if (direction > 0) {
        next_client = current.next;
        while (next_client) |client| {
            if (client_mod.is_visible(client)) {
                break;
            }
            next_client = client.next;
        }
        if (next_client == null) {
            next_client = monitor.clients;
            while (next_client) |client| {
                if (client_mod.is_visible(client)) {
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
            if (client_mod.is_visible(client)) {
                prev = client;
            }
            iter = client.next;
        }
        if (prev == null) {
            iter = current.next;
            while (iter) |client| {
                if (client_mod.is_visible(client)) {
                    prev = client;
                }
                iter = client.next;
            }
        }
        next_client = prev;
    }

    if (next_client) |client| {
        focus(display, client);
        if (client.monitor) |client_monitor| {
            restack(display, client_monitor);
        }
    }
}

fn toggle_floating(_: *Display) void {
    const monitor = monitor_mod.selected_monitor orelse return;
    const client = monitor.sel orelse return;

    if (client.is_fullscreen) {
        return;
    }

    client.is_floating = !client.is_floating;

    if (client.is_floating) {
        tiling.resize(client, client.x, client.y, client.width, client.height, false);
    }

    arrange(monitor);
    std.debug.print("toggle_floating: window=0x{x} floating={}\n", .{ client.window, client.is_floating });
}

fn incnmaster(delta: i32) void {
    const monitor = monitor_mod.selected_monitor orelse return;
    const new_val = @max(0, monitor.nmaster + delta);
    monitor.nmaster = new_val;
    monitor.pertag.nmasters[monitor.pertag.curtag] = new_val;
    arrange(monitor);
    std.debug.print("incnmaster: nmaster={d}\n", .{monitor.nmaster});
}

fn setmfact(delta: f32) void {
    const monitor = monitor_mod.selected_monitor orelse return;
    const new_mfact = monitor.mfact + delta;
    if (new_mfact < 0.05 or new_mfact > 0.95) {
        return;
    }
    monitor.mfact = new_mfact;
    monitor.pertag.mfacts[monitor.pertag.curtag] = new_mfact;
    arrange(monitor);
    std.debug.print("setmfact: mfact={d:.2}\n", .{monitor.mfact});
}

fn cycle_layout() void {
    const monitor = monitor_mod.selected_monitor orelse return;
    const new_lt = (monitor.sel_lt + 1) % 5;
    monitor.sel_lt = new_lt;
    monitor.pertag.sellts[monitor.pertag.curtag] = new_lt;
    if (new_lt != 3) {
        monitor.scroll_offset = 0;
    }
    arrange(monitor);
    bar_mod.invalidate_bars();
    if (monitor.lt[monitor.sel_lt]) |layout| {
        std.debug.print("cycle_layout: {s}\n", .{layout.symbol});
    }
}

fn set_layout(layout_name: ?[]const u8) void {
    const monitor = monitor_mod.selected_monitor orelse return;
    const name = layout_name orelse return;

    const new_lt: u32 = if (std.mem.eql(u8, name, "tiling") or std.mem.eql(u8, name, "[]="))
        0
    else if (std.mem.eql(u8, name, "monocle") or std.mem.eql(u8, name, "[M]"))
        1
    else if (std.mem.eql(u8, name, "floating") or std.mem.eql(u8, name, "><>"))
        2
    else if (std.mem.eql(u8, name, "scrolling") or std.mem.eql(u8, name, "[S]"))
        3
    else if (std.mem.eql(u8, name, "grid") or std.mem.eql(u8, name, "[#]"))
        4
    else {
        std.debug.print("set_layout: unknown layout '{s}'\n", .{name});
        return;
    };

    monitor.sel_lt = new_lt;
    monitor.pertag.sellts[monitor.pertag.curtag] = new_lt;
    if (new_lt != 3) {
        monitor.scroll_offset = 0;
    }
    arrange(monitor);
    bar_mod.invalidate_bars();
    if (monitor.lt[monitor.sel_lt]) |layout| {
        std.debug.print("set_layout: {s}\n", .{layout.symbol});
    }
}

fn set_layout_index(index: u32) void {
    const monitor = monitor_mod.selected_monitor orelse return;
    monitor.sel_lt = index;
    monitor.pertag.sellts[monitor.pertag.curtag] = index;
    if (index != 3) {
        monitor.scroll_offset = 0;
    }
    arrange(monitor);
    bar_mod.invalidate_bars();
    if (monitor.lt[monitor.sel_lt]) |layout| {
        std.debug.print("set_layout_index: {s}\n", .{layout.symbol});
    }
}

fn focusmon(display: *Display, direction: i32) void {
    const selmon = monitor_mod.selected_monitor orelse return;
    const target = monitor_mod.dir_to_monitor(direction) orelse return;
    if (target == selmon) {
        return;
    }
    unfocus_client(display, selmon.sel, false);
    monitor_mod.selected_monitor = target;
    focus(display, null);
    std.debug.print("focusmon: monitor {d}\n", .{target.num});
}

fn sendmon(display: *Display, direction: i32) void {
    const source_monitor = monitor_mod.selected_monitor orelse return;
    const client = source_monitor.sel orelse return;
    const target = monitor_mod.dir_to_monitor(direction) orelse return;

    if (target == source_monitor) {
        return;
    }

    client_mod.detach(client);
    client_mod.detach_stack(client);
    client.monitor = target;
    client.tags = target.tagset[target.sel_tags];
    client_mod.attach_aside(client);
    client_mod.attach_stack(client);

    focus_top_client(display, source_monitor);
    arrange(source_monitor);
    arrange(target);

    std.debug.print("sendmon: window=0x{x} to monitor {d}\n", .{ client.window, target.num });
}

fn snap_x(client: *Client, new_x: i32, monitor: *Monitor) i32 {
    const client_width = client.width + 2 * client.border_width;
    if (@abs(monitor.win_x - new_x) < snap_distance) {
        return monitor.win_x;
    } else if (@abs((monitor.win_x + monitor.win_w) - (new_x + client_width)) < snap_distance) {
        return monitor.win_x + monitor.win_w - client_width;
    }
    return new_x;
}

fn snap_y(client: *Client, new_y: i32, monitor: *Monitor) i32 {
    const client_height = client.height + 2 * client.border_width;
    if (@abs(monitor.win_y - new_y) < snap_distance) {
        return monitor.win_y;
    } else if (@abs((monitor.win_y + monitor.win_h) - (new_y + client_height)) < snap_distance) {
        return monitor.win_y + monitor.win_h - client_height;
    }
    return new_y;
}

fn movemouse(display: *Display) void {
    const monitor = monitor_mod.selected_monitor orelse return;
    const client = monitor.sel orelse return;

    if (client.is_fullscreen) {
        return;
    }

    restack(display, monitor);

    const was_floating = client.is_floating;
    if (!client.is_floating) {
        client.is_floating = true;
    }

    var root_x: c_int = undefined;
    var root_y: c_int = undefined;
    var dummy_win: xlib.Window = undefined;
    var dummy_int: c_int = undefined;
    var dummy_uint: c_uint = undefined;

    _ = xlib.XQueryPointer(display.handle, display.root, &dummy_win, &dummy_win, &root_x, &root_y, &dummy_int, &dummy_int, &dummy_uint);

    const grab_result = xlib.XGrabPointer(
        display.handle,
        display.root,
        xlib.False,
        xlib.ButtonPressMask | xlib.ButtonReleaseMask | xlib.PointerMotionMask,
        xlib.GrabModeAsync,
        xlib.GrabModeAsync,
        xlib.None,
        cursor_move,
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
        _ = xlib.XNextEvent(display.handle, &event);

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
                    new_x = snap_x(client, new_x, client_monitor);
                    new_y = snap_y(client, new_y, client_monitor);
                }
                tiling.resize(client, new_x, new_y, client.width, client.height, true);
            },
            xlib.ButtonRelease => {
                done = true;
            },
            else => {},
        }
    }

    _ = xlib.XUngrabPointer(display.handle, xlib.CurrentTime);

    const new_mon = monitor_mod.rect_to_monitor(client.x, client.y, client.width, client.height);
    if (new_mon != null and new_mon != monitor) {
        client_mod.detach(client);
        client_mod.detach_stack(client);
        client.monitor = new_mon;
        client.tags = new_mon.?.tagset[new_mon.?.sel_tags];
        client_mod.attach_aside(client);
        client_mod.attach_stack(client);
        monitor_mod.selected_monitor = new_mon;
        focus(display, client);
        arrange(monitor);
        arrange(new_mon.?);
    } else {
        arrange(monitor);
    }

    if (config.auto_tile and !was_floating) {
        const drop_monitor = client.monitor orelse return;
        const center_x = client.x + @divTrunc(client.width, 2);
        const center_y = client.y + @divTrunc(client.height, 2);

        if (client_mod.tiled_window_at(client, drop_monitor, center_x, center_y)) |target| {
            client_mod.insert_before(client, target);
        }

        client.is_floating = false;
        arrange(drop_monitor);
    }
}

fn resizemouse(display: *Display) void {
    const monitor = monitor_mod.selected_monitor orelse return;
    const client = monitor.sel orelse return;

    if (client.is_fullscreen) {
        return;
    }

    restack(display, monitor);

    if (!client.is_floating) {
        client.is_floating = true;
    }

    const grab_result = xlib.XGrabPointer(
        display.handle,
        display.root,
        xlib.False,
        xlib.ButtonPressMask | xlib.ButtonReleaseMask | xlib.PointerMotionMask,
        xlib.GrabModeAsync,
        xlib.GrabModeAsync,
        xlib.None,
        cursor_resize,
        xlib.CurrentTime,
    );

    if (grab_result != xlib.GrabSuccess) {
        return;
    }

    _ = xlib.XWarpPointer(display.handle, xlib.None, client.window, 0, 0, 0, 0, client.width + client.border_width - 1, client.height + client.border_width - 1);

    var event: xlib.XEvent = undefined;
    var done = false;
    var last_time: c_ulong = 0;

    while (!done) {
        _ = xlib.XNextEvent(display.handle, &event);

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

    _ = xlib.XUngrabPointer(display.handle, xlib.CurrentTime);
    arrange(monitor);
}

fn handle_expose(display: *Display, event: *xlib.XExposeEvent) void {
    if (event.count != 0) return;

    if (bar_mod.window_to_bar(event.window)) |bar| {
        bar.invalidate();
        bar.draw(display.handle, &tags);
    }
}

fn clean_mask(mask: c_uint) c_uint {
    const lock: c_uint = @intCast(xlib.LockMask);
    const shift: c_uint = @intCast(xlib.ShiftMask);
    const ctrl: c_uint = @intCast(xlib.ControlMask);
    const mod1: c_uint = @intCast(xlib.Mod1Mask);
    const mod2: c_uint = @intCast(xlib.Mod2Mask);
    const mod3: c_uint = @intCast(xlib.Mod3Mask);
    const mod4: c_uint = @intCast(xlib.Mod4Mask);
    const mod5: c_uint = @intCast(xlib.Mod5Mask);
    return mask & ~(lock | numlock_mask) & (shift | ctrl | mod1 | mod2 | mod3 | mod4 | mod5);
}

fn handle_button_press(display: *Display, event: *xlib.XButtonEvent) void {
    std.debug.print("button_press: window=0x{x} subwindow=0x{x}\n", .{ event.window, event.subwindow });

    const clicked_monitor = monitor_mod.window_to_monitor(event.window);
    if (clicked_monitor) |monitor| {
        if (monitor != monitor_mod.selected_monitor) {
            if (monitor_mod.selected_monitor) |selmon| {
                unfocus_client(display, selmon.sel, true);
            }
            monitor_mod.selected_monitor = monitor;
            focus(display, null);
        }
    }

    if (bar_mod.window_to_bar(event.window)) |bar| {
        const clicked_tag = bar.handle_click(event.x, &tags);
        if (clicked_tag) |tag_index| {
            const tag_mask: u32 = @as(u32, 1) << @intCast(tag_index);
            view(display, tag_mask);
        }
        return;
    }

    const click_client = client_mod.window_to_client(event.window);
    if (click_client) |found_client| {
        focus(display, found_client);
        if (monitor_mod.selected_monitor) |selmon| {
            restack(display, selmon);
        }
        _ = xlib.XAllowEvents(display.handle, xlib.ReplayPointer, xlib.CurrentTime);
    }

    const clean_state = clean_mask(event.state);
    for (config.buttons.items) |button| {
        if (button.click != .client_win) continue;
        const button_clean_mask = clean_mask(button.mod_mask);
        if (clean_state == button_clean_mask and event.button == button.button) {
            switch (button.action) {
                .move_mouse => movemouse(display),
                .resize_mouse => resizemouse(display),
                .toggle_floating => {
                    if (click_client) |found_client| {
                        found_client.is_floating = !found_client.is_floating;
                        if (monitor_mod.selected_monitor) |monitor| {
                            arrange(monitor);
                        }
                    }
                },
            }
            return;
        }
    }
}

fn handle_client_message(display: *Display, event: *xlib.XClientMessageEvent) void {
    const client = client_mod.window_to_client(event.window) orelse return;

    if (event.message_type == net_wm_state) {
        const action = event.data.l[0];
        const first_property = @as(xlib.Atom, @intCast(event.data.l[1]));
        const second_property = @as(xlib.Atom, @intCast(event.data.l[2]));

        if (first_property == net_wm_state_fullscreen or second_property == net_wm_state_fullscreen) {
            const net_wm_state_remove = 0;
            const net_wm_state_add = 1;
            const net_wm_state_toggle = 2;

            if (action == net_wm_state_add) {
                set_fullscreen(display, client, true);
            } else if (action == net_wm_state_remove) {
                set_fullscreen(display, client, false);
            } else if (action == net_wm_state_toggle) {
                set_fullscreen(display, client, !client.is_fullscreen);
            }
        }
    } else if (event.message_type == net_active_window) {
        const selected = monitor_mod.selected_monitor orelse return;
        if (client != selected.sel and !client.is_urgent) {
            set_urgent(display, client, true);
        }
    }
}

fn handle_destroy_notify(display: *Display, event: *xlib.XDestroyWindowEvent) void {
    const client = client_mod.window_to_client(event.window) orelse return;
    std.debug.print("destroy_notify: window=0x{x}\n", .{event.window});
    unmanage(display, client);
}

fn handle_unmap_notify(display: *Display, event: *xlib.XUnmapEvent) void {
    const client = client_mod.window_to_client(event.window) orelse return;
    std.debug.print("unmap_notify: window=0x{x}\n", .{event.window});
    unmanage(display, client);
}

fn unmanage(display: *Display, client: *Client) void {
    const client_monitor = client.monitor;

    var next_focus: ?*Client = null;
    if (client_monitor) |monitor| {
        if (monitor.sel == client and is_scrolling_layout(monitor)) {
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
    client_mod.detach_stack(client);

    if (client_monitor) |monitor| {
        if (monitor.sel == client) {
            monitor.sel = if (next_focus) |nf| nf else monitor.stack;
        }
        if (is_scrolling_layout(monitor)) {
            const target = if (monitor.sel) |sel| scrolling.get_target_scroll_for_window(monitor, sel) else 0;
            if (target == 0) {
                monitor.scroll_offset = scrolling.get_scroll_step(monitor);
            } else {
                monitor.scroll_offset = 0;
            }
        }
        arrange(monitor);
    }

    if (client_monitor) |monitor| {
        if (monitor.sel) |selected| {
            focus(display, selected);
        }
    }

    client_mod.destroy(client);
    update_client_list(display);
    bar_mod.invalidate_bars();
}

fn handle_enter_notify(display: *Display, event: *xlib.XCrossingEvent) void {
    if ((event.mode != xlib.NotifyNormal or event.detail == xlib.NotifyInferior) and event.window != display.root) {
        return;
    }

    const client = client_mod.window_to_client(event.window);
    const target_mon = if (client) |c| c.monitor else monitor_mod.window_to_monitor(event.window);
    const selmon = monitor_mod.selected_monitor;

    if (target_mon != selmon) {
        if (selmon) |sel| {
            unfocus_client(display, sel.sel, true);
        }
        monitor_mod.selected_monitor = target_mon;
    } else if (client == null) {
        return;
    } else if (selmon) |sel| {
        if (client.? == sel.sel) {
            return;
        }
    }

    focus(display, client);
}

fn handle_focus_in(display: *Display, event: *xlib.XFocusChangeEvent) void {
    const selmon = monitor_mod.selected_monitor orelse return;
    const selected = selmon.sel orelse return;
    if (event.window != selected.window) {
        set_focus(display, selected);
    }
}

fn set_focus(display: *Display, client: *Client) void {
    if (!client.never_focus) {
        _ = xlib.XSetInputFocus(display.handle, client.window, xlib.RevertToPointerRoot, xlib.CurrentTime);
        _ = xlib.XChangeProperty(display.handle, display.root, net_active_window, xlib.XA_WINDOW, 32, xlib.PropModeReplace, @ptrCast(&client.window), 1);
    }
    _ = send_event(display, client, wm_take_focus);
}

var last_motion_monitor: ?*Monitor = null;

fn handle_motion_notify(display: *Display, event: *xlib.XMotionEvent) void {
    if (event.window != display.root) {
        return;
    }

    const target_mon = monitor_mod.rect_to_monitor(event.x_root, event.y_root, 1, 1);
    if (target_mon != last_motion_monitor and last_motion_monitor != null) {
        if (monitor_mod.selected_monitor) |selmon| {
            unfocus_client(display, selmon.sel, true);
        }
        monitor_mod.selected_monitor = target_mon;
        focus(display, null);
    }
    last_motion_monitor = target_mon;
}

fn handle_property_notify(display: *Display, event: *xlib.XPropertyEvent) void {
    if (event.state == xlib.PropertyDelete) {
        return;
    }

    const client = client_mod.window_to_client(event.window) orelse return;

    if (event.atom == xlib.XA_WM_TRANSIENT_FOR) {
        var trans: xlib.Window = 0;
        if (!client.is_floating and xlib.XGetTransientForHint(display.handle, client.window, &trans) != 0) {
            client.is_floating = client_mod.window_to_client(trans) != null;
            if (client.is_floating) {
                if (client.monitor) |monitor| {
                    arrange(monitor);
                }
            }
        }
    } else if (event.atom == xlib.XA_WM_NORMAL_HINTS) {
        client.hints_valid = false;
    } else if (event.atom == xlib.XA_WM_HINTS) {
        update_wm_hints(display, client);
        bar_mod.invalidate_bars();
    } else if (event.atom == xlib.XA_WM_NAME or event.atom == net_wm_name) {
        update_title(display, client);
    } else if (event.atom == net_wm_window_type) {
        update_window_type(display, client);
    }
}

fn unfocus_client(display: *Display, client: ?*Client, reset_input_focus: bool) void {
    const unfocus_target = client orelse return;
    grabbuttons(display, unfocus_target, false);
    _ = xlib.XSetWindowBorder(display.handle, unfocus_target.window, border_color_unfocused);
    if (reset_input_focus) {
        _ = xlib.XSetInputFocus(display.handle, display.root, xlib.RevertToPointerRoot, xlib.CurrentTime);
        _ = xlib.XDeleteProperty(display.handle, display.root, net_active_window);
    }
}

fn set_client_state(display: *Display, client: *Client, state: c_long) void {
    var data: [2]c_long = .{ state, xlib.None };
    _ = xlib.c.XChangeProperty(display.handle, client.window, wm_state, wm_state, 32, xlib.PropModeReplace, @ptrCast(&data), 2);
}

fn update_numlock_mask(display: *Display) void {
    numlock_mask = 0;
    const modmap = xlib.XGetModifierMapping(display.handle);
    if (modmap == null) return;
    defer _ = xlib.XFreeModifiermap(modmap);

    const numlock_keycode = xlib.XKeysymToKeycode(display.handle, xlib.XK_Num_Lock);

    var modifier_index: usize = 0;
    while (modifier_index < 8) : (modifier_index += 1) {
        var key_index: usize = 0;
        while (key_index < @as(usize, @intCast(modmap.*.max_keypermod))) : (key_index += 1) {
            const keycode = modmap.*.modifiermap[modifier_index * @as(usize, @intCast(modmap.*.max_keypermod)) + key_index];
            if (keycode == numlock_keycode) {
                numlock_mask = @as(c_uint, 1) << @intCast(modifier_index);
            }
        }
    }
}

fn grabbuttons(display: *Display, client: *Client, focused: bool) void {
    update_numlock_mask(display);
    const modifiers = [_]c_uint{ 0, xlib.LockMask, numlock_mask, numlock_mask | xlib.LockMask };

    _ = xlib.XUngrabButton(display.handle, xlib.AnyButton, xlib.AnyModifier, client.window);
    if (!focused) {
        _ = xlib.XGrabButton(
            display.handle,
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
    for (config.buttons.items) |button| {
        if (button.click == .client_win) {
            for (modifiers) |modifier| {
                _ = xlib.XGrabButton(
                    display.handle,
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

fn focus(display: *Display, target_client: ?*Client) void {
    const selmon = monitor_mod.selected_monitor orelse return;

    var focus_client = target_client;
    if (focus_client == null or !client_mod.is_visible(focus_client.?)) {
        focus_client = selmon.stack;
        while (focus_client) |iter| {
            if (client_mod.is_visible(iter)) break;
            focus_client = iter.stack_next;
        }
    }

    if (selmon.sel != null and selmon.sel != focus_client) {
        unfocus_client(display, selmon.sel, false);
    }

    if (focus_client) |client| {
        if (client.monitor != selmon) {
            monitor_mod.selected_monitor = client.monitor;
        }
        if (client.is_urgent) {
            set_urgent(display, client, false);
        }
        client_mod.detach_stack(client);
        client_mod.attach_stack(client);
        grabbuttons(display, client, true);
        _ = xlib.XSetWindowBorder(display.handle, client.window, border_color_focused);
        if (!client.never_focus) {
            _ = xlib.XSetInputFocus(display.handle, client.window, xlib.RevertToPointerRoot, xlib.CurrentTime);
            _ = xlib.XChangeProperty(display.handle, display.root, net_active_window, xlib.XA_WINDOW, 32, xlib.PropModeReplace, @ptrCast(&client.window), 1);
        }
        _ = send_event(display, client, wm_take_focus);
    } else {
        _ = xlib.XSetInputFocus(display.handle, display.root, xlib.RevertToPointerRoot, xlib.CurrentTime);
        _ = xlib.XDeleteProperty(display.handle, display.root, net_active_window);
    }

    const current_selmon = monitor_mod.selected_monitor orelse return;
    current_selmon.sel = focus_client;

    if (focus_client) |client| {
        if (is_scrolling_layout(current_selmon)) {
            scroll_to_window(client, true);
        }
    }

    bar_mod.invalidate_bars();
}

fn restack(display: *Display, monitor: *Monitor) void {
    bar_mod.invalidate_bars();
    const selected_client = monitor.sel orelse return;

    if (selected_client.is_floating or monitor.lt[monitor.sel_lt] == null) {
        _ = xlib.XRaiseWindow(display.handle, selected_client.window);
    }

    if (monitor.lt[monitor.sel_lt] != null) {
        var window_changes: xlib.c.XWindowChanges = undefined;
        window_changes.stack_mode = xlib.c.Below;
        window_changes.sibling = monitor.bar_win;

        var current = monitor.stack;
        while (current) |client| {
            if (!client.is_floating and client_mod.is_visible(client)) {
                _ = xlib.c.XConfigureWindow(display.handle, client.window, xlib.c.CWSibling | xlib.c.CWStackMode, &window_changes);
                window_changes.sibling = client.window;
            }
            current = client.stack_next;
        }
    }

    _ = xlib.XSync(display.handle, xlib.False);

    var discard_event: xlib.XEvent = undefined;
    while (xlib.c.XCheckMaskEvent(display.handle, xlib.EnterWindowMask, &discard_event) != 0) {}
}

fn arrange(monitor: *Monitor) void {
    if (display_global) |display| {
        showhide(display, monitor);
    }
    if (monitor.lt[monitor.sel_lt]) |layout| {
        if (layout.arrange_fn) |arrange_fn| {
            arrange_fn(monitor);
        }
    }
    if (display_global) |display| {
        restack(display, monitor);
    }
}

fn tick_animations() void {
    if (!scroll_animation.is_active()) return;

    const monitor = monitor_mod.selected_monitor orelse return;
    if (scroll_animation.update()) |new_offset| {
        monitor.scroll_offset = new_offset;
        arrange(monitor);
    }
}

fn is_scrolling_layout(monitor: *Monitor) bool {
    if (monitor.lt[monitor.sel_lt]) |layout| {
        return layout.arrange_fn == scrolling.layout.arrange_fn;
    }
    return false;
}

fn scroll_layout(direction: i32) void {
    const monitor = monitor_mod.selected_monitor orelse return;
    if (!is_scrolling_layout(monitor)) return;

    const scroll_step = scrolling.get_scroll_step(monitor);
    const max_scroll = scrolling.get_max_scroll(monitor);

    const current = if (scroll_animation.is_active())
        scroll_animation.target()
    else
        monitor.scroll_offset;

    var target = current + direction * scroll_step;
    target = @max(0, @min(target, max_scroll));

    scroll_animation.start(monitor.scroll_offset, target, animation_config);
}

fn scroll_to_window(client: *Client, animate: bool) void {
    const monitor = client.monitor orelse return;
    if (!is_scrolling_layout(monitor)) return;

    const target = scrolling.get_target_scroll_for_window(monitor, client);

    if (animate) {
        scroll_animation.start(monitor.scroll_offset, target, animation_config);
    } else {
        monitor.scroll_offset = target;
        arrange(monitor);
    }
}

fn showhide_client(display: *Display, client: ?*Client) void {
    const target = client orelse return;
    if (client_mod.is_visible(target)) {
        _ = xlib.XMoveWindow(display.handle, target.window, target.x, target.y);
        const monitor = target.monitor orelse return;
        if ((monitor.lt[monitor.sel_lt] == null or target.is_floating) and !target.is_fullscreen) {
            tiling.resize(target, target.x, target.y, target.width, target.height, false);
        }
        showhide_client(display, target.stack_next);
    } else {
        showhide_client(display, target.stack_next);
        const client_width = target.width + 2 * target.border_width;
        _ = xlib.XMoveWindow(display.handle, target.window, -2 * client_width, target.y);
    }
}

fn showhide(display: *Display, monitor: *Monitor) void {
    showhide_client(display, monitor.stack);
}

fn update_size_hints(display: *Display, client: *Client) void {
    var size_hints: xlib.XSizeHints = undefined;
    var msize: c_long = 0;

    if (xlib.XGetWMNormalHints(display.handle, client.window, &size_hints, &msize) == 0) {
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

fn update_wm_hints(display: *Display, client: *Client) void {
    const wmh = xlib.XGetWMHints(display.handle, client.window);
    if (wmh) |hints| {
        defer _ = xlib.XFree(@ptrCast(hints));

        if (client == (monitor_mod.selected_monitor orelse return).sel and (hints.*.flags & xlib.XUrgencyHint) != 0) {
            hints.*.flags = hints.*.flags & ~@as(c_long, xlib.XUrgencyHint);
            _ = xlib.XSetWMHints(display.handle, client.window, hints);
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

fn update_window_type(display: *Display, client: *Client) void {
    const state = get_atom_prop(display, client, net_wm_state);
    const window_type = get_atom_prop(display, client, net_wm_window_type);

    if (state == net_wm_state_fullscreen) {
        set_fullscreen(display, client, true);
    }
    if (window_type == net_wm_window_type_dialog) {
        client.is_floating = true;
    }
}

fn update_title(display: *Display, client: *Client) void {
    if (!get_text_prop(display, client.window, net_wm_name, &client.name)) {
        _ = get_text_prop(display, client.window, xlib.XA_WM_NAME, &client.name);
    }
    if (client.name[0] == 0) {
        @memcpy(client.name[0..6], "broken");
    }
}

fn get_atom_prop(display: *Display, client: *Client, prop: xlib.Atom) xlib.Atom {
    var actual_type: xlib.Atom = undefined;
    var actual_format: c_int = undefined;
    var num_items: c_ulong = undefined;
    var bytes_after: c_ulong = undefined;
    var prop_data: [*c]u8 = undefined;

    if (xlib.XGetWindowProperty(display.handle, client.window, prop, 0, @sizeOf(xlib.Atom), xlib.False, xlib.XA_ATOM, &actual_type, &actual_format, &num_items, &bytes_after, &prop_data) == 0 and prop_data != null) {
        const atom: xlib.Atom = @as(*xlib.Atom, @ptrCast(@alignCast(prop_data))).*;
        _ = xlib.XFree(@ptrCast(prop_data));
        return atom;
    }
    return 0;
}

fn get_text_prop(display: *Display, window: xlib.Window, atom: xlib.Atom, text: *[256]u8) bool {
    var name: xlib.XTextProperty = undefined;
    text[0] = 0;

    if (xlib.XGetTextProperty(display.handle, window, &name, atom) == 0 or name.nitems == 0) {
        return false;
    }

    if (name.encoding == xlib.XA_STRING) {
        const len = @min(name.nitems, 255);
        @memcpy(text[0..len], name.value[0..len]);
        text[len] = 0;
    } else {
        var list: [*c][*c]u8 = undefined;
        var count: c_int = undefined;
        if (xlib.XmbTextPropertyToTextList(display.handle, &name, &list, &count) >= xlib.Success and count > 0 and list[0] != null) {
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

fn apply_rules(display: *Display, client: *Client) void {
    var class_hint: xlib.XClassHint = .{ .res_name = null, .res_class = null };
    _ = xlib.XGetClassHint(display.handle, client.window, &class_hint);

    const class_str: []const u8 = if (class_hint.res_class) |ptr| std.mem.sliceTo(ptr, 0) else "";
    const instance_str: []const u8 = if (class_hint.res_name) |ptr| std.mem.sliceTo(ptr, 0) else "";

    client.is_floating = false;
    client.tags = 0;
    var rule_focus = false;

    for (config.rules.items) |rule| {
        const class_matches = if (rule.class) |rc| std.mem.indexOf(u8, class_str, rc) != null else true;
        const instance_matches = if (rule.instance) |ri| std.mem.indexOf(u8, instance_str, ri) != null else true;
        const title_matches = if (rule.title) |rt| std.mem.indexOf(u8, std.mem.sliceTo(&client.name, 0), rt) != null else true;

        if (class_matches and instance_matches and title_matches) {
            client.is_floating = rule.is_floating;
            client.tags |= rule.tags;
            if (rule.monitor >= 0) {
                var target = monitor_mod.monitors;
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
            view(display, client.tags);
        }
    }
}

fn update_client_list(display: *Display) void {
    _ = xlib.XDeleteProperty(display.handle, display.root, net_client_list);

    var current_monitor = monitor_mod.monitors;
    while (current_monitor) |monitor| {
        var current_client = monitor.clients;
        while (current_client) |client| {
            _ = xlib.XChangeProperty(display.handle, display.root, net_client_list, xlib.XA_WINDOW, 32, xlib.PropModeAppend, @ptrCast(&client.window), 1);
            current_client = client.next;
        }
        current_monitor = monitor.next;
    }
}

fn send_event(display: *Display, client: *Client, protocol: xlib.Atom) bool {
    var protocols: [*c]xlib.Atom = undefined;
    var num_protocols: c_int = 0;
    var exists = false;

    if (xlib.XGetWMProtocols(display.handle, client.window, &protocols, &num_protocols) != 0) {
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
        event.xclient.message_type = wm_protocols;
        event.xclient.format = 32;
        event.xclient.data.l[0] = @intCast(protocol);
        event.xclient.data.l[1] = xlib.CurrentTime;
        _ = xlib.XSendEvent(display.handle, client.window, xlib.False, xlib.NoEventMask, &event);
    }
    return exists;
}

fn set_urgent(display: *Display, client: *Client, urgent: bool) void {
    client.is_urgent = urgent;
    const wmh = xlib.XGetWMHints(display.handle, client.window);
    if (wmh) |hints| {
        if (urgent) {
            hints.*.flags = hints.*.flags | xlib.XUrgencyHint;
        } else {
            hints.*.flags = hints.*.flags & ~@as(c_long, xlib.XUrgencyHint);
        }
        _ = xlib.XSetWMHints(display.handle, client.window, hints);
        _ = xlib.XFree(@ptrCast(hints));
    }
}

fn run_autostart_commands(_: std.mem.Allocator, commands: []const []const u8) !void {
    for (commands) |cmd| spawn_command(cmd);
}

test {
    _ = @import("x11/events.zig");
}
