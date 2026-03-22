const std = @import("std");

pub const Action = enum {
    spawn_terminal,
    spawn,
    kill_client,
    quit,
    reload_config,
    restart,
    show_keybinds,
    focus_next,
    focus_prev,
    move_next,
    move_prev,
    resize_master,
    inc_master,
    dec_master,
    toggle_floating,
    toggle_fullscreen,
    toggle_gaps,
    cycle_layout,
    set_layout,
    set_layout_tiling,
    set_layout_floating,
    view_tag,
    view_next_tag,
    view_prev_tag,
    view_next_nonempty_tag,
    view_prev_nonempty_tag,
    move_to_tag,
    toggle_view_tag,
    toggle_tag,
    focus_monitor,
    send_to_monitor,
    scroll_left,
    scroll_right,
};

pub const KeyPress = struct {
    mod_mask: u32 = 0,
    keysym: u64 = 0,
};

pub const Keybind = struct {
    keys: [4]KeyPress = [_]KeyPress{.{}} ** 4,
    key_count: u8 = 1,
    action: Action,
    int_arg: i32 = 0,
    str_arg: ?[]const u8 = null,
};

pub const Rule = struct {
    class: ?[]const u8,
    instance: ?[]const u8,
    title: ?[]const u8,
    tags: u32,
    is_floating: bool,
    monitor: i32,
    focus: bool,
};

pub const BlockType = enum {
    static,
    datetime,
    ram,
    shell,
    battery,
    cpu_temp,
};

pub const ClickTarget = enum {
    client_win,
    root_win,
    tag_bar,
};

pub const MouseAction = enum {
    move_mouse,
    resize_mouse,
    toggle_floating,
};

pub const MouseButton = struct {
    click: ClickTarget,
    mod_mask: u32,
    button: u32,
    action: MouseAction,
};

pub const Block = struct {
    block_type: BlockType,
    format: []const u8,
    command: ?[]const u8 = null,
    interval: u32,
    color: u32,
    underline: bool = true,
    datetime_format: ?[]const u8 = null,
    format_charging: ?[]const u8 = null,
    format_discharging: ?[]const u8 = null,
    format_full: ?[]const u8 = null,
    battery_name: ?[]const u8 = null,
    thermal_zone: ?[]const u8 = null,
};

pub const ColorScheme = struct {
    foreground: u32 = 0xbbbbbb,
    background: u32 = 0x1a1b26,
    border: u32 = 0x444444,
};

pub const Config = struct {
    allocator: std.mem.Allocator,
    string_arena: std.heap.ArenaAllocator,

    terminal: []const u8 = "st",
    font: []const u8 = "monospace:size=10",
    tags: [9][]const u8 = .{ "1", "2", "3", "4", "5", "6", "7", "8", "9" },

    border_width: i32 = 2,
    border_focused: u32 = 0x6dade3,
    border_unfocused: u32 = 0x444444,

    gaps_enabled: bool = true,
    smartgaps_enabled: bool = false,
    gap_inner_h: i32 = 5,
    gap_inner_v: i32 = 5,
    gap_outer_h: i32 = 5,
    gap_outer_v: i32 = 5,

    modkey: u32 = (1 << 6),
    auto_tile: bool = false,
    tag_back_and_forth: bool = false,
    hide_vacant_tags: bool = false,

    layout_tile_symbol: []const u8 = "[]=",
    layout_monocle_symbol: []const u8 = "[M]",
    layout_floating_symbol: []const u8 = "><>",
    layout_scrolling_symbol: []const u8 = "[S]",

    scheme_normal: ColorScheme = .{ .foreground = 0xbbbbbb, .background = 0x1a1b26, .border = 0x444444 },
    scheme_selected: ColorScheme = .{ .foreground = 0x0db9d7, .background = 0x1a1b26, .border = 0xad8ee6 },
    scheme_occupied: ColorScheme = .{ .foreground = 0x0db9d7, .background = 0x1a1b26, .border = 0x0db9d7 },
    scheme_urgent: ColorScheme = .{ .foreground = 0xf7768e, .background = 0x1a1b26, .border = 0xf7768e },

    keybinds: std.ArrayListUnmanaged(Keybind) = .{},
    rules: std.ArrayListUnmanaged(Rule) = .{},
    blocks: std.ArrayListUnmanaged(Block) = .{},
    buttons: std.ArrayListUnmanaged(MouseButton) = .{},
    autostart: std.ArrayListUnmanaged([]const u8) = .{},

    pub fn init(allocator: std.mem.Allocator) Config {
        return Config{
            .allocator = allocator,
            .string_arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *Config) void {
        self.string_arena.deinit();
        self.keybinds.deinit(self.allocator);
        self.rules.deinit(self.allocator);
        self.blocks.deinit(self.allocator);
        self.buttons.deinit(self.allocator);
        self.autostart.deinit(self.allocator);
    }

    pub fn addKeybind(self: *Config, keybind: Keybind) !void {
        try self.keybinds.append(self.allocator, keybind);
    }

    pub fn addRule(self: *Config, rule: Rule) !void {
        try self.rules.append(self.allocator, rule);
    }

    pub fn addBlock(self: *Config, block: Block) !void {
        try self.blocks.append(self.allocator, block);
    }

    pub fn addButton(self: *Config, button: MouseButton) !void {
        try self.buttons.append(self.allocator, button);
    }

    pub fn addAutostart(self: *Config, cmd: []const u8) !void {
        try self.autostart.append(self.allocator, cmd);
    }
};

pub fn initializeDefaultConfig(cfg: *Config) void {
    const mod_key: u32 = 1 << 6;
    const shift_key: u32 = 1 << 0;
    const control_key: u32 = 1 << 2;

    cfg.addKeybind(makeKeybind(mod_key, 0xff0d, .spawn_terminal)) catch {};
    cfg.addKeybind(makeKeybindStr(mod_key, 'd', .spawn, "rofi -show drun")) catch {};
    cfg.addKeybind(makeKeybindStr(mod_key, 's', .spawn, "maim -s | xclip -selection clipboard -t image/png")) catch {};
    cfg.addKeybind(makeKeybind(mod_key, 'q', .kill_client)) catch {};
    cfg.addKeybind(makeKeybindStr(0, 0x1008ff13, .spawn, "pactl set-sink-volume @DEFAULT_SINK@ +5%")) catch {};
    cfg.addKeybind(makeKeybindStr(0, 0x1008ff11, .spawn, "pactl set-sink-volume @DEFAULT_SINK@ -5%")) catch {};
    cfg.addKeybind(makeKeybindStr(0, 0x1008ff12, .spawn, "pactl set-sink-mute @DEFAULT_SINK@ toggle")) catch {};
    cfg.addKeybind(makeKeybindStr(0, 0x1008ff14, .spawn, "playerctl play-pause")) catch {};
    cfg.addKeybind(makeKeybindStr(0, 0x1008ff17, .spawn, "playerctl next")) catch {};
    cfg.addKeybind(makeKeybindStr(0, 0x1008ff16, .spawn, "playerctl previous")) catch {};
    cfg.addKeybind(makeKeybind(mod_key | shift_key, 'q', .quit)) catch {};
    cfg.addKeybind(makeKeybind(mod_key | shift_key, 'r', .reload_config)) catch {};
    cfg.addKeybind(makeKeybind(mod_key, 'j', .focus_next)) catch {};
    cfg.addKeybind(makeKeybind(mod_key, 'k', .focus_prev)) catch {};
    cfg.addKeybind(makeKeybind(mod_key | shift_key, 'j', .move_next)) catch {};
    cfg.addKeybind(makeKeybind(mod_key | shift_key, 'k', .move_prev)) catch {};
    cfg.addKeybind(makeKeybindInt(mod_key, 'h', .resize_master, -50)) catch {};
    cfg.addKeybind(makeKeybindInt(mod_key, 'l', .resize_master, 50)) catch {};
    cfg.addKeybind(makeKeybind(mod_key, 'i', .inc_master)) catch {};
    cfg.addKeybind(makeKeybind(mod_key, 'p', .dec_master)) catch {};
    cfg.addKeybind(makeKeybind(mod_key, 'a', .toggle_gaps)) catch {};
    cfg.addKeybind(makeKeybind(mod_key, 'f', .toggle_fullscreen)) catch {};
    cfg.addKeybind(makeKeybind(mod_key, 0x0020, .toggle_floating)) catch {};
    cfg.addKeybind(makeKeybind(mod_key, 'n', .cycle_layout)) catch {};
    cfg.addKeybind(makeKeybindInt(mod_key, 0x002c, .focus_monitor, -1)) catch {};
    cfg.addKeybind(makeKeybindInt(mod_key, 0x002e, .focus_monitor, 1)) catch {};
    cfg.addKeybind(makeKeybindInt(mod_key | shift_key, 0x002c, .send_to_monitor, -1)) catch {};
    cfg.addKeybind(makeKeybindInt(mod_key | shift_key, 0x002e, .send_to_monitor, 1)) catch {};

    var tag_index: i32 = 0;
    while (tag_index < 9) : (tag_index += 1) {
        const keysym: u64 = @as(u64, '1') + @as(u64, @intCast(tag_index));
        cfg.addKeybind(makeKeybindInt(mod_key, keysym, .view_tag, tag_index)) catch {};
        cfg.addKeybind(makeKeybindInt(mod_key | shift_key, keysym, .move_to_tag, tag_index)) catch {};
        cfg.addKeybind(makeKeybindInt(mod_key | control_key, keysym, .toggle_view_tag, tag_index)) catch {};
        cfg.addKeybind(makeKeybindInt(mod_key | control_key | shift_key, keysym, .toggle_tag, tag_index)) catch {};
    }

    cfg.addButton(.{ .click = .client_win, .mod_mask = mod_key, .button = 1, .action = .move_mouse }) catch {};
    cfg.addButton(.{ .click = .client_win, .mod_mask = mod_key, .button = 3, .action = .resize_mouse }) catch {};
}

fn makeKeybind(mod: u32, key: u64, action: Action) Keybind {
    var kb: Keybind = .{ .action = action };
    kb.keys[0] = .{ .mod_mask = mod, .keysym = key };
    kb.key_count = 1;
    return kb;
}

fn makeKeybindInt(mod: u32, key: u64, action: Action, int_arg: i32) Keybind {
    var kb = makeKeybind(mod, key, action);
    kb.int_arg = int_arg;
    return kb;
}

fn makeKeybindStr(mod: u32, key: u64, action: Action, str_arg: []const u8) Keybind {
    var kb = makeKeybind(mod, key, action);
    kb.str_arg = str_arg;
    return kb;
}
