const std = @import("std");
const testing = std.testing;
const lua = @import("../config/lua.zig");
const Config = lua.config_mod.Config;

test "test-config.lua loads without errors" {
    var cfg = Config.init(testing.allocator);
    defer cfg.deinit();

    const initialized = lua.init(&cfg);
    if (!initialized) {
        return error.LuaInitFailed;
    }
    defer lua.deinit();

    const loaded = lua.loadFile("resources/test-config.lua");
    try testing.expect(loaded);
}
