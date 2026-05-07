const std = @import("std");
pub const config_mod = @import("config.zig");
const Config = config_mod.Config;
const Keybind = config_mod.Keybind;
const Action = config_mod.Action;
const Rule = config_mod.Rule;
const Block = config_mod.Block;
const ColorScheme = config_mod.ColorScheme;

const c = @cImport({
    @cInclude("lua.h");
    @cInclude("lauxlib.h");
    @cInclude("lualib.h");
});

var L: ?*c.lua_State = null;
var config: ?*Config = null;

pub fn init(cfg: *Config) bool {
    config = cfg;
    L = c.luaL_newstate();
    if (L == null) return false;
    c.luaL_openlibs(L);
    registerApi();
    return true;
}

pub fn deinit() void {
    if (L) |state| {
        c.lua_close(state);
    }
    L = null;
    config = null;
}

pub fn loadFile(path: []const u8) bool {
    const state = L orelse return false;
    var path_buf: [512]u8 = undefined;
    if (path.len >= path_buf.len) return false;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;

    if (std.mem.lastIndexOfScalar(u8, path, '/')) |last_slash| {
        const dir = path[0..last_slash];
        var setup_buf: [600]u8 = undefined;
        const setup_code = std.fmt.bufPrintZ(&setup_buf, "package.path = '{s}/?.lua;' .. package.path", .{dir}) catch return false;
        if (c.luaL_loadstring(state, setup_code.ptr) != 0 or c.lua_pcallk(state, 0, 0, 0, 0, null) != 0) {
            c.lua_settop(state, -2);
            return false;
        }
    }

    if (c.luaL_loadfilex(state, &path_buf, null) != 0) {
        const err = c.lua_tolstring(state, -1, null);
        if (err != null) {
            std.debug.print("lua load error: {s}\n", .{std.mem.span(err)});
        }
        c.lua_settop(state, -2);
        return false;
    }

    if (c.lua_pcallk(state, 0, 0, 0, 0, null) != 0) {
        const err = c.lua_tolstring(state, -1, null);
        if (err != null) {
            std.debug.print("lua runtime error: {s}\n", .{std.mem.span(err)});
        }
        c.lua_settop(state, -2);
        return false;
    }

    return true;
}

pub fn loadConfig() bool {
    const home = std.posix.getenv("HOME") orelse return false;
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/.config/oxwm/config.lua", .{home}) catch return false;
    return loadFile(path);
}

fn registerApi() void {
    const state = L orelse return;

    c.lua_createtable(state, 0, 16);

    registerSpawnFunctions(state);
    registerKeyModule(state);
    registerGapsModule(state);
    registerBorderModule(state);
    registerClientModule(state);
    registerLayoutModule(state);
    registerTagModule(state);
    registerMonitorModule(state);
    registerRuleModule(state);
    registerBarModule(state);
    registerMiscFunctions(state);

    c.lua_setglobal(state, "oxwm");
}

fn registerSpawnFunctions(state: *c.lua_State) void {
    c.lua_pushcfunction(state, luaSpawn);
    c.lua_setfield(state, -2, "spawn");

    c.lua_pushcfunction(state, luaSpawnTerminal);
    c.lua_setfield(state, -2, "spawn_terminal");
}

fn registerKeyModule(state: *c.lua_State) void {
    c.lua_createtable(state, 0, 2);

    c.lua_pushcfunction(state, luaKeyBind);
    c.lua_setfield(state, -2, "bind");

    c.lua_pushcfunction(state, luaKeyChord);
    c.lua_setfield(state, -2, "chord");

    c.lua_setfield(state, -2, "key");
}

fn registerGapsModule(state: *c.lua_State) void {
    c.lua_createtable(state, 0, 6);

    c.lua_pushcfunction(state, luaGapsSetEnabled);
    c.lua_setfield(state, -2, "set_enabled");

    c.lua_pushcfunction(state, luaGapsEnable);
    c.lua_setfield(state, -2, "enable");

    c.lua_pushcfunction(state, luaGapsDisable);
    c.lua_setfield(state, -2, "disable");

    c.lua_pushcfunction(state, luaGapsSetInner);
    c.lua_setfield(state, -2, "set_inner");

    c.lua_pushcfunction(state, luaGapsSetOuter);
    c.lua_setfield(state, -2, "set_outer");

    c.lua_pushcfunction(state, luaGapsSetSmart);
    c.lua_setfield(state, -2, "set_smart");

    c.lua_setfield(state, -2, "gaps");
}

fn registerBorderModule(state: *c.lua_State) void {
    c.lua_createtable(state, 0, 3);

    c.lua_pushcfunction(state, luaBorderSetWidth);
    c.lua_setfield(state, -2, "set_width");

    c.lua_pushcfunction(state, luaBorderSetFocusedColor);
    c.lua_setfield(state, -2, "set_focused_color");

    c.lua_pushcfunction(state, luaBorderSetUnfocusedColor);
    c.lua_setfield(state, -2, "set_unfocused_color");

    c.lua_setfield(state, -2, "border");
}

fn registerClientModule(state: *c.lua_State) void {
    c.lua_createtable(state, 0, 5);

    c.lua_pushcfunction(state, luaClientKill);
    c.lua_setfield(state, -2, "kill");

    c.lua_pushcfunction(state, luaClientToggleFullscreen);
    c.lua_setfield(state, -2, "toggle_fullscreen");

    c.lua_pushcfunction(state, luaClientToggleFloating);
    c.lua_setfield(state, -2, "toggle_floating");

    c.lua_pushcfunction(state, luaClientFocusStack);
    c.lua_setfield(state, -2, "focus_stack");

    c.lua_pushcfunction(state, luaClientMoveStack);
    c.lua_setfield(state, -2, "move_stack");

    c.lua_setfield(state, -2, "client");
}

fn registerLayoutModule(state: *c.lua_State) void {
    c.lua_createtable(state, 0, 4);

    c.lua_pushcfunction(state, luaLayoutCycle);
    c.lua_setfield(state, -2, "cycle");

    c.lua_pushcfunction(state, luaLayoutSet);
    c.lua_setfield(state, -2, "set");

    c.lua_pushcfunction(state, luaLayoutScrollLeft);
    c.lua_setfield(state, -2, "scroll_left");

    c.lua_pushcfunction(state, luaLayoutScrollRight);
    c.lua_setfield(state, -2, "scroll_right");

    c.lua_setfield(state, -2, "layout");
}

fn registerTagModule(state: *c.lua_State) void {
    c.lua_createtable(state, 0, 10);

    c.lua_pushcfunction(state, luaTagView);
    c.lua_setfield(state, -2, "view");

    c.lua_pushcfunction(state, luaTagViewNext);
    c.lua_setfield(state, -2, "view_next");

    c.lua_pushcfunction(state, luaTagViewPrevious);
    c.lua_setfield(state, -2, "view_previous");

    c.lua_pushcfunction(state, luaTagViewNextNonempty);
    c.lua_setfield(state, -2, "view_next_nonempty");

    c.lua_pushcfunction(state, luaTagViewPreviousNonempty);
    c.lua_setfield(state, -2, "view_previous_nonempty");

    c.lua_pushcfunction(state, luaTagToggleview);
    c.lua_setfield(state, -2, "toggleview");

    c.lua_pushcfunction(state, luaTagMoveTo);
    c.lua_setfield(state, -2, "move_to");

    c.lua_pushcfunction(state, luaTagToggletag);
    c.lua_setfield(state, -2, "toggletag");

    c.lua_pushcfunction(state, luaTagSetBackAndForth);
    c.lua_setfield(state, -2, "set_back_and_forth");

    c.lua_setfield(state, -2, "tag");
}

fn registerMonitorModule(state: *c.lua_State) void {
    c.lua_createtable(state, 0, 2);

    c.lua_pushcfunction(state, luaMonitorFocus);
    c.lua_setfield(state, -2, "focus");

    c.lua_pushcfunction(state, luaMonitorTag);
    c.lua_setfield(state, -2, "tag");

    c.lua_setfield(state, -2, "monitor");
}

fn registerRuleModule(state: *c.lua_State) void {
    c.lua_createtable(state, 0, 1);

    c.lua_pushcfunction(state, luaRuleAdd);
    c.lua_setfield(state, -2, "add");

    c.lua_setfield(state, -2, "rule");
}

fn registerBarModule(state: *c.lua_State) void {
    c.lua_createtable(state, 0, 10);

    c.lua_pushcfunction(state, luaBarSetFont);
    c.lua_setfield(state, -2, "set_font");

    c.lua_pushcfunction(state, luaBarSetBlocks);
    c.lua_setfield(state, -2, "set_blocks");

    c.lua_pushcfunction(state, luaBarSetSchemeNormal);
    c.lua_setfield(state, -2, "set_scheme_normal");

    c.lua_pushcfunction(state, luaBarSetSchemeSelected);
    c.lua_setfield(state, -2, "set_scheme_selected");

    c.lua_pushcfunction(state, luaBarSetSchemeOccupied);
    c.lua_setfield(state, -2, "set_scheme_occupied");

    c.lua_pushcfunction(state, luaBarSetSchemeUrgent);
    c.lua_setfield(state, -2, "set_scheme_urgent");

    c.lua_pushcfunction(state, luaBarSetHideVacantTags);
    c.lua_setfield(state, -2, "set_hide_vacant_tags");

    c.lua_pushcfunction(state, luaBarSetPosition);
    c.lua_setfield(state, -2, "set_position");

    c.lua_createtable(state, 0, 6);

    c.lua_pushcfunction(state, luaBarBlockRam);
    c.lua_setfield(state, -2, "ram");

    c.lua_pushcfunction(state, luaBarBlockDatetime);
    c.lua_setfield(state, -2, "datetime");

    c.lua_pushcfunction(state, luaBarBlockShell);
    c.lua_setfield(state, -2, "shell");

    c.lua_pushcfunction(state, luaBarBlockStatic);
    c.lua_setfield(state, -2, "static");

    c.lua_pushcfunction(state, luaBarBlockBattery);
    c.lua_setfield(state, -2, "battery");

    c.lua_setfield(state, -2, "block");

    c.lua_setfield(state, -2, "bar");
}

fn registerMiscFunctions(state: *c.lua_State) void {
    c.lua_pushcfunction(state, luaSetTerminal);
    c.lua_setfield(state, -2, "set_terminal");

    c.lua_pushcfunction(state, luaSetLayout);
    c.lua_setfield(state, -2, "set_layout");

    c.lua_pushcfunction(state, luaSetModkey);
    c.lua_setfield(state, -2, "set_modkey");

    c.lua_pushcfunction(state, luaSetTags);
    c.lua_setfield(state, -2, "set_tags");

    c.lua_pushcfunction(state, luaSetLayoutSymbol);
    c.lua_setfield(state, -2, "set_layout_symbol");

    c.lua_pushcfunction(state, luaAutostart);
    c.lua_setfield(state, -2, "autostart");

    c.lua_pushcfunction(state, luaAutoTile);
    c.lua_setfield(state, -2, "auto_tile");

    c.lua_pushcfunction(state, luaTiledResizeMode);
    c.lua_setfield(state, -2, "tiled_resize_mode");

    c.lua_pushcfunction(state, luaQuit);
    c.lua_setfield(state, -2, "quit");

    c.lua_pushcfunction(state, luaRestart);
    c.lua_setfield(state, -2, "restart");

    c.lua_pushcfunction(state, luaToggleGaps);
    c.lua_setfield(state, -2, "toggle_gaps");

    c.lua_pushcfunction(state, luaToggleBar);
    c.lua_setfield(state, -2, "toggle_bar");

    c.lua_pushcfunction(state, luaShowKeybinds);
    c.lua_setfield(state, -2, "show_keybinds");

    c.lua_pushcfunction(state, luaSetMasterFactor);
    c.lua_setfield(state, -2, "set_master_factor");

    c.lua_pushcfunction(state, luaIncNumMaster);
    c.lua_setfield(state, -2, "inc_num_master");

    c.lua_pushcfunction(state, luaSetTagLayout);
    c.lua_setfield(state, -2, "set_tag_layout");

    c.lua_pushcfunction(state, luaSetFloatingPosition);
    c.lua_setfield(state, -2, "set_floating_position");
}

fn createActionTable(state: *c.lua_State, action_name: [*:0]const u8) void {
    c.lua_createtable(state, 0, 2);
    _ = c.lua_pushstring(state, action_name);
    c.lua_setfield(state, -2, "__action");
}

fn createActionTableWithInt(state: *c.lua_State, action_name: [*:0]const u8, arg: i32) void {
    c.lua_createtable(state, 0, 2);
    _ = c.lua_pushstring(state, action_name);
    c.lua_setfield(state, -2, "__action");
    c.lua_pushinteger(state, arg);
    c.lua_setfield(state, -2, "__arg");
}

fn createActionTableWithString(state: *c.lua_State, action_name: [*:0]const u8) void {
    c.lua_createtable(state, 0, 2);
    _ = c.lua_pushstring(state, action_name);
    c.lua_setfield(state, -2, "__action");
    c.lua_pushvalue(state, 1);
    c.lua_setfield(state, -2, "__arg");
}

fn luaSpawn(state: ?*c.lua_State) callconv(.c) c_int {
    const s = state orelse return 0;
    createActionTableWithString(s, "Spawn");
    return 1;
}

fn luaSpawnTerminal(state: ?*c.lua_State) callconv(.c) c_int {
    const s = state orelse return 0;
    createActionTable(s, "SpawnTerminal");
    return 1;
}

fn luaKeyBind(state: ?*c.lua_State) callconv(.c) c_int {
    const s = state orelse return 0;
    const cfg = config orelse return 0;

    const mod_mask = parseModifiers(s, 1);
    const key_str = getStringArg(s, 2) orelse return 0;
    const keysym = keynameToKeysym(key_str) orelse return 0;

    if (c.lua_type(s, 3) != c.LUA_TTABLE) return 0;

    _ = c.lua_getfield(s, 3, "__action");
    const action_str = getLuaString(s, -1) orelse {
        c.lua_settop(s, -2);
        return 0;
    };
    c.lua_settop(s, -2);

    const action = parseAction(action_str) orelse return 0;

    var int_arg: i32 = 0;
    var str_arg: ?[]const u8 = null;

    _ = c.lua_getfield(s, 3, "__arg");
    if (c.lua_type(s, -1) == c.LUA_TNUMBER) {
        int_arg = @intCast(c.lua_tointegerx(s, -1, null));
    } else if (c.lua_type(s, -1) == c.LUA_TSTRING) {
        str_arg = getLuaString(s, -1);
    } else if (c.lua_type(s, -1) == c.LUA_TTABLE) {
        str_arg = extractSpawnCommand(s, -1);
    }
    c.lua_settop(s, -2);

    var keybind: config_mod.Keybind = .{
        .action = action,
        .int_arg = int_arg,
        .str_arg = str_arg,
    };
    keybind.keys[0] = .{ .mod_mask = mod_mask, .keysym = keysym };
    keybind.key_count = 1;

    cfg.addKeybind(keybind) catch return 0;

    return 0;
}

fn luaKeyChord(state: ?*c.lua_State) callconv(.c) c_int {
    const s = state orelse return 0;
    const cfg = config orelse return 0;

    if (c.lua_type(s, 1) != c.LUA_TTABLE) return 0;
    if (c.lua_type(s, 2) != c.LUA_TTABLE) return 0;

    var keybind: config_mod.Keybind = .{
        .action = .quit,
        .int_arg = 0,
        .str_arg = null,
    };
    keybind.key_count = 0;

    const num_keys = c.lua_rawlen(s, 1);
    if (num_keys == 0 or num_keys > 4) return 0;

    var i: usize = 1;
    while (i <= num_keys) : (i += 1) {
        _ = c.lua_rawgeti(s, 1, @intCast(i));
        if (c.lua_type(s, -1) != c.LUA_TTABLE) {
            c.lua_settop(s, -2);
            return 0;
        }

        _ = c.lua_rawgeti(s, -1, 1);
        const mod_mask = parseModifiersAtTop(s);
        c.lua_settop(s, -2);

        _ = c.lua_rawgeti(s, -1, 2);
        const key_str = getLuaString(s, -1) orelse {
            c.lua_settop(s, -3);
            return 0;
        };
        c.lua_settop(s, -2);

        const keysym = keynameToKeysym(key_str) orelse {
            c.lua_settop(s, -2);
            return 0;
        };

        keybind.keys[keybind.key_count] = .{ .mod_mask = mod_mask, .keysym = keysym };
        keybind.key_count += 1;

        c.lua_settop(s, -2);
    }

    _ = c.lua_getfield(s, 2, "__action");
    const action_str = getLuaString(s, -1) orelse {
        c.lua_settop(s, -2);
        return 0;
    };
    c.lua_settop(s, -2);

    keybind.action = parseAction(action_str) orelse return 0;

    _ = c.lua_getfield(s, 2, "__arg");
    if (c.lua_type(s, -1) == c.LUA_TNUMBER) {
        keybind.int_arg = @intCast(c.lua_tointegerx(s, -1, null));
    } else if (c.lua_type(s, -1) == c.LUA_TSTRING) {
        keybind.str_arg = getLuaString(s, -1);
    } else if (c.lua_type(s, -1) == c.LUA_TTABLE) {
        keybind.str_arg = extractSpawnCommand(s, -1);
    }

    c.lua_settop(s, -2);
    cfg.addKeybind(keybind) catch return 0;

    return 0;
}

fn luaGapsSetEnabled(state: ?*c.lua_State) callconv(.c) c_int {
    const cfg = config orelse return 0;
    const s = state orelse return 0;
    cfg.gaps_enabled = c.lua_toboolean(s, 1) != 0;
    return 0;
}

fn luaGapsEnable(state: ?*c.lua_State) callconv(.c) c_int {
    _ = state;
    const cfg = config orelse return 0;
    cfg.gaps_enabled = true;
    return 0;
}

fn luaGapsDisable(state: ?*c.lua_State) callconv(.c) c_int {
    _ = state;
    const cfg = config orelse return 0;
    cfg.gaps_enabled = false;
    return 0;
}

fn luaGapsSetInner(state: ?*c.lua_State) callconv(.c) c_int {
    const cfg = config orelse return 0;
    const s = state orelse return 0;
    cfg.gap_inner_h = @intCast(c.lua_tointegerx(s, 1, null));
    cfg.gap_inner_v = @intCast(c.lua_tointegerx(s, 2, null));
    return 0;
}

fn luaGapsSetOuter(state: ?*c.lua_State) callconv(.c) c_int {
    const cfg = config orelse return 0;
    const s = state orelse return 0;
    cfg.gap_outer_h = @intCast(c.lua_tointegerx(s, 1, null));
    cfg.gap_outer_v = @intCast(c.lua_tointegerx(s, 2, null));
    return 0;
}

fn luaGapsSetSmart(state: ?*c.lua_State) callconv(.c) c_int {
    const cfg = config orelse return 0;
    const s = state orelse return 0;
    cfg.smartgaps_enabled = c.lua_toboolean(s, 1) != 0;
    return 0;
}

fn luaBorderSetWidth(state: ?*c.lua_State) callconv(.c) c_int {
    const cfg = config orelse return 0;
    const s = state orelse return 0;
    cfg.border_width = @intCast(c.lua_tointegerx(s, 1, null));
    return 0;
}

fn luaBorderSetFocusedColor(state: ?*c.lua_State) callconv(.c) c_int {
    const cfg = config orelse return 0;
    const s = state orelse return 0;
    cfg.border_focused = parseColor(s, 1);
    return 0;
}

fn luaBorderSetUnfocusedColor(state: ?*c.lua_State) callconv(.c) c_int {
    const cfg = config orelse return 0;
    const s = state orelse return 0;
    cfg.border_unfocused = parseColor(s, 1);
    return 0;
}

fn luaClientKill(state: ?*c.lua_State) callconv(.c) c_int {
    const s = state orelse return 0;
    createActionTable(s, "KillClient");
    return 1;
}

fn luaClientToggleFullscreen(state: ?*c.lua_State) callconv(.c) c_int {
    const s = state orelse return 0;
    createActionTable(s, "ToggleFullScreen");
    return 1;
}

fn luaClientToggleFloating(state: ?*c.lua_State) callconv(.c) c_int {
    const s = state orelse return 0;
    createActionTable(s, "ToggleFloating");
    return 1;
}

fn luaClientFocusStack(state: ?*c.lua_State) callconv(.c) c_int {
    const s = state orelse return 0;
    const dir: i32 = @intCast(c.lua_tointegerx(s, 1, null));
    createActionTableWithInt(s, "FocusStack", dir);
    return 1;
}

fn luaClientMoveStack(state: ?*c.lua_State) callconv(.c) c_int {
    const s = state orelse return 0;
    const dir: i32 = @intCast(c.lua_tointegerx(s, 1, null));
    createActionTableWithInt(s, "MoveStack", dir);
    return 1;
}

fn luaLayoutCycle(state: ?*c.lua_State) callconv(.c) c_int {
    const s = state orelse return 0;
    createActionTable(s, "CycleLayout");
    return 1;
}

fn luaLayoutSet(state: ?*c.lua_State) callconv(.c) c_int {
    const s = state orelse return 0;
    createActionTableWithString(s, "ChangeLayout");
    return 1;
}

fn luaLayoutScrollLeft(state: ?*c.lua_State) callconv(.c) c_int {
    const s = state orelse return 0;
    createActionTable(s, "ScrollLeft");
    return 1;
}

fn luaLayoutScrollRight(state: ?*c.lua_State) callconv(.c) c_int {
    const s = state orelse return 0;
    createActionTable(s, "ScrollRight");
    return 1;
}

fn luaTagView(state: ?*c.lua_State) callconv(.c) c_int {
    const s = state orelse return 0;
    const idx: i32 = @intCast(c.lua_tointegerx(s, 1, null));
    createActionTableWithInt(s, "ViewTag", idx);
    return 1;
}

fn luaTagViewNext(state: ?*c.lua_State) callconv(.c) c_int {
    const s = state orelse return 0;
    createActionTable(s, "ViewNextTag");
    return 1;
}

fn luaTagViewPrevious(state: ?*c.lua_State) callconv(.c) c_int {
    const s = state orelse return 0;
    createActionTable(s, "ViewPreviousTag");
    return 1;
}

fn luaTagViewNextNonempty(state: ?*c.lua_State) callconv(.c) c_int {
    const s = state orelse return 0;
    createActionTable(s, "ViewNextNonEmptyTag");
    return 1;
}

fn luaTagViewPreviousNonempty(state: ?*c.lua_State) callconv(.c) c_int {
    const s = state orelse return 0;
    createActionTable(s, "ViewPreviousNonEmptyTag");
    return 1;
}

fn luaTagToggleview(state: ?*c.lua_State) callconv(.c) c_int {
    const s = state orelse return 0;
    const idx: i32 = @intCast(c.lua_tointegerx(s, 1, null));
    createActionTableWithInt(s, "ToggleView", idx);
    return 1;
}

fn luaTagMoveTo(state: ?*c.lua_State) callconv(.c) c_int {
    const s = state orelse return 0;
    const idx: i32 = @intCast(c.lua_tointegerx(s, 1, null));
    createActionTableWithInt(s, "MoveToTag", idx);
    return 1;
}

fn luaTagToggletag(state: ?*c.lua_State) callconv(.c) c_int {
    const s = state orelse return 0;
    const idx: i32 = @intCast(c.lua_tointegerx(s, 1, null));
    createActionTableWithInt(s, "ToggleTag", idx);
    return 1;
}

fn luaTagSetBackAndForth(state: ?*c.lua_State) callconv(.c) c_int {
    const cfg = config orelse return 0;
    const s = state orelse return 0;
    cfg.tag_back_and_forth = c.lua_toboolean(s, 1) != 0;
    return 0;
}

fn luaMonitorFocus(state: ?*c.lua_State) callconv(.c) c_int {
    const s = state orelse return 0;
    const dir: i32 = @intCast(c.lua_tointegerx(s, 1, null));
    createActionTableWithInt(s, "FocusMonitor", dir);
    return 1;
}

fn luaMonitorTag(state: ?*c.lua_State) callconv(.c) c_int {
    const s = state orelse return 0;
    const dir: i32 = @intCast(c.lua_tointegerx(s, 1, null));
    createActionTableWithInt(s, "TagMonitor", dir);
    return 1;
}

fn luaRuleAdd(state: ?*c.lua_State) callconv(.c) c_int {
    const cfg = config orelse return 0;
    const s = state orelse return 0;

    if (c.lua_type(s, 1) != c.LUA_TTABLE) return 0;

    var rule = Rule{
        .class = null,
        .instance = null,
        .title = null,
        .tags = 0,
        .is_floating = false,
        .monitor = -1,
        .focus = false,
    };

    _ = c.lua_getfield(s, 1, "class");
    if (c.lua_type(s, -1) == c.LUA_TSTRING) {
        rule.class = getLuaString(s, -1);
    }
    c.lua_settop(s, -2);

    _ = c.lua_getfield(s, 1, "instance");
    if (c.lua_type(s, -1) == c.LUA_TSTRING) {
        rule.instance = getLuaString(s, -1);
    }
    c.lua_settop(s, -2);

    _ = c.lua_getfield(s, 1, "title");
    if (c.lua_type(s, -1) == c.LUA_TSTRING) {
        rule.title = getLuaString(s, -1);
    }
    c.lua_settop(s, -2);

    _ = c.lua_getfield(s, 1, "tag");
    if (c.lua_type(s, -1) == c.LUA_TNUMBER) {
        const tag_idx: i32 = @intCast(c.lua_tointegerx(s, -1, null));
        if (tag_idx > 0) {
            rule.tags = @as(u32, 1) << @intCast(tag_idx - 1);
        }
    }
    c.lua_settop(s, -2);

    _ = c.lua_getfield(s, 1, "floating");
    if (c.lua_type(s, -1) == c.LUA_TBOOLEAN) {
        rule.is_floating = c.lua_toboolean(s, -1) != 0;
    }
    c.lua_settop(s, -2);

    _ = c.lua_getfield(s, 1, "monitor");
    if (c.lua_type(s, -1) == c.LUA_TNUMBER) {
        rule.monitor = @intCast(c.lua_tointegerx(s, -1, null));
    }
    c.lua_settop(s, -2);

    _ = c.lua_getfield(s, 1, "focus");
    if (c.lua_type(s, -1) == c.LUA_TBOOLEAN) {
        rule.focus = c.lua_toboolean(s, -1) != 0;
    }
    c.lua_settop(s, -2);

    cfg.addRule(rule) catch return 0;
    return 0;
}

fn luaBarSetFont(state: ?*c.lua_State) callconv(.c) c_int {
    const cfg = config orelse return 0;
    const s = state orelse return 0;
    if (dupeLuaString(s, 1)) |font| {
        cfg.font = font;
    }
    return 0;
}

fn luaBarSetPosition(state: ?*c.lua_State) callconv(.c) c_int {
    const cfg = config orelse return 0;
    const s = state orelse return 0;
    if (dupeLuaString(s, 1)) |position| {
        cfg.bar_position = position;
    }
    return 0;
}

fn luaBarSetBlocks(state: ?*c.lua_State) callconv(.c) c_int {
    const cfg = config orelse return 0;
    const s = state orelse return 0;

    if (c.lua_type(s, 1) != c.LUA_TTABLE) return 0;

    const len = c.lua_rawlen(s, 1);
    var i: usize = 1;
    while (i <= len) : (i += 1) {
        _ = c.lua_rawgeti(s, 1, @intCast(i));

        if (c.lua_type(s, -1) != c.LUA_TTABLE) {
            c.lua_settop(s, -2);
            continue;
        }

        if (parseBlockConfig(s, -1)) |block| {
            cfg.addBlock(block) catch {};
        }

        c.lua_settop(s, -2);
    }

    return 0;
}

fn parseBlockConfig(state: *c.lua_State, idx: c_int) ?Block {
    _ = c.lua_getfield(state, idx, "__block_type");
    const block_type_str = getLuaString(state, -1) orelse {
        c.lua_settop(state, -2);
        return null;
    };
    c.lua_settop(state, -2);

    _ = c.lua_getfield(state, idx, "format");
    const format = dupeLuaString(state, -1) orelse "";
    c.lua_settop(state, -2);

    _ = c.lua_getfield(state, idx, "interval");
    const interval: u32 = @intCast(c.lua_tointegerx(state, -1, null));
    c.lua_settop(state, -2);

    _ = c.lua_getfield(state, idx, "color");
    const color = parseColor(state, -1);
    c.lua_settop(state, -2);

    _ = c.lua_getfield(state, idx, "bg");
    const bg = parseColor(state, -1);
    c.lua_settop(state, -2);

    _ = c.lua_getfield(state, idx, "underline");
    const underline = c.lua_toboolean(state, -1) != 0;
    c.lua_settop(state, -2);

    _ = c.lua_getfield(state, idx, "click");
    const click = parseClickAction(state, -1);
    c.lua_settop(state, -2);

    var block = Block{
        .block_type = .static,
        .format = format,
        .interval = interval,
        .color = color,
        .bg = bg,
        .underline = underline,
        .click = click,
    };

    if (std.mem.eql(u8, block_type_str, "Ram")) {
        block.block_type = .ram;
    } else if (std.mem.eql(u8, block_type_str, "DateTime")) {
        block.block_type = .datetime;
        _ = c.lua_getfield(state, idx, "__arg");
        block.datetime_format = dupeLuaString(state, -1);
        c.lua_settop(state, -2);
    } else if (std.mem.eql(u8, block_type_str, "Shell")) {
        block.block_type = .shell;
        _ = c.lua_getfield(state, idx, "__arg");
        block.command = dupeLuaString(state, -1);
        c.lua_settop(state, -2);
    } else if (std.mem.eql(u8, block_type_str, "Static")) {
        block.block_type = .static;
        _ = c.lua_getfield(state, idx, "__arg");
        if (dupeLuaString(state, -1)) |text| {
            block.format = text;
        }
        c.lua_settop(state, -2);
    } else if (std.mem.eql(u8, block_type_str, "Battery")) {
        block.block_type = .battery;
        _ = c.lua_getfield(state, idx, "__arg");
        if (c.lua_type(state, -1) == c.LUA_TTABLE) {
            _ = c.lua_getfield(state, -1, "charging");
            block.format_charging = dupeLuaString(state, -1);
            c.lua_settop(state, -2);

            _ = c.lua_getfield(state, -1, "discharging");
            block.format_discharging = dupeLuaString(state, -1);
            c.lua_settop(state, -2);

            _ = c.lua_getfield(state, -1, "full");
            block.format_full = dupeLuaString(state, -1);
            c.lua_settop(state, -2);

            _ = c.lua_getfield(state, -1, "battery_name");
            block.battery_name = dupeLuaString(state, -1);
            c.lua_settop(state, -2);
        }
        c.lua_settop(state, -2);
    } else {
        return null;
    }

    return block;
}

fn luaBarSetSchemeNormal(state: ?*c.lua_State) callconv(.c) c_int {
    const cfg = config orelse return 0;
    const s = state orelse return 0;
    cfg.scheme_normal = parseScheme(s);
    return 0;
}

fn luaBarSetSchemeSelected(state: ?*c.lua_State) callconv(.c) c_int {
    const cfg = config orelse return 0;
    const s = state orelse return 0;
    cfg.scheme_selected = parseScheme(s);
    return 0;
}

fn luaBarSetSchemeOccupied(state: ?*c.lua_State) callconv(.c) c_int {
    const cfg = config orelse return 0;
    const s = state orelse return 0;
    cfg.scheme_occupied = parseScheme(s);
    return 0;
}

fn luaBarSetSchemeUrgent(state: ?*c.lua_State) callconv(.c) c_int {
    const cfg = config orelse return 0;
    const s = state orelse return 0;
    cfg.scheme_urgent = parseScheme(s);
    return 0;
}

fn luaBarSetHideVacantTags(state: ?*c.lua_State) callconv(.c) c_int {
    const cfg = config orelse return 0;
    const s = state orelse return 0;
    cfg.hide_vacant_tags = c.lua_toboolean(s, 1) != 0;
    return 0;
}

fn luaBarBlockRam(state: ?*c.lua_State) callconv(.c) c_int {
    const s = state orelse return 0;
    createBlockTable(s, "Ram", null);
    return 1;
}

fn luaBarBlockDatetime(state: ?*c.lua_State) callconv(.c) c_int {
    const s = state orelse return 0;
    _ = c.lua_getfield(s, 1, "date_format");
    const date_format = getLuaString(s, -1);
    c.lua_settop(s, -2);
    createBlockTable(s, "DateTime", date_format);
    return 1;
}

fn luaBarBlockShell(state: ?*c.lua_State) callconv(.c) c_int {
    const s = state orelse return 0;
    _ = c.lua_getfield(s, 1, "command");
    const command = getLuaString(s, -1);
    c.lua_settop(s, -2);
    createBlockTable(s, "Shell", command);
    return 1;
}

fn luaBarBlockStatic(state: ?*c.lua_State) callconv(.c) c_int {
    const s = state orelse return 0;
    _ = c.lua_getfield(s, 1, "text");
    const text = getLuaString(s, -1);
    c.lua_settop(s, -2);
    createBlockTable(s, "Static", text);
    return 1;
}

fn luaBarBlockBattery(state: ?*c.lua_State) callconv(.c) c_int {
    const s = state orelse return 0;

    c.lua_createtable(s, 0, 7);

    _ = c.lua_pushstring(s, "Battery");
    c.lua_setfield(s, -2, "__block_type");

    _ = c.lua_getfield(s, 1, "format");
    c.lua_setfield(s, -2, "format");

    _ = c.lua_getfield(s, 1, "interval");
    c.lua_setfield(s, -2, "interval");

    _ = c.lua_getfield(s, 1, "color");
    c.lua_setfield(s, -2, "color");

    _ = c.lua_getfield(s, 1, "bg");
    c.lua_setfield(s, -2, "bg");

    _ = c.lua_getfield(s, 1, "underline");
    c.lua_setfield(s, -2, "underline");

    _ = c.lua_getfield(s, 1, "click");
    c.lua_setfield(s, -2, "click");

    c.lua_createtable(s, 0, 4);
    _ = c.lua_getfield(s, 1, "charging");
    c.lua_setfield(s, -2, "charging");
    _ = c.lua_getfield(s, 1, "discharging");
    c.lua_setfield(s, -2, "discharging");
    _ = c.lua_getfield(s, 1, "full");
    c.lua_setfield(s, -2, "full");
    _ = c.lua_getfield(s, 1, "battery_name");
    c.lua_setfield(s, -2, "battery_name");
    c.lua_setfield(s, -2, "__arg");

    return 1;
}

fn createBlockTable(state: *c.lua_State, block_type: [*:0]const u8, arg: ?[]const u8) void {
    c.lua_createtable(state, 0, 7);

    _ = c.lua_pushstring(state, block_type);
    c.lua_setfield(state, -2, "__block_type");

    _ = c.lua_getfield(state, 1, "format");
    c.lua_setfield(state, -2, "format");

    _ = c.lua_getfield(state, 1, "interval");
    c.lua_setfield(state, -2, "interval");

    _ = c.lua_getfield(state, 1, "color");
    c.lua_setfield(state, -2, "color");

    _ = c.lua_getfield(state, 1, "bg");
    c.lua_setfield(state, -2, "bg");

    _ = c.lua_getfield(state, 1, "underline");
    c.lua_setfield(state, -2, "underline");

    _ = c.lua_getfield(state, 1, "click");
    c.lua_setfield(state, -2, "click");

    if (arg) |a| {
        var buf: [256]u8 = undefined;
        if (a.len < buf.len) {
            @memcpy(buf[0..a.len], a);
            buf[a.len] = 0;
            _ = c.lua_pushstring(state, &buf);
            c.lua_setfield(state, -2, "__arg");
        }
    }
}

fn luaSetFloatingPosition(state: ?*c.lua_State) callconv(.c) c_int {
    const cfg = config orelse return 0;
    const s = state orelse return 0;
    if (getLuaString(s, 1)) |name| {
        if (config_mod.FloatingPosition.fromString(name)) |pos| {
            cfg.floating_position = pos;
        }
    }
    return 0;
}

fn luaSetTerminal(state: ?*c.lua_State) callconv(.c) c_int {
    const cfg = config orelse return 0;
    const s = state orelse return 0;
    if (dupeLuaString(s, 1)) |term| {
        cfg.terminal = term;
    }
    return 0;
}

fn luaSetLayout(state: ?*c.lua_State) callconv(.c) c_int {
    const cfg = config orelse return 0;
    const s = state orelse return 0;
    const name = getStringArg(s, 1) orelse return 0;
    if (config_mod.Layouts.fromString(name) == null) {
        std.debug.print("set_layout: unknown layout '{s}'\n", .{name});
        return 0;
    }
    if (dupeLuaString(s, 1)) |layout| {
        cfg.layout = layout;
    }
    return 0;
}

fn luaSetModkey(state: ?*c.lua_State) callconv(.c) c_int {
    const cfg = config orelse return 0;
    const s = state orelse return 0;
    if (getStringArg(s, 1)) |modkey_str| {
        cfg.modkey = parseSingleModifier(modkey_str);
        cfg.addButton(.{
            .click = .client_win,
            .mod_mask = cfg.modkey,
            .button = 1,
            .action = .move_mouse,
        }) catch {};
        cfg.addButton(.{
            .click = .client_win,
            .mod_mask = cfg.modkey,
            .button = 3,
            .action = .resize_mouse,
        }) catch {};
    }
    return 0;
}

fn luaSetTags(state: ?*c.lua_State) callconv(.c) c_int {
    const cfg = config orelse return 0;
    const s = state orelse return 0;

    if (c.lua_type(s, 1) != c.LUA_TTABLE) return 0;

    const len = c.lua_rawlen(s, 1);
    var i: usize = 0;
    while (i < len and i < 9) : (i += 1) {
        _ = c.lua_rawgeti(s, 1, @intCast(i + 1));
        if (dupeLuaString(s, -1)) |tag_str| {
            cfg.tags[i] = tag_str;
        }
        c.lua_settop(s, -2);
    }

    return 0;
}

fn luaAutostart(state: ?*c.lua_State) callconv(.c) c_int {
    const cfg = config orelse return 0;
    const s = state orelse return 0;
    if (dupeLuaString(s, 1)) |cmd| {
        cfg.addAutostart(cmd) catch return 0;
    }
    return 0;
}

fn luaAutoTile(state: ?*c.lua_State) callconv(.c) c_int {
    const cfg = config orelse return 0;
    const s = state orelse return 0;
    cfg.auto_tile = c.lua_toboolean(s, 1) != 0;
    return 0;
}

fn luaTiledResizeMode(state: ?*c.lua_State) callconv(.c) c_int {
    const cfg = config orelse return 0;
    const s = state orelse return 0;
    cfg.tiled_resize_mode = c.lua_toboolean(s, 1) != 0;
    return 0;
}

fn luaSetLayoutSymbol(state: ?*c.lua_State) callconv(.c) c_int {
    const cfg = config orelse return 0;
    const s = state orelse return 0;
    const name = getStringArg(s, 1) orelse return 0;
    const symbol = dupeLuaString(s, 2) orelse return 0;

    const layout = config_mod.Layouts.fromString(name) orelse return 0;
    switch (layout) {
        .tiling => cfg.layout_tile_symbol = symbol,
        .monocle => cfg.layout_monocle_symbol = symbol,
        .floating => cfg.layout_floating_symbol = symbol,
        .scrolling => cfg.layout_scrolling_symbol = symbol,
        .grid => cfg.layout_grid_symbol = symbol,
    }
    return 0;
}

fn luaSetTagLayout(state: ?*c.lua_State) callconv(.c) c_int {
    const cfg = config orelse return 0;
    const s = state orelse return 0;
    const tag_index = c.lua_tointegerx(s, 1, null);
    if (tag_index < 1 or tag_index > 9) return 0;
    const name = getStringArg(s, 2) orelse return 0;
    if (config_mod.Layouts.fromString(name) == null) {
        std.debug.print("set_tag_layout: unknown layout '{s}'\n", .{name});
        return 0;
    }
    if (dupeLuaString(s, 2)) |layout_str| {
        cfg.tag_layouts[@intCast(tag_index - 1)] = layout_str;
    }
    return 0;
}

fn luaQuit(state: ?*c.lua_State) callconv(.c) c_int {
    const s = state orelse return 0;
    createActionTable(s, "Quit");
    return 1;
}

fn luaRestart(state: ?*c.lua_State) callconv(.c) c_int {
    const s = state orelse return 0;
    createActionTable(s, "Restart");
    return 1;
}

fn luaToggleGaps(state: ?*c.lua_State) callconv(.c) c_int {
    const s = state orelse return 0;
    createActionTable(s, "ToggleGaps");
    return 1;
}

fn luaToggleBar(state: ?*c.lua_State) callconv(.c) c_int {
    const s = state orelse return 0;
    createActionTable(s, "ToggleBar");
    return 1;
}

fn luaShowKeybinds(state: ?*c.lua_State) callconv(.c) c_int {
    const s = state orelse return 0;
    createActionTable(s, "ShowKeybinds");
    return 1;
}

fn luaSetMasterFactor(state: ?*c.lua_State) callconv(.c) c_int {
    const s = state orelse return 0;
    const delta: i32 = @intCast(c.lua_tointegerx(s, 1, null));
    createActionTableWithInt(s, "ResizeMaster", delta);
    return 1;
}

fn luaIncNumMaster(state: ?*c.lua_State) callconv(.c) c_int {
    const s = state orelse return 0;
    const delta: i32 = @intCast(c.lua_tointegerx(s, 1, null));
    if (delta > 0) {
        createActionTable(s, "IncMaster");
    } else {
        createActionTable(s, "DecMaster");
    }
    return 1;
}

fn getStringArg(state: *c.lua_State, idx: c_int) ?[]const u8 {
    if (c.lua_type(state, idx) != c.LUA_TSTRING) return null;
    return getLuaString(state, idx);
}

fn extractSpawnCommand(state: *c.lua_State, idx: c_int) ?[]const u8 {
    const len = c.lua_rawlen(state, idx);
    if (len == 0) return null;

    if (len >= 3) {
        _ = c.lua_rawgeti(state, idx, 1);
        const first = getLuaString(state, -1);
        c.lua_settop(state, -2);

        _ = c.lua_rawgeti(state, idx, 2);
        const second = getLuaString(state, -1);
        c.lua_settop(state, -2);

        if (first != null and second != null and
            std.mem.eql(u8, first.?, "sh") and std.mem.eql(u8, second.?, "-c"))
        {
            _ = c.lua_rawgeti(state, idx, 3);
            const cmd = getLuaString(state, -1);
            c.lua_settop(state, -2);
            return cmd;
        }
    }

    _ = c.lua_rawgeti(state, idx, 1);
    const first_elem = getLuaString(state, -1);
    c.lua_settop(state, -2);
    return first_elem;
}

fn getLuaString(state: *c.lua_State, idx: c_int) ?[]const u8 {
    const cstr = c.lua_tolstring(state, idx, null);
    if (cstr == null) return null;
    return std.mem.span(cstr);
}

fn dupeLuaString(state: *c.lua_State, idx: c_int) ?[]const u8 {
    const cfg = config orelse return null;
    const lua_str = getLuaString(state, idx) orelse return null;
    const arena_allocator = cfg.string_arena.allocator();
    const duped = arena_allocator.dupe(u8, lua_str) catch return null;
    return duped;
}

fn parseClickAction(state: *c.lua_State, idx: c_int) ?config_mod.ClickAction {
    const lua_type = c.lua_type(state, idx);
    if (lua_type == c.LUA_TSTRING) {
        const cmd = dupeLuaString(state, idx) orelse return null;
        return .{ .command = cmd };
    } else if (lua_type == c.LUA_TTABLE) {
        _ = c.lua_getfield(state, idx, "command");
        const cmd = dupeLuaString(state, -1);
        c.lua_settop(state, -2);
        if (cmd == null) return null;

        _ = c.lua_getfield(state, idx, "floating");
        const floating = c.lua_toboolean(state, -1) != 0;
        c.lua_settop(state, -2);

        _ = c.lua_getfield(state, idx, "bypass_rules");
        const bypass_rules = c.lua_toboolean(state, -1) != 0;
        c.lua_settop(state, -2);

        return .{ .command = cmd.?, .floating = floating, .bypass_rules = bypass_rules };
    }
    return null;
}

fn parseColor(state: *c.lua_State, idx: c_int) u32 {
    const lua_type = c.lua_type(state, idx);
    if (lua_type == c.LUA_TNUMBER) {
        return @intCast(c.lua_tointegerx(state, idx, null));
    }
    if (lua_type == c.LUA_TSTRING) {
        const str = getLuaString(state, idx) orelse return 0;
        if (str.len > 0 and str[0] == '#') {
            return std.fmt.parseInt(u32, str[1..], 16) catch return 0;
        }
        if (str.len > 2 and str[0] == '0' and str[1] == 'x') {
            return std.fmt.parseInt(u32, str[2..], 16) catch return 0;
        }
        return std.fmt.parseInt(u32, str, 16) catch return 0;
    }
    return 0;
}

fn parseScheme(state: *c.lua_State) ColorScheme {
    return ColorScheme{
        .foreground = parseColor(state, 1),
        .background = parseColor(state, 2),
        .border = parseColor(state, 3),
    };
}

fn parseModifiers(state: *c.lua_State, idx: c_int) u32 {
    var mod_mask: u32 = 0;

    if (c.lua_type(state, idx) != c.LUA_TTABLE) return mod_mask;

    const len = c.lua_rawlen(state, idx);
    var i: usize = 1;
    while (i <= len) : (i += 1) {
        _ = c.lua_rawgeti(state, idx, @intCast(i));
        if (getLuaString(state, -1)) |mod_str| {
            const parsed = parseSingleModifier(mod_str);
            mod_mask |= parsed;
        }
        c.lua_settop(state, -2);
    }

    return mod_mask;
}

fn parseModifiersAtTop(state: *c.lua_State) u32 {
    return parseModifiers(state, -1);
}

fn parseSingleModifier(name: []const u8) u32 {
    if (std.mem.eql(u8, name, "Mod4") or std.mem.eql(u8, name, "mod4") or std.mem.eql(u8, name, "super")) {
        return (1 << 6);
    } else if (std.mem.eql(u8, name, "Mod1") or std.mem.eql(u8, name, "mod1") or std.mem.eql(u8, name, "alt")) {
        return (1 << 3);
    } else if (std.mem.eql(u8, name, "Shift") or std.mem.eql(u8, name, "shift")) {
        return (1 << 0);
    } else if (std.mem.eql(u8, name, "Control") or std.mem.eql(u8, name, "control") or std.mem.eql(u8, name, "ctrl")) {
        return (1 << 2);
    }
    return 0;
}

fn parseAction(name: []const u8) ?Action {
    const action_map = .{
        .{ "Spawn", Action.spawn },
        .{ "SpawnTerminal", Action.spawn_terminal },
        .{ "KillClient", Action.kill_client },
        .{ "Quit", Action.quit },
        .{ "Restart", Action.restart },
        .{ "ShowKeybinds", Action.show_keybinds },
        .{ "FocusStack", Action.focus_next },
        .{ "MoveStack", Action.move_next },
        .{ "ResizeMaster", Action.resize_master },
        .{ "IncMaster", Action.inc_master },
        .{ "DecMaster", Action.dec_master },
        .{ "ToggleFloating", Action.toggle_floating },
        .{ "ToggleFullScreen", Action.toggle_fullscreen },
        .{ "ToggleGaps", Action.toggle_gaps },
        .{ "ToggleBar", Action.toggle_bar },
        .{ "CycleLayout", Action.cycle_layout },
        .{ "ChangeLayout", Action.set_layout },
        .{ "ViewTag", Action.view_tag },
        .{ "ViewNextTag", Action.view_next_tag },
        .{ "ViewPreviousTag", Action.view_prev_tag },
        .{ "ViewNextNonEmptyTag", Action.view_next_nonempty_tag },
        .{ "ViewPreviousNonEmptyTag", Action.view_prev_nonempty_tag },
        .{ "MoveToTag", Action.move_to_tag },
        .{ "ToggleView", Action.toggle_view_tag },
        .{ "ToggleTag", Action.toggle_tag },
        .{ "FocusMonitor", Action.focus_monitor },
        .{ "TagMonitor", Action.send_to_monitor },
        .{ "ScrollLeft", Action.scroll_left },
        .{ "ScrollRight", Action.scroll_right },
    };

    inline for (action_map) |entry| {
        if (std.mem.eql(u8, name, entry[0])) {
            return entry[1];
        }
    }
    return null;
}

fn keynameToKeysym(name: []const u8) ?u64 {
    const key_map = .{
        .{ "Return", 0xff0d },
        .{ "Enter", 0xff0d },
        .{ "Tab", 0xff09 },
        .{ "Escape", 0xff1b },
        .{ "BackSpace", 0xff08 },
        .{ "Delete", 0xffff },
        .{ "space", 0x0020 },
        .{ "Space", 0x0020 },
        .{ "comma", 0x002c },
        .{ "Comma", 0x002c },
        .{ "period", 0x002e },
        .{ "Period", 0x002e },
        .{ "slash", 0x002f },
        .{ "Slash", 0x002f },
        .{ "minus", 0x002d },
        .{ "Minus", 0x002d },
        .{ "equal", 0x003d },
        .{ "Equal", 0x003d },
        .{ "bracketleft", 0x005b },
        .{ "bracketright", 0x005d },
        .{ "backslash", 0x005c },
        .{ "colon", 0x003a },
        .{ "semicolon", 0x003b },
        .{ "apostrophe", 0x0027 },
        .{ "quotedbl", 0x0022 },
        .{ "ampersand", 0x0026 },
        .{ "parenleft", 0x0028 },
        .{ "parenright", 0x0029 },
        .{ "underscore", 0x005f },
        .{ "grave", 0x0060 },
        .{ "agrave", 0x00e0 },
        .{ "egrave", 0x00e8 },
        .{ "ccedilla", 0x00e7 },
        .{ "eacute", 0x00e9 },
        .{ "Left", 0xff51 },
        .{ "Up", 0xff52 },
        .{ "Right", 0xff53 },
        .{ "Down", 0xff54 },
        .{ "F1", 0xffbe },
        .{ "F2", 0xffbf },
        .{ "F3", 0xffc0 },
        .{ "F4", 0xffc1 },
        .{ "F5", 0xffc2 },
        .{ "F6", 0xffc3 },
        .{ "F7", 0xffc4 },
        .{ "F8", 0xffc5 },
        .{ "F9", 0xffc6 },
        .{ "F10", 0xffc7 },
        .{ "F11", 0xffc8 },
        .{ "F12", 0xffc9 },
        .{ "Print", 0xff61 },
        .{ "XF86AudioRaiseVolume", 0x1008ff13 },
        .{ "XF86AudioLowerVolume", 0x1008ff11 },
        .{ "XF86AudioMute", 0x1008ff12 },
        .{ "XF86AudioPlay", 0x1008ff14 },
        .{ "XF86AudioPause", 0x1008ff31 },
        .{ "XF86AudioNext", 0x1008ff17 },
        .{ "XF86AudioPrev", 0x1008ff16 },
        .{ "XF86MonBrightnessUp", 0x1008ff02 },
        .{ "XF86MonBrightnessDown", 0x1008ff03 },
    };

    inline for (key_map) |entry| {
        if (std.mem.eql(u8, name, entry[0])) {
            return entry[1];
        }
    }

    if (name.len == 1) {
        const char = name[0];
        if (char >= 'a' and char <= 'z') {
            return char;
        }
        if (char >= 'A' and char <= 'Z') {
            return char + 32;
        }
        if (char >= '0' and char <= '9') {
            return char;
        }
    }

    return null;
}
