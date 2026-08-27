const std = @import("std");
const build_options = @import("build_options");

const actions = @import("wm/actions.zig");
const handlers = @import("wm/handlers.zig");
const window_manager = @import("wm/wm.zig");
const config_mod = @import("config/config.zig");
const lua = @import("config/lua.zig");

const WindowManager = window_manager.WindowManager;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const env = init.environ_map;

    const default_config_path = try getConfigPath(allocator, env);
    defer allocator.free(default_config_path);

    var config_path: []const u8 = default_config_path;
    var validate_mode: bool = false;
    var args = init.minimal.args.iterate();
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--config")) {
            if (args.next()) |path| config_path = path;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printHelp();
            return;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
            std.debug.print("v{s}\n", .{build_options.version});
            return;
        } else if (std.mem.eql(u8, arg, "--init")) {
            initConfig(allocator, init.io, env);
            return;
        } else if (std.mem.eql(u8, arg, "--validate")) {
            validate_mode = true;
            if (args.next()) |path| config_path = path;
        }
    }

    if (validate_mode) {
        try validateConfig(allocator, init.io, config_path);
        return;
    }

    std.debug.print("oxwm starting\n", .{});

    var config = config_mod.Config.init(allocator);

    if (lua.init(&config)) {
        const loaded = if (std.Io.Dir.cwd().statFile(init.io, config_path, .{})) |_| blk: {
            break :blk lua.loadFile(config_path);
        } else |_| blk: {
            initConfig(allocator, init.io, env);
            break :blk lua.loadConfig(env);
        };

        if (loaded) {
            std.debug.print("loaded config from {s}\n", .{config_path});
        } else {
            std.debug.print("no config found, using defaults\n", .{});
            config_mod.initializeDefaultConfig(&config);
        }
    } else {
        std.debug.print("failed to init lua, using defaults\n", .{});
        config_mod.initializeDefaultConfig(&config);
    }

    var wm = WindowManager.init(allocator, config, config_path, env, init.io) catch |err| {
        std.debug.print("failed to start window manager: {}\n", .{err});
        return;
    };
    defer wm.deinit();

    std.debug.print("display opened: screen={d} root=0x{x}\n", .{ wm.display.screen, wm.display.root });
    std.debug.print("successfully became window manager\n", .{});
    std.debug.print("atoms initialized with EWMH support\n", .{});

    const sigchld_handler = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.mem.zeroes(std.posix.sigset_t),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.CHLD, &sigchld_handler, null);

    wm.grabKeybinds();
    wm.scanExistingWindows(window_manager.core.manage);

    try runAutostartCommands(&wm);
    std.debug.print("entering event loop\n", .{});
    wm.run(handlers.handleEvent, window_manager.core.tickAnimations);

    lua.deinit();
    std.debug.print("oxwm exiting\n", .{});
}

fn printHelp() void {
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

fn initConfig(allocator: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map) void {
    const config_path = getConfigPath(allocator, env) catch return;
    defer allocator.free(config_path);

    const template = @embedFile("templates/config.lua");

    if (std.fs.path.dirname(config_path)) |dir_path| {
        var root = std.Io.Dir.openDirAbsolute(io, "/", .{}) catch |err| {
            std.debug.print("error: could not open root directory: {}\n", .{err});
            return;
        };
        defer root.close(io);

        const relative_path = std.mem.trimStart(u8, dir_path, "/");
        root.createDirPath(io, relative_path) catch |err| {
            std.debug.print("error: could not create config directory: {}\n", .{err});
            return;
        };
    }

    const file = std.Io.Dir.createFileAbsolute(io, config_path, .{}) catch |err| {
        std.debug.print("error: could not create config file: {}\n", .{err});
        return;
    };
    defer file.close(io);

    file.writeStreamingAll(io, template) catch |err| {
        std.debug.print("error: could not write config file: {}\n", .{err});
        return;
    };

    std.debug.print("Config created at {s}\n", .{config_path});
    std.debug.print("Edit the file and reload with Mod+Shift+R\n", .{});
    std.debug.print("No compilation needed - changes take effect immediately!\n", .{});
}

fn getConfigPath(allocator: std.mem.Allocator, env: *std.process.Environ.Map) ![]u8 {
    if (env.get("XDG_CONFIG_HOME")) |xdg| {
        return std.fs.path.join(allocator, &.{ xdg, "oxwm", "config.lua" });
    }
    const home = env.get("HOME") orelse return error.CouldNotGetHomeDir;
    return std.fs.path.join(allocator, &.{ home, ".config", "oxwm", "config.lua" });
}

fn validateConfig(allocator: std.mem.Allocator, io: std.Io, config_path: []const u8) !void {
    var config = config_mod.Config.init(allocator);
    defer config.deinit();

    if (!lua.init(&config)) {
        std.debug.print("error: failed to initialize lua\n", .{});
        std.process.exit(1);
    }
    defer lua.deinit();

    _ = std.Io.Dir.cwd().statFile(io, config_path, .{}) catch |err| {
        std.debug.print("error: config file not found: {s}\n", .{config_path});
        std.debug.print("  {}\n", .{err});
        std.process.exit(1);
    };

    if (lua.loadFile(config_path)) {
        std.debug.print("✓ config valid: {s}\n", .{config_path});
        std.process.exit(0);
    } else {
        std.debug.print("✗ config validation failed\n", .{});
        std.process.exit(1);
    }
}

fn runAutostartCommands(wm: *WindowManager) !void {
    const commands = wm.config.autostart.items;
    for (commands) |cmd| actions.spawnCommand(wm, cmd);
}

test {
    _ = @import("x11/events.zig");
}
