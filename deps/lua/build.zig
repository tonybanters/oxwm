// Zig build system wrapper for Lua

const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    // C lua source code
    const lua = b.dependency("lua", .{});

    // Module as a separate const so that zls resolves modules properly
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // The actual library
    const lib = b.addLibrary(.{
        .name = "lua",
        .root_module = mod,
    });

    // Enable posix, allows subprocesses
    lib.root_module.addCMacro("LUA_USE_POSIX", "1");

    lib.root_module.addIncludePath(lua.path("src"));

    // Install Lua headers
    lib.installHeader(lua.path("src/lua.h"), "lua.h");
    lib.installHeader(lua.path("src/lualib.h"), "lualib.h");
    lib.installHeader(lua.path("src/lauxlib.h"), "lauxlib.h");
    lib.installHeader(lua.path("src/luaconf.h"), "luaconf.h");

    // Compile the source
    lib.root_module.addCSourceFiles(.{
        .root = lua.path("src"),
        .files = &.{
            "lapi.c",
            "lauxlib.c",
            "lbaselib.c",
            "lcode.c",
            "lcorolib.c",
            "lctype.c",
            "ldblib.c",
            "ldebug.c",
            "ldo.c",
            "ldump.c",
            "lfunc.c",
            "lgc.c",
            "linit.c",
            "liolib.c",
            "llex.c",
            "lmathlib.c",
            "lmem.c",
            "loadlib.c",
            "lobject.c",
            "lopcodes.c",
            "loslib.c",
            "lparser.c",
            "lstate.c",
            "lstring.c",
            "lstrlib.c",
            "ltable.c",
            "ltablib.c",
            "ltm.c",
            "lundump.c",
            "lutf8lib.c",
            "lvm.c",
            "lzio.c",
        },
    });

    // Expose the artifact
    b.installArtifact(lib);
}
