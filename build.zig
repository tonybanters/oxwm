const std = @import("std");
const zon = @import("build.zig.zon");

pub const RunWrapper = enum {
    xwayland,
    xw,
    xephyr,
    xe,
};

pub const WrapOptions = struct {
    display: u16,
    app: ?RunWrapper,
    args: ?[]const u8,
    nodefault: bool,
    xephyr_mm: bool,
};

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lua_dep = b.dependency("lua", .{
        .optimize = optimize,
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "oxwm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
        .use_lld = false,
    });

    const exe_options = b.addOptions();
    exe_options.addOption([]const u8, "version", zon.version);
    exe.root_module.addOptions("build_options", exe_options);
    exe.root_module.addAnonymousImport("templates/config.lua", .{
        .root_source_file = b.path("templates/config.lua"),
    });

    link(exe.root_module, lua_dep);
    b.installArtifact(exe);

    // Setup run command
    const wrap = WrapOptions{
        .app = b.option(RunWrapper, "wrap", "Run a wrapper like Xwayland before oxwm"),
        .args = b.option([]const u8, "w_args", "Pass arguments to the wrapper"),
        .nodefault = b.option(bool, "w_nodef", "Don't pass default arguments to wrappers (default: false)") orelse false,
        .display = b.option(u16, "display", "Set $DISPLAY to run oxwm in a wrapper (default: 2)") orelse 2,
        .xephyr_mm = b.option(bool, "w_xp_mm", "Run a multi-monitor Xephyr instance (default: false)") orelse false,
    };
    const run_step = b.step("run", "Run oxwm");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    try addWrapper(b, run_cmd, wrap);

    const test_step = b.step("test", "Run unit tests");
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .use_lld = false,
    });
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    link(unit_tests.root_module, lua_dep);

    const kill_step = b.step("kill", "Kill Xephyr and oxwm");
    kill_step.dependOn(&b.addSystemCommand(&.{ "sh", "-c", "pkill -9 Xephyr || true; pkill -9 oxwm || true" }).step);

    // Install the required resources
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(b.path("resources/oxwm.desktop"), .prefix, "share/xsessions/oxwm.desktop").step);
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(b.path("resources/oxwm.1"), .prefix, "share/man/man1/oxwm.1").step);
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(b.path("templates/oxwm.lua"), .prefix, "share/oxwm/oxwm.lua").step);

    // Uninstall resources installed by the install step
    // TODO: wait for the https://github.com/ziglang/zig/issues/14943 issue to be resolved
    //      and remove this completely
    const uninstall_step = b.step("uninstall-system", "Uninstall oxwm from system");
    uninstall_step.dependOn(&b.addSystemCommand(&.{
        "sudo", "sh", "-c",
        "rm -f /usr/bin/oxwm /usr/share/xsessions/oxwm.desktop /usr/share/man/man1/oxwm.1 && " ++
            "rm -rf /usr/share/oxwm && " ++
            "echo 'oxwm uninstalled (config at ~/.config/oxwm preserved)'",
    }).step);
}

fn link(mod: *std.Build.Module, lua: *std.Build.Dependency) void {
    linkLua(mod, lua);

    mod.linkSystemLibrary("X11", .{});
    mod.linkSystemLibrary("Xinerama", .{});
    mod.linkSystemLibrary("Xft", .{});
    mod.linkSystemLibrary("fontconfig", .{});
}

fn linkLua(mod: *std.Build.Module, dep: *std.Build.Dependency) void {
    mod.linkLibrary(dep.artifact("lua"));
    mod.addIncludePath(dep.path("src"));
}

fn addWrapper(b: *std.Build, artifact: *std.Build.Step.Run, opts: WrapOptions) !void {
    if (opts.app == null) return;

    const app = opts.app.?;
    const disp = b.fmt(":{d}", .{opts.display});
    const bin = try b.findProgram(&.{switch (app) {
        .xwayland, .xw => "Xwayland",
        .xephyr, .xe => "Xephyr",
    }}, &.{});
    var argv: std.array_list.Aligned([]const u8, null) = .empty;
    defer argv.deinit(b.allocator);

    // Default arguments
    try argv.append(b.allocator, bin);
    if (!opts.nodefault) switch (app) {
        .xwayland, .xw => try argv.appendSlice(b.allocator, &.{ "-retro", "-noreset", disp }),
        .xephyr, .xe => if (opts.xephyr_mm) {
            try argv.appendSlice(b.allocator, &.{ "+xinerama", "-glamor", "-screen", "640x480", "-screen", "640x480", disp });
        } else try argv.appendSlice(b.allocator, &.{ "-screen", "1280x800" }),
    };

    // User arguments
    if (opts.args) |args| {
        var it = std.mem.tokenizeScalar(u8, args, ' ');
        while (it.next()) |arg| try argv.append(b.allocator, arg);
    }

    // Disowning the process to finish step
    try argv.appendSlice(b.allocator, &.{ "&", "sleep", "0.2" });

    // Setup command
    const argv_flat = try flatten(b.allocator, argv.items, ' ');
    const cmd = b.addSystemCommand(&.{ "sh", "-c", argv_flat });

    // Make the wrapper run before oxwm
    artifact.step.dependOn(&cmd.step);
    artifact.setEnvironmentVariable("DISPLAY", disp);
}

fn flatten(allocator: std.mem.Allocator, array: []const []const u8, sep: u8) ![]const u8 {
    var writer = std.Io.Writer.Allocating.init(allocator);
    errdefer writer.deinit();

    for (array) |i| {
        try writer.writer.writeAll(i);
        try writer.writer.writeByte(sep);
    } 
    return writer.toOwnedSlice();
} 

fn addXephyrRun(b: *std.Build, exe: *std.Build.Step.Compile, multimon: bool) *std.Build.Step.Run {
    const kill_cmd = if (multimon)
        "pkill -9 Xephyr || true; Xephyr +xinerama -glamor -screen 640x480 -screen 640x480 :2 & sleep 1"
    else
        "pkill -9 Xephyr || true; Xephyr -screen 1280x800 :2 & sleep 1";

    const setup = b.addSystemCommand(&.{ "sh", "-c", kill_cmd });

    const run_wm = b.addRunArtifact(exe);
    run_wm.step.dependOn(&setup.step);
    run_wm.setEnvironmentVariable("DISPLAY", ":2");
    run_wm.addArgs(&.{ "-c", "resources/test-config.lua" });

    return run_wm;
}

fn addXwaylandRun(b: *std.Build, exe: *std.Build.Step.Compile) *std.Build.Step.Run {
    const cmd = "Xwayland -retro -noreset :2 & sleep 1";

    const setup = b.addSystemCommand(&.{ "sh", "-c", cmd });

    const run_wm = b.addRunArtifact(exe);
    run_wm.step.dependOn(&setup.step);
    run_wm.setEnvironmentVariable("DISPLAY", ":2");

    return run_wm;
}
