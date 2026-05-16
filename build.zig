const std = @import("std");
const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lua_dep = b.dependency("lua", .{
        .optimize = optimize,
        .target = target,
    });
    const lua_headers = lua_dep.path("src/");
    const lua = lua_dep.artifact("lua");

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

    exe.root_module.linkLibrary(lua);
    exe.root_module.linkSystemLibrary("X11", .{});
    exe.root_module.linkSystemLibrary("Xinerama", .{});
    exe.root_module.linkSystemLibrary("Xft", .{});
    exe.root_module.linkSystemLibrary("fontconfig", .{});

    b.installArtifact(exe);

    const run_step = b.step("run", "Run oxwm");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const test_step = b.step("test", "Run unit tests");
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/main_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .use_lld = false,
    });
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    const src_main_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
        .use_lld = false,
    });
    src_main_unit_tests.root_module.addIncludePath(lua_headers);
    src_main_unit_tests.root_module.linkLibrary(lua);
    src_main_unit_tests.root_module.linkSystemLibrary("X11", .{});
    src_main_unit_tests.root_module.linkSystemLibrary("Xinerama", .{});
    src_main_unit_tests.root_module.linkSystemLibrary("Xft", .{});
    src_main_unit_tests.root_module.linkSystemLibrary("fontconfig", .{});
    test_step.dependOn(&b.addRunArtifact(src_main_unit_tests).step);

    const lua_config_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/lua_config_tests.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
        .use_lld = false,
    });
    lua_config_tests.root_module.addIncludePath(lua_headers);
    const lua_config_module = b.createModule(.{
        .root_source_file = b.path("src/config/lua.zig"),
        .target = target,
        .optimize = optimize,
    });
    lua_config_module.addIncludePath(lua_headers);
    lua_config_tests.root_module.addImport("lua", lua_config_module);
    lua_config_tests.root_module.linkLibrary(lua);
    test_step.dependOn(&b.addRunArtifact(lua_config_tests).step);

    const xephyr_step = b.step("xephyr", "Run in Xephyr (1280x800 on :2)");
    xephyr_step.dependOn(&addXephyrRun(b, exe, false).step);

    const xephyr_multi_step = b.step("xephyr-multi", "Run in Xephyr multi-monitor on :2");
    xephyr_multi_step.dependOn(&addXephyrRun(b, exe, true).step);

    const multimon_step = b.step("multimon", "Alias for xephyr-multi");
    multimon_step.dependOn(&addXephyrRun(b, exe, true).step);

    const xwayland_step = b.step("xwayland", "Run in Xwayland on :2");
    xwayland_step.dependOn(&addXwaylandRun(b, exe).step);

    const kill_step = b.step("kill", "Kill Xephyr and oxwm");
    kill_step.dependOn(&b.addSystemCommand(&.{ "sh", "-c", "pkill -9 Xephyr || true; pkill -9 oxwm || true" }).step);

    const fmt_step = b.step("fmt", "Format source files");
    fmt_step.dependOn(&b.addFmt(.{ .paths = &.{"src/"} }).step);

    const clean_step = b.step("clean", "Remove build artifacts");
    clean_step.dependOn(&b.addSystemCommand(&.{ "rm", "-rf", "zig-out", ".zig-cache" }).step);

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
