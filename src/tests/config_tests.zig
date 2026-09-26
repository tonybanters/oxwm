const std = @import("std");
const testing = std.testing;

const Config = struct {
    terminal: []const u8 = "st",
    font: []const u8 = "monospace:size=10",
    border_width: i32 = 2,
    border_focused: u32 = 0x6dade3,
    border_unfocused: u32 = 0x444444,
    gaps_enabled: bool = true,
    gap_inner_h: i32 = 5,
    gap_inner_v: i32 = 5,
    gap_outer_h: i32 = 5,
    gap_outer_v: i32 = 5,
    modkey: u32 = (1 << 6),
    auto_tile: bool = false,
    tag_back_and_forth: bool = false,
    hide_vacant_tags: bool = false,
};

test "config has correct default terminal" {
    const cfg = Config{};
    try testing.expectEqualStrings("st", cfg.terminal);
}

test "config has correct default font" {
    const cfg = Config{};
    try testing.expectEqualStrings("monospace:size=10", cfg.font);
}

test "config has correct default border width" {
    const cfg = Config{};
    try testing.expectEqual(@as(i32, 2), cfg.border_width);
}

test "config has correct default focused border color" {
    const cfg = Config{};
    try testing.expectEqual(@as(u32, 0x6dade3), cfg.border_focused);
}

test "config has correct default unfocused border color" {
    const cfg = Config{};
    try testing.expectEqual(@as(u32, 0x444444), cfg.border_unfocused);
}

test "config gaps are enabled by default" {
    const cfg = Config{};
    try testing.expect(cfg.gaps_enabled);
}

test "config has correct default gap values" {
    const cfg = Config{};
    try testing.expectEqual(@as(i32, 5), cfg.gap_inner_h);
    try testing.expectEqual(@as(i32, 5), cfg.gap_inner_v);
    try testing.expectEqual(@as(i32, 5), cfg.gap_outer_h);
    try testing.expectEqual(@as(i32, 5), cfg.gap_outer_v);
}

test "config auto_tile is disabled by default" {
    const cfg = Config{};
    try testing.expect(!cfg.auto_tile);
}

test "config tag_back_and_forth is disabled by default" {
    const cfg = Config{};
    try testing.expect(!cfg.tag_back_and_forth);
}

test "config hide_vacant_tags is disabled by default" {
    const cfg = Config{};
    try testing.expect(!cfg.hide_vacant_tags);
}

test "config default modkey is Mod4 (super)" {
    const cfg = Config{};
    try testing.expectEqual(@as(u32, 1 << 6), cfg.modkey);
}

test "can override config defaults" {
    const cfg = Config{
        .terminal = "alacritty",
        .border_width = 3,
        .gaps_enabled = false,
    };
    try testing.expectEqualStrings("alacritty", cfg.terminal);
    try testing.expectEqual(@as(i32, 3), cfg.border_width);
    try testing.expect(!cfg.gaps_enabled);
}
