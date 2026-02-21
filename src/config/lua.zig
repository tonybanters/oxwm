const std = @import("std");
pub const config_mod = @import("config.zig");
const Config = config_mod.Config;
const Keybind = config_mod.Keybind;
const Action = config_mod.Action;
const Rule = config_mod.Rule;
const Block = config_mod.Block;
const Block_Type = config_mod.Block_Type;
const Mouse_Button = config_mod.Mouse_Button;
const Click_Target = config_mod.Click_Target;
const Mouse_Action = config_mod.Mouse_Action;
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
    register_api();
    return true;
}

pub fn deinit() void {
    if (L) |state| {
        c.lua_close(state);
    }
    L = null;
    config = null;
}

pub fn load_file(path: []const u8) bool {
    const state = L orelse return false;
    var path_buf: [512]u8 = undefined;
    if (path.len >= path_buf.len) return false;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;

    if (std.mem.lastIndexOfScalar(u8, path, '/')) |last_slash| {
        const dir = path[0..last_slash];
        var setup_buf: [600]u8 = undefined;
        const setup_code = std.fmt.bufPrint(&setup_buf, "package.path = '{s}/?.lua;' .. package.path\x00", .{dir}) catch return false;
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

pub fn load_config() bool {
    const home = std.posix.getenv("HOME") orelse return false;
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/.config/oxwm/config.lua", .{home}) catch return false;
    return load_file(path);
}

fn register_api() void {
    const state = L orelse return;

    c.lua_createtable(state, 0, 16);

    register_spawn_functions(state);
    register_key_module(state);
    register_gaps_module(state);
    register_border_module(state);
    register_client_module(state);
    register_layout_module(state);
    register_tag_module(state);
    register_monitor_module(state);
    register_rule_module(state);
    register_bar_module(state);
    register_misc_functions(state);

    c.lua_setglobal(state, "oxwm");
}

fn register_spawn_functions(state: *c.lua_State) void {
    c.lua_pushcfunction(state, lua_spawn);
    c.lua_setfield(state, -2, "spawn");

    c.lua_pushcfunction(state, lua_spawn_terminal);
    c.lua_setfield(state, -2, "spawn_terminal");
}

fn register_key_module(state: *c.lua_State) void {
    c.lua_createtable(state, 0, 2);

    c.lua_pushcfunction(state, lua_key_bind);
    c.lua_setfield(state, -2, "bind");

    c.lua_pushcfunction(state, lua_key_chord);
    c.lua_setfield(state, -2, "chord");

    c.lua_setfield(state, -2, "key");
}

fn register_gaps_module(state: *c.lua_State) void {
    c.lua_createtable(state, 0, 6);

    c.lua_pushcfunction(state, lua_gaps_set_enabled);
    c.lua_setfield(state, -2, "set_enabled");

    c.lua_pushcfunction(state, lua_gaps_enable);
    c.lua_setfield(state, -2, "enable");

    c.lua_pushcfunction(state, lua_gaps_disable);
    c.lua_setfield(state, -2, "disable");

    c.lua_pushcfunction(state, lua_gaps_set_inner);
    c.lua_setfield(state, -2, "set_inner");

    c.lua_pushcfunction(state, lua_gaps_set_outer);
    c.lua_setfield(state, -2, "set_outer");

    c.lua_pushcfunction(state, lua_gaps_set_smart);
    c.lua_setfield(state, -2, "set_smart");

    c.lua_setfield(state, -2, "gaps");
}

fn register_border_module(state: *c.lua_State) void {
    c.lua_createtable(state, 0, 3);

    c.lua_pushcfunction(state, lua_border_set_width);
    c.lua_setfield(state, -2, "set_width");

    c.lua_pushcfunction(state, lua_border_set_focused_color);
    c.lua_setfield(state, -2, "set_focused_color");

    c.lua_pushcfunction(state, lua_border_set_unfocused_color);
    c.lua_setfield(state, -2, "set_unfocused_color");

    c.lua_setfield(state, -2, "border");
}

fn register_client_module(state: *c.lua_State) void {
    c.lua_createtable(state, 0, 5);

    c.lua_pushcfunction(state, lua_client_kill);
    c.lua_setfield(state, -2, "kill");

    c.lua_pushcfunction(state, lua_client_toggle_fullscreen);
    c.lua_setfield(state, -2, "toggle_fullscreen");

    c.lua_pushcfunction(state, lua_client_toggle_floating);
    c.lua_setfield(state, -2, "toggle_floating");

    c.lua_pushcfunction(state, lua_client_focus_stack);
    c.lua_setfield(state, -2, "focus_stack");

    c.lua_pushcfunction(state, lua_client_move_stack);
    c.lua_setfield(state, -2, "move_stack");

    c.lua_setfield(state, -2, "client");
}

fn register_layout_module(state: *c.lua_State) void {
    c.lua_createtable(state, 0, 4);

    c.lua_pushcfunction(state, lua_layout_cycle);
    c.lua_setfield(state, -2, "cycle");

    c.lua_pushcfunction(state, lua_layout_set);
    c.lua_setfield(state, -2, "set");

    c.lua_pushcfunction(state, lua_layout_scroll_left);
    c.lua_setfield(state, -2, "scroll_left");

    c.lua_pushcfunction(state, lua_layout_scroll_right);
    c.lua_setfield(state, -2, "scroll_right");

    c.lua_setfield(state, -2, "layout");
}

fn register_tag_module(state: *c.lua_State) void {
    c.lua_createtable(state, 0, 10);

    c.lua_pushcfunction(state, lua_tag_view);
    c.lua_setfield(state, -2, "view");

    c.lua_pushcfunction(state, lua_tag_view_next);
    c.lua_setfield(state, -2, "view_next");

    c.lua_pushcfunction(state, lua_tag_view_previous);
    c.lua_setfield(state, -2, "view_previous");

    c.lua_pushcfunction(state, lua_tag_view_next_nonempty);
    c.lua_setfield(state, -2, "view_next_nonempty");

    c.lua_pushcfunction(state, lua_tag_view_previous_nonempty);
    c.lua_setfield(state, -2, "view_previous_nonempty");

    c.lua_pushcfunction(state, lua_tag_toggleview);
    c.lua_setfield(state, -2, "toggleview");

    c.lua_pushcfunction(state, lua_tag_move_to);
    c.lua_setfield(state, -2, "move_to");

    c.lua_pushcfunction(state, lua_tag_toggletag);
    c.lua_setfield(state, -2, "toggletag");

    c.lua_pushcfunction(state, lua_tag_set_back_and_forth);
    c.lua_setfield(state, -2, "set_back_and_forth");

    c.lua_setfield(state, -2, "tag");
}

fn register_monitor_module(state: *c.lua_State) void {
    c.lua_createtable(state, 0, 2);

    c.lua_pushcfunction(state, lua_monitor_focus);
    c.lua_setfield(state, -2, "focus");

    c.lua_pushcfunction(state, lua_monitor_tag);
    c.lua_setfield(state, -2, "tag");

    c.lua_setfield(state, -2, "monitor");
}

fn register_rule_module(state: *c.lua_State) void {
    c.lua_createtable(state, 0, 1);

    c.lua_pushcfunction(state, lua_rule_add);
    c.lua_setfield(state, -2, "add");

    c.lua_setfield(state, -2, "rule");
}

fn register_bar_module(state: *c.lua_State) void {
    c.lua_createtable(state, 0, 10);

    c.lua_pushcfunction(state, lua_bar_set_font);
    c.lua_setfield(state, -2, "set_font");

    c.lua_pushcfunction(state, lua_bar_set_blocks);
    c.lua_setfield(state, -2, "set_blocks");

    c.lua_pushcfunction(state, lua_bar_set_scheme_normal);
    c.lua_setfield(state, -2, "set_scheme_normal");

    c.lua_pushcfunction(state, lua_bar_set_scheme_selected);
    c.lua_setfield(state, -2, "set_scheme_selected");

    c.lua_pushcfunction(state, lua_bar_set_scheme_occupied);
    c.lua_setfield(state, -2, "set_scheme_occupied");

    c.lua_pushcfunction(state, lua_bar_set_scheme_urgent);
    c.lua_setfield(state, -2, "set_scheme_urgent");

    c.lua_pushcfunction(state, lua_bar_set_hide_vacant_tags);
    c.lua_setfield(state, -2, "set_hide_vacant_tags");

    c.lua_createtable(state, 0, 6);

    c.lua_pushcfunction(state, lua_bar_block_ram);
    c.lua_setfield(state, -2, "ram");

    c.lua_pushcfunction(state, lua_bar_block_datetime);
    c.lua_setfield(state, -2, "datetime");

    c.lua_pushcfunction(state, lua_bar_block_shell);
    c.lua_setfield(state, -2, "shell");

    c.lua_pushcfunction(state, lua_bar_block_static);
    c.lua_setfield(state, -2, "static");

    c.lua_pushcfunction(state, lua_bar_block_battery);
    c.lua_setfield(state, -2, "battery");

    c.lua_setfield(state, -2, "block");

    c.lua_setfield(state, -2, "bar");
}

fn register_misc_functions(state: *c.lua_State) void {
    c.lua_pushcfunction(state, lua_set_terminal);
    c.lua_setfield(state, -2, "set_terminal");

    c.lua_pushcfunction(state, lua_set_modkey);
    c.lua_setfield(state, -2, "set_modkey");

    c.lua_pushcfunction(state, lua_set_tags);
    c.lua_setfield(state, -2, "set_tags");

    c.lua_pushcfunction(state, lua_set_layout_symbol);
    c.lua_setfield(state, -2, "set_layout_symbol");

    c.lua_pushcfunction(state, lua_autostart);
    c.lua_setfield(state, -2, "autostart");

    c.lua_pushcfunction(state, lua_auto_tile);
    c.lua_setfield(state, -2, "auto_tile");

    c.lua_pushcfunction(state, lua_quit);
    c.lua_setfield(state, -2, "quit");

    c.lua_pushcfunction(state, lua_restart);
    c.lua_setfield(state, -2, "restart");

    c.lua_pushcfunction(state, lua_toggle_gaps);
    c.lua_setfield(state, -2, "toggle_gaps");

    c.lua_pushcfunction(state, lua_show_keybinds);
    c.lua_setfield(state, -2, "show_keybinds");

    c.lua_pushcfunction(state, lua_set_master_factor);
    c.lua_setfield(state, -2, "set_master_factor");

    c.lua_pushcfunction(state, lua_inc_num_master);
    c.lua_setfield(state, -2, "inc_num_master");
}

fn create_action_table(state: *c.lua_State, action_name: [*:0]const u8) void {
    c.lua_createtable(state, 0, 2);
    _ = c.lua_pushstring(state, action_name);
    c.lua_setfield(state, -2, "__action");
}

fn create_action_table_with_int(state: *c.lua_State, action_name: [*:0]const u8, arg: i32) void {
    c.lua_createtable(state, 0, 2);
    _ = c.lua_pushstring(state, action_name);
    c.lua_setfield(state, -2, "__action");
    c.lua_pushinteger(state, arg);
    c.lua_setfield(state, -2, "__arg");
}

fn create_action_table_with_string(state: *c.lua_State, action_name: [*:0]const u8) void {
    c.lua_createtable(state, 0, 2);
    _ = c.lua_pushstring(state, action_name);
    c.lua_setfield(state, -2, "__action");
    c.lua_pushvalue(state, 1);
    c.lua_setfield(state, -2, "__arg");
}

fn lua_spawn(state: ?*c.lua_State) callconv(.c) c_int {
    const s = state orelse return 0;
    create_action_table_with_string(s, "Spawn");
    return 1;
}

fn lua_spawn_terminal(state: ?*c.lua_State) callconv(.c) c_int {
    const s = state orelse return 0;
    create_action_table(s, "SpawnTerminal");
    return 1;
}

fn lua_key_bind(state: ?*c.lua_State) callconv(.c) c_int {
    const s = state orelse return 0;
    const cfg = config orelse return 0;

    const mod_mask = parse_modifiers(s, 1);
    const key_str = get_string_arg(s, 2) orelse return 0;
    const keysym = key_name_to_keysym(key_str) orelse return 0;

    if (c.lua_type(s, 3) != c.LUA_TTABLE) return 0;

    _ = c.lua_getfield(s, 3, "__action");
    const action_str = get_lua_string(s, -1) orelse {
        c.lua_settop(s, -2);
        return 0;
    };
    c.lua_settop(s, -2);

    const action = parse_action(action_str) orelse return 0;

    var int_arg: i32 = 0;
    var str_arg: ?[]const u8 = null;

    _ = c.lua_getfield(s, 3, "__arg");
    if (c.lua_type(s, -1) == c.LUA_TNUMBER) {
        int_arg = @intCast(c.lua_tointegerx(s, -1, null));
    } else if (c.lua_type(s, -1) == c.LUA_TSTRING) {
        str_arg = get_lua_string(s, -1);
    } else if (c.lua_type(s, -1) == c.LUA_TTABLE) {
        str_arg = extract_spawn_command(s, -1);
    }
    c.lua_settop(s, -2);

    var keybind: config_mod.Keybind = .{
        .action = action,
        .int_arg = int_arg,
        .str_arg = str_arg,
    };
    keybind.keys[0] = .{ .mod_mask = mod_mask, .keysym = keysym };
    keybind.key_count = 1;

    cfg.add_keybind(keybind) catch return 0;

    return 0;
}

fn lua_key_chord(state: ?*c.lua_State) callconv(.c) c_int {
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
        const mod_mask = parse_modifiers_at_top(s);
        c.lua_settop(s, -2);

        _ = c.lua_rawgeti(s, -1, 2);
        const key_str = get_lua_string(s, -1) orelse {
            c.lua_settop(s, -3);
            return 0;
        };
        c.lua_settop(s, -2);

        const keysym = key_name_to_keysym(key_str) orelse {
            c.lua_settop(s, -2);
            return 0;
        };

        keybind.keys[keybind.key_count] = .{ .mod_mask = mod_mask, .keysym = keysym };
        keybind.key_count += 1;

        c.lua_settop(s, -2);
    }

    _ = c.lua_getfield(s, 2, "__action");
    const action_str = get_lua_string(s, -1) orelse {
        c.lua_settop(s, -2);
        return 0;
    };
    c.lua_settop(s, -2);

    keybind.action = parse_action(action_str) orelse return 0;

    _ = c.lua_getfield(s, 2, "__arg");
    if (c.lua_type(s, -1) == c.LUA_TNUMBER) {
        keybind.int_arg = @intCast(c.lua_tointegerx(s, -1, null));
    } else if (c.lua_type(s, -1) == c.LUA_TSTRING) {
        keybind.str_arg = get_lua_string(s, -1);
    } else if (c.lua_type(s, -1) == c.LUA_TTABLE) {
        keybind.str_arg = extract_spawn_command(s, -1);
    }

    c.lua_settop(s, -2);
    cfg.add_keybind(keybind) catch return 0;

    return 0;
}

fn lua_gaps_set_enabled(state: ?*c.lua_State) callconv(.c) c_int {
    const cfg = config orelse return 0;
    const s = state orelse return 0;
    cfg.gaps_enabled = c.lua_toboolean(s, 1) != 0;
    return 0;
}

fn lua_gaps_enable(state: ?*c.lua_State) callconv(.c) c_int {
    _ = state;
    const cfg = config orelse return 0;
    cfg.gaps_enabled = true;
    return 0;
}

fn lua_gaps_disable(state: ?*c.lua_State) callconv(.c) c_int {
    _ = state;
    const cfg = config orelse return 0;
    cfg.gaps_enabled = false;
    return 0;
}

fn lua_gaps_set_inner(state: ?*c.lua_State) callconv(.c) c_int {
    const cfg = config orelse return 0;
    const s = state orelse return 0;
    cfg.gap_inner_h = @intCast(c.lua_tointegerx(s, 1, null));
    cfg.gap_inner_v = @intCast(c.lua_tointegerx(s, 2, null));
    return 0;
}

fn lua_gaps_set_outer(state: ?*c.lua_State) callconv(.c) c_int {
    const cfg = config orelse return 0;
    const s = state orelse return 0;
    cfg.gap_outer_h = @intCast(c.lua_tointegerx(s, 1, null));
    cfg.gap_outer_v = @intCast(c.lua_tointegerx(s, 2, null));
    return 0;
}

fn lua_gaps_set_smart(state: ?*c.lua_State) callconv(.c) c_int {
    const cfg = config orelse return 0;
    const s = state orelse return 0;
    cfg.smartgaps_enabled = c.lua_toboolean(s, 1) != 0;
    return 0;
}

fn lua_border_set_width(state: ?*c.lua_State) callconv(.c) c_int {
    const cfg = config orelse return 0;
    const s = state orelse return 0;
    cfg.border_width = @intCast(c.lua_tointegerx(s, 1, null));
    return 0;
}

fn lua_border_set_focused_color(state: ?*c.lua_State) callconv(.c) c_int {
    const cfg = config orelse return 0;
    const s = state orelse return 0;
    cfg.border_focused = parse_color(s, 1);
    return 0;
}

fn lua_border_set_unfocused_color(state: ?*c.lua_State) callconv(.c) c_int {
    const cfg = config orelse return 0;
    const s = state orelse return 0;
    cfg.border_unfocused = parse_color(s, 1);
    return 0;
}

fn lua_client_kill(state: ?*c.lua_State) callconv(.c) c_int {
    const s = state orelse return 0;
    create_action_table(s, "KillClient");
    return 1;
}

fn lua_client_toggle_fullscreen(state: ?*c.lua_State) callconv(.c) c_int {
    const s = state orelse return 0;
    create_action_table(s, "ToggleFullScreen");
    return 1;
}

fn lua_client_toggle_floating(state: ?*c.lua_State) callconv(.c) c_int {
    const s = state orelse return 0;
    create_action_table(s, "ToggleFloating");
    return 1;
}

fn lua_client_focus_stack(state: ?*c.lua_State) callconv(.c) c_int {
    const s = state orelse return 0;
    const dir: i32 = @intCast(c.lua_tointegerx(s, 1, null));
    create_action_table_with_int(s, "FocusStack", dir);
    return 1;
}

fn lua_client_move_stack(state: ?*c.lua_State) callconv(.c) c_int {
    const s = state orelse return 0;
    const dir: i32 = @intCast(c.lua_tointegerx(s, 1, null));
    create_action_table_with_int(s, "MoveStack", dir);
    return 1;
}

fn lua_layout_cycle(state: ?*c.lua_State) callconv(.c) c_int {
    const s = state orelse return 0;
    create_action_table(s, "CycleLayout");
    return 1;
}

fn lua_layout_set(state: ?*c.lua_State) callconv(.c) c_int {
    const s = state orelse return 0;
    create_action_table_with_string(s, "ChangeLayout");
    return 1;
}

fn lua_layout_scroll_left(state: ?*c.lua_State) callconv(.c) c_int {
    const s = state orelse return 0;
    create_action_table(s, "ScrollLeft");
    return 1;
}

fn lua_layout_scroll_right(state: ?*c.lua_State) callconv(.c) c_int {
    const s = state orelse return 0;
    create_action_table(s, "ScrollRight");
    return 1;
}

fn lua_tag_view(state: ?*c.lua_State) callconv(.c) c_int {
    const s = state orelse return 0;
    const idx: i32 = @intCast(c.lua_tointegerx(s, 1, null));
    create_action_table_with_int(s, "ViewTag", idx);
    return 1;
}

fn lua_tag_view_next(state: ?*c.lua_State) callconv(.c) c_int {
    const s = state orelse return 0;
    create_action_table(s, "ViewNextTag");
    return 1;
}

fn lua_tag_view_previous(state: ?*c.lua_State) callconv(.c) c_int {
    const s = state orelse return 0;
    create_action_table(s, "ViewPreviousTag");
    return 1;
}

fn lua_tag_view_next_nonempty(state: ?*c.lua_State) callconv(.c) c_int {
    const s = state orelse return 0;
    create_action_table(s, "ViewNextNonEmptyTag");
    return 1;
}

fn lua_tag_view_previous_nonempty(state: ?*c.lua_State) callconv(.c) c_int {
    const s = state orelse return 0;
    create_action_table(s, "ViewPreviousNonEmptyTag");
    return 1;
}

fn lua_tag_toggleview(state: ?*c.lua_State) callconv(.c) c_int {
    const s = state orelse return 0;
    const idx: i32 = @intCast(c.lua_tointegerx(s, 1, null));
    create_action_table_with_int(s, "ToggleView", idx);
    return 1;
}

fn lua_tag_move_to(state: ?*c.lua_State) callconv(.c) c_int {
    const s = state orelse return 0;
    const idx: i32 = @intCast(c.lua_tointegerx(s, 1, null));
    create_action_table_with_int(s, "MoveToTag", idx);
    return 1;
}

fn lua_tag_toggletag(state: ?*c.lua_State) callconv(.c) c_int {
    const s = state orelse return 0;
    const idx: i32 = @intCast(c.lua_tointegerx(s, 1, null));
    create_action_table_with_int(s, "ToggleTag", idx);
    return 1;
}

fn lua_tag_set_back_and_forth(state: ?*c.lua_State) callconv(.c) c_int {
    const cfg = config orelse return 0;
    const s = state orelse return 0;
    cfg.tag_back_and_forth = c.lua_toboolean(s, 1) != 0;
    return 0;
}

fn lua_monitor_focus(state: ?*c.lua_State) callconv(.c) c_int {
    const s = state orelse return 0;
    const dir: i32 = @intCast(c.lua_tointegerx(s, 1, null));
    create_action_table_with_int(s, "FocusMonitor", dir);
    return 1;
}

fn lua_monitor_tag(state: ?*c.lua_State) callconv(.c) c_int {
    const s = state orelse return 0;
    const dir: i32 = @intCast(c.lua_tointegerx(s, 1, null));
    create_action_table_with_int(s, "TagMonitor", dir);
    return 1;
}

fn lua_rule_add(state: ?*c.lua_State) callconv(.c) c_int {
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
        rule.class = get_lua_string(s, -1);
    }
    c.lua_settop(s, -2);

    _ = c.lua_getfield(s, 1, "instance");
    if (c.lua_type(s, -1) == c.LUA_TSTRING) {
        rule.instance = get_lua_string(s, -1);
    }
    c.lua_settop(s, -2);

    _ = c.lua_getfield(s, 1, "title");
    if (c.lua_type(s, -1) == c.LUA_TSTRING) {
        rule.title = get_lua_string(s, -1);
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

    cfg.add_rule(rule) catch return 0;
    return 0;
}

fn lua_bar_set_font(state: ?*c.lua_State) callconv(.c) c_int {
    const cfg = config orelse return 0;
    const s = state orelse return 0;
    if (dupe_lua_string(s, 1)) |font| {
        cfg.font = font;
    }
    return 0;
}

fn lua_bar_set_blocks(state: ?*c.lua_State) callconv(.c) c_int {
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

        if (parse_block_config(s, -1)) |block| {
            cfg.add_block(block) catch {};
        }

        c.lua_settop(s, -2);
    }

    return 0;
}

fn parse_block_config(state: *c.lua_State, idx: c_int) ?Block {
    _ = c.lua_getfield(state, idx, "__block_type");
    const block_type_str = get_lua_string(state, -1) orelse {
        c.lua_settop(state, -2);
        return null;
    };
    c.lua_settop(state, -2);

    _ = c.lua_getfield(state, idx, "format");
    const format = dupe_lua_string(state, -1) orelse "";
    c.lua_settop(state, -2);

    _ = c.lua_getfield(state, idx, "interval");
    const interval: u32 = @intCast(c.lua_tointegerx(state, -1, null));
    c.lua_settop(state, -2);

    _ = c.lua_getfield(state, idx, "color");
    const color = parse_color(state, -1);
    c.lua_settop(state, -2);

    _ = c.lua_getfield(state, idx, "underline");
    const underline = c.lua_toboolean(state, -1) != 0;
    c.lua_settop(state, -2);

    var block = Block{
        .block_type = .static,
        .format = format,
        .interval = interval,
        .color = color,
        .underline = underline,
    };

    if (std.mem.eql(u8, block_type_str, "Ram")) {
        block.block_type = .ram;
    } else if (std.mem.eql(u8, block_type_str, "DateTime")) {
        block.block_type = .datetime;
        _ = c.lua_getfield(state, idx, "__arg");
        block.datetime_format = dupe_lua_string(state, -1);
        c.lua_settop(state, -2);
    } else if (std.mem.eql(u8, block_type_str, "Shell")) {
        block.block_type = .shell;
        _ = c.lua_getfield(state, idx, "__arg");
        block.command = dupe_lua_string(state, -1);
        c.lua_settop(state, -2);
    } else if (std.mem.eql(u8, block_type_str, "Static")) {
        block.block_type = .static;
        _ = c.lua_getfield(state, idx, "__arg");
        if (dupe_lua_string(state, -1)) |text| {
            block.format = text;
        }
        c.lua_settop(state, -2);
    } else if (std.mem.eql(u8, block_type_str, "Battery")) {
        block.block_type = .battery;
        _ = c.lua_getfield(state, idx, "__arg");
        if (c.lua_type(state, -1) == c.LUA_TTABLE) {
            _ = c.lua_getfield(state, -1, "charging");
            block.format_charging = dupe_lua_string(state, -1);
            c.lua_settop(state, -2);

            _ = c.lua_getfield(state, -1, "discharging");
            block.format_discharging = dupe_lua_string(state, -1);
            c.lua_settop(state, -2);

            _ = c.lua_getfield(state, -1, "full");
            block.format_full = dupe_lua_string(state, -1);
            c.lua_settop(state, -2);

            _ = c.lua_getfield(state, -1, "battery_name");
            block.battery_name = dupe_lua_string(state, -1);
            c.lua_settop(state, -2);
        }
        c.lua_settop(state, -2);
    } else {
        return null;
    }

    return block;
}

fn lua_bar_set_scheme_normal(state: ?*c.lua_State) callconv(.c) c_int {
    const cfg = config orelse return 0;
    const s = state orelse return 0;
    cfg.scheme_normal = parse_scheme(s);
    return 0;
}

fn lua_bar_set_scheme_selected(state: ?*c.lua_State) callconv(.c) c_int {
    const cfg = config orelse return 0;
    const s = state orelse return 0;
    cfg.scheme_selected = parse_scheme(s);
    return 0;
}

fn lua_bar_set_scheme_occupied(state: ?*c.lua_State) callconv(.c) c_int {
    const cfg = config orelse return 0;
    const s = state orelse return 0;
    cfg.scheme_occupied = parse_scheme(s);
    return 0;
}

fn lua_bar_set_scheme_urgent(state: ?*c.lua_State) callconv(.c) c_int {
    const cfg = config orelse return 0;
    const s = state orelse return 0;
    cfg.scheme_urgent = parse_scheme(s);
    return 0;
}

fn lua_bar_set_hide_vacant_tags(state: ?*c.lua_State) callconv(.c) c_int {
    const cfg = config orelse return 0;
    const s = state orelse return 0;
    cfg.hide_vacant_tags = c.lua_toboolean(s, 1) != 0;
    return 0;
}

fn lua_bar_block_ram(state: ?*c.lua_State) callconv(.c) c_int {
    const s = state orelse return 0;
    create_block_table(s, "Ram", null);
    return 1;
}

fn lua_bar_block_datetime(state: ?*c.lua_State) callconv(.c) c_int {
    const s = state orelse return 0;
    _ = c.lua_getfield(s, 1, "date_format");
    const date_format = get_lua_string(s, -1);
    c.lua_settop(s, -2);
    create_block_table(s, "DateTime", date_format);
    return 1;
}

fn lua_bar_block_shell(state: ?*c.lua_State) callconv(.c) c_int {
    const s = state orelse return 0;
    _ = c.lua_getfield(s, 1, "command");
    const command = get_lua_string(s, -1);
    c.lua_settop(s, -2);
    create_block_table(s, "Shell", command);
    return 1;
}

fn lua_bar_block_static(state: ?*c.lua_State) callconv(.c) c_int {
    const s = state orelse return 0;
    _ = c.lua_getfield(s, 1, "text");
    const text = get_lua_string(s, -1);
    c.lua_settop(s, -2);
    create_block_table(s, "Static", text);
    return 1;
}

fn lua_bar_block_battery(state: ?*c.lua_State) callconv(.c) c_int {
    const s = state orelse return 0;

    c.lua_createtable(s, 0, 6);

    _ = c.lua_pushstring(s, "Battery");
    c.lua_setfield(s, -2, "__block_type");

    _ = c.lua_getfield(s, 1, "format");
    c.lua_setfield(s, -2, "format");

    _ = c.lua_getfield(s, 1, "interval");
    c.lua_setfield(s, -2, "interval");

    _ = c.lua_getfield(s, 1, "color");
    c.lua_setfield(s, -2, "color");

    _ = c.lua_getfield(s, 1, "underline");
    c.lua_setfield(s, -2, "underline");

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

fn create_block_table(state: *c.lua_State, block_type: [*:0]const u8, arg: ?[]const u8) void {
    c.lua_createtable(state, 0, 6);

    _ = c.lua_pushstring(state, block_type);
    c.lua_setfield(state, -2, "__block_type");

    _ = c.lua_getfield(state, 1, "format");
    c.lua_setfield(state, -2, "format");

    _ = c.lua_getfield(state, 1, "interval");
    c.lua_setfield(state, -2, "interval");

    _ = c.lua_getfield(state, 1, "color");
    c.lua_setfield(state, -2, "color");

    _ = c.lua_getfield(state, 1, "underline");
    c.lua_setfield(state, -2, "underline");

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

fn lua_set_terminal(state: ?*c.lua_State) callconv(.c) c_int {
    const cfg = config orelse return 0;
    const s = state orelse return 0;
    if (dupe_lua_string(s, 1)) |term| {
        cfg.terminal = term;
    }
    return 0;
}

fn lua_set_modkey(state: ?*c.lua_State) callconv(.c) c_int {
    const cfg = config orelse return 0;
    const s = state orelse return 0;
    if (get_string_arg(s, 1)) |modkey_str| {
        cfg.modkey = parse_single_modifier(modkey_str);
        cfg.add_button(.{
            .click = .client_win,
            .mod_mask = cfg.modkey,
            .button = 1,
            .action = .move_mouse,
        }) catch {};
        cfg.add_button(.{
            .click = .client_win,
            .mod_mask = cfg.modkey,
            .button = 3,
            .action = .resize_mouse,
        }) catch {};
    }
    return 0;
}

fn lua_set_tags(state: ?*c.lua_State) callconv(.c) c_int {
    const cfg = config orelse return 0;
    const s = state orelse return 0;

    if (c.lua_type(s, 1) != c.LUA_TTABLE) return 0;

    const len = c.lua_rawlen(s, 1);
    const count = @min(len, 9);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        _ = c.lua_rawgeti(s, 1, @intCast(i + 1));
        if (dupe_lua_string(s, -1)) |tag_str| {
            cfg.tags[i] = tag_str;
        }
        c.lua_settop(s, -2);
    }
    cfg.tag_count = @intCast(count);

    return 0;
}

fn lua_autostart(state: ?*c.lua_State) callconv(.c) c_int {
    const cfg = config orelse return 0;
    const s = state orelse return 0;
    if (dupe_lua_string(s, 1)) |cmd| {
        cfg.add_autostart(cmd) catch return 0;
    }
    return 0;
}

fn lua_auto_tile(state: ?*c.lua_State) callconv(.c) c_int {
    const cfg = config orelse return 0;
    const s = state orelse return 0;
    cfg.auto_tile = c.lua_toboolean(s, 1) != 0;
    return 0;
}

fn lua_set_layout_symbol(state: ?*c.lua_State) callconv(.c) c_int {
    const cfg = config orelse return 0;
    const s = state orelse return 0;
    const name = get_string_arg(s, 1) orelse return 0;
    const symbol = dupe_lua_string(s, 2) orelse return 0;

    const layout_map = .{
        .{ "tiling", &cfg.layout_tile_symbol },
        .{ "tile", &cfg.layout_tile_symbol },
        .{ "normie", &cfg.layout_floating_symbol },
        .{ "floating", &cfg.layout_floating_symbol },
        .{ "float", &cfg.layout_floating_symbol },
        .{ "monocle", &cfg.layout_monocle_symbol },
        .{ "scrolling", &cfg.layout_scrolling_symbol },
        .{ "scroll", &cfg.layout_scrolling_symbol },
        .{ "grid", &cfg.layout_grid_symbol },
    };

    inline for (layout_map) |entry| {
        if (std.mem.eql(u8, name, entry[0])) {
            entry[1].* = symbol;
            return 0;
        }
    }
    return 0;
}

fn lua_quit(state: ?*c.lua_State) callconv(.c) c_int {
    const s = state orelse return 0;
    create_action_table(s, "Quit");
    return 1;
}

fn lua_restart(state: ?*c.lua_State) callconv(.c) c_int {
    const s = state orelse return 0;
    create_action_table(s, "Restart");
    return 1;
}

fn lua_toggle_gaps(state: ?*c.lua_State) callconv(.c) c_int {
    const s = state orelse return 0;
    create_action_table(s, "ToggleGaps");
    return 1;
}

fn lua_show_keybinds(state: ?*c.lua_State) callconv(.c) c_int {
    const s = state orelse return 0;
    create_action_table(s, "ShowKeybinds");
    return 1;
}

fn lua_set_master_factor(state: ?*c.lua_State) callconv(.c) c_int {
    const s = state orelse return 0;
    const delta: i32 = @intCast(c.lua_tointegerx(s, 1, null));
    create_action_table_with_int(s, "ResizeMaster", delta);
    return 1;
}

fn lua_inc_num_master(state: ?*c.lua_State) callconv(.c) c_int {
    const s = state orelse return 0;
    const delta: i32 = @intCast(c.lua_tointegerx(s, 1, null));
    if (delta > 0) {
        create_action_table(s, "IncMaster");
    } else {
        create_action_table(s, "DecMaster");
    }
    return 1;
}

fn get_string_arg(state: *c.lua_State, idx: c_int) ?[]const u8 {
    if (c.lua_type(state, idx) != c.LUA_TSTRING) return null;
    return get_lua_string(state, idx);
}

fn extract_spawn_command(state: *c.lua_State, idx: c_int) ?[]const u8 {
    const len = c.lua_rawlen(state, idx);
    if (len == 0) return null;

    if (len >= 3) {
        _ = c.lua_rawgeti(state, idx, 1);
        const first = get_lua_string(state, -1);
        c.lua_settop(state, -2);

        _ = c.lua_rawgeti(state, idx, 2);
        const second = get_lua_string(state, -1);
        c.lua_settop(state, -2);

        if (first != null and second != null and
            std.mem.eql(u8, first.?, "sh") and std.mem.eql(u8, second.?, "-c"))
        {
            _ = c.lua_rawgeti(state, idx, 3);
            const cmd = get_lua_string(state, -1);
            c.lua_settop(state, -2);
            return cmd;
        }
    }

    _ = c.lua_rawgeti(state, idx, 1);
    const first_elem = get_lua_string(state, -1);
    c.lua_settop(state, -2);
    return first_elem;
}

fn get_lua_string(state: *c.lua_State, idx: c_int) ?[]const u8 {
    const cstr = c.lua_tolstring(state, idx, null);
    if (cstr == null) return null;
    return std.mem.span(cstr);
}

fn dupe_lua_string(state: *c.lua_State, idx: c_int) ?[]const u8 {
    const cfg = config orelse return null;
    const lua_str = get_lua_string(state, idx) orelse return null;
    const arena_allocator = cfg.string_arena.allocator();
    const duped = arena_allocator.dupe(u8, lua_str) catch return null;
    return duped;
}

fn parse_color(state: *c.lua_State, idx: c_int) u32 {
    const lua_type = c.lua_type(state, idx);
    if (lua_type == c.LUA_TNUMBER) {
        return @intCast(c.lua_tointegerx(state, idx, null));
    }
    if (lua_type == c.LUA_TSTRING) {
        const str = get_lua_string(state, idx) orelse return 0;
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

fn parse_scheme(state: *c.lua_State) ColorScheme {
    return ColorScheme{
        .foreground = parse_color(state, 1),
        .background = parse_color(state, 2),
        .border = parse_color(state, 3),
    };
}

fn parse_modifiers(state: *c.lua_State, idx: c_int) u32 {
    var mod_mask: u32 = 0;

    if (c.lua_type(state, idx) != c.LUA_TTABLE) return mod_mask;

    const len = c.lua_rawlen(state, idx);
    var i: usize = 1;
    while (i <= len) : (i += 1) {
        _ = c.lua_rawgeti(state, idx, @intCast(i));
        if (get_lua_string(state, -1)) |mod_str| {
            const parsed = parse_single_modifier(mod_str);
            mod_mask |= parsed;
        }
        c.lua_settop(state, -2);
    }

    return mod_mask;
}

fn parse_modifiers_at_top(state: *c.lua_State) u32 {
    return parse_modifiers(state, -1);
}

fn parse_single_modifier(name: []const u8) u32 {
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

fn parse_action(name: []const u8) ?Action {
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

fn key_name_to_keysym(name: []const u8) ?u64 {
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
        .{ "semicolon", 0x003b },
        .{ "apostrophe", 0x0027 },
        .{ "grave", 0x0060 },
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
