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

pub const Key_Press = struct {
    mod_mask: u32 = 0,
    keysym: u64 = 0,
};

pub const Keybind = struct {
    keys: [4]Key_Press = [_]Key_Press{.{}} ** 4,
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

pub const Block_Type = enum {
    static,
    datetime,
    ram,
    shell,
    battery,
    cpu_temp,
};

pub const Click_Target = enum {
    client_win,
    root_win,
    tag_bar,
};

pub const Mouse_Action = enum {
    move_mouse,
    resize_mouse,
    toggle_floating,
};

pub const Mouse_Button = struct {
    click: Click_Target,
    mod_mask: u32,
    button: u32,
    action: Mouse_Action,
};

pub const Block = struct {
    block_type: Block_Type,
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
    color_charging: ?u32 = null,
    color_discharging: ?u32 = null,
    color_full: ?u32 = null,
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
    buttons: std.ArrayListUnmanaged(Mouse_Button) = .{},
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

    pub fn add_keybind(self: *Config, keybind: Keybind) !void {
        try self.keybinds.append(self.allocator, keybind);
    }

    pub fn add_rule(self: *Config, rule: Rule) !void {
        try self.rules.append(self.allocator, rule);
    }

    pub fn add_block(self: *Config, block: Block) !void {
        try self.blocks.append(self.allocator, block);
    }

    pub fn add_button(self: *Config, button: Mouse_Button) !void {
        try self.buttons.append(self.allocator, button);
    }

    pub fn add_autostart(self: *Config, cmd: []const u8) !void {
        try self.autostart.append(self.allocator, cmd);
    }
};

pub var global_config: ?*Config = null;

pub fn get_config() ?*Config {
    return global_config;
}

pub fn set_config(cfg: *Config) void {
    global_config = cfg;
}
