const std = @import("std");
const xlib = @import("../x11/xlib.zig");
const monitor_mod = @import("../monitor.zig");
const client_mod = @import("../client.zig");
const blocks_mod = @import("blocks/blocks.zig");
const config_mod = @import("../config/config.zig");
const ColorScheme = config_mod.ColorScheme;

const Monitor = monitor_mod.Monitor;
const Block = blocks_mod.Block;

fn get_layout_symbol(layout_index: u32) []const u8 {
    const cfg = config_mod.get_config();
    if (cfg) |conf| {
        return switch (layout_index) {
            0 => conf.layout_tile_symbol,
            1 => conf.layout_monocle_symbol,
            2 => conf.layout_floating_symbol,
            3 => conf.layout_scrolling_symbol,
            4 => conf.layout_grid_symbol,
            else => "[?]",
        };
    }
    return switch (layout_index) {
        0 => "[]=",
        1 => "[M]",
        2 => "><>",
        3 => "[S]",
        4 => "[#]",
        else => "[?]",
    };
}

pub const Bar = struct {
    window: xlib.Window,
    pixmap: xlib.Pixmap,
    graphics_context: xlib.GC,
    xft_draw: ?*xlib.XftDraw,
    width: i32,
    height: i32,
    monitor: *Monitor,

    font: ?*xlib.XftFont,
    font_height: i32,

    scheme_normal: ColorScheme,
    scheme_selected: ColorScheme,
    scheme_occupied: ColorScheme,
    scheme_urgent: ColorScheme,
    hide_vacant_tags: bool,

    allocator: std.mem.Allocator,
    blocks: std.ArrayList(Block),
    needs_redraw: bool,
    next: ?*Bar,

    pub fn create(
        allocator: std.mem.Allocator,
        display: *xlib.Display,
        screen: c_int,
        monitor: *Monitor,
        config: config_mod.Config,
    ) ?*Bar {
        const bar = allocator.create(Bar) catch return null;

        const visual = xlib.XDefaultVisual(display, screen);
        const colormap = xlib.XDefaultColormap(display, screen);
        const depth = xlib.XDefaultDepth(display, screen);
        const root = xlib.XRootWindow(display, screen);

        const font_name_z = allocator.dupeZ(u8, config.font) catch return null;
        defer allocator.free(font_name_z);

        const font = xlib.XftFontOpenName(display, screen, font_name_z);
        if (font == null) {
            allocator.destroy(bar);
            return null;
        }

        const font_height = font.*.ascent + font.*.descent;
        const bar_height: i32 = @intCast(@as(i32, font_height) + 8);

        const window = xlib.c.XCreateSimpleWindow(
            display,
            root,
            monitor.mon_x,
            monitor.mon_y,
            @intCast(monitor.mon_w),
            @intCast(bar_height),
            0,
            0,
            0x1a1b26,
        );

        _ = xlib.c.XSetWindowAttributes{};
        var attributes: xlib.c.XSetWindowAttributes = undefined;
        attributes.override_redirect = xlib.True;
        attributes.event_mask = xlib.c.ExposureMask | xlib.c.ButtonPressMask;
        _ = xlib.c.XChangeWindowAttributes(display, window, xlib.c.CWOverrideRedirect | xlib.c.CWEventMask, &attributes);

        const pixmap = xlib.XCreatePixmap(
            display,
            window,
            @intCast(monitor.mon_w),
            @intCast(bar_height),
            @intCast(depth),
        );

        const graphics_context = xlib.XCreateGC(display, pixmap, 0, null);

        const xft_draw = xlib.XftDrawCreate(display, pixmap, visual, colormap);

        _ = xlib.XMapWindow(display, window);

        bar.* = Bar{
            .window = window,
            .pixmap = pixmap,
            .graphics_context = graphics_context,
            .xft_draw = xft_draw,
            .width = monitor.mon_w,
            .height = bar_height,
            .monitor = monitor,
            .font = font,
            .font_height = font_height,
            .scheme_normal = config.scheme_normal,
            .scheme_selected = config.scheme_selected,
            .scheme_occupied = config.scheme_occupied,
            .scheme_urgent = config.scheme_urgent,
            .hide_vacant_tags = config.hide_vacant_tags,
            .allocator = allocator,
            .blocks = .{},
            .needs_redraw = true,
            .next = null,
        };

        monitor.bar_win = window;
        monitor.win_y = monitor.mon_y + bar_height;
        monitor.win_h = monitor.mon_h - bar_height;

        return bar;
    }

    pub fn destroy(self: *Bar, allocator: std.mem.Allocator, display: *xlib.Display) void {
        if (self.xft_draw) |xft_draw| {
            xlib.XftDrawDestroy(xft_draw);
        }
        if (self.font) |font| {
            xlib.XftFontClose(display, font);
        }
        _ = xlib.XFreeGC(display, self.graphics_context);
        _ = xlib.XFreePixmap(display, self.pixmap);
        _ = xlib.c.XDestroyWindow(display, self.window);
        self.blocks.deinit(self.allocator);
        allocator.destroy(self);
    }

    pub fn add_block(self: *Bar, block: Block) void {
        self.blocks.append(self.allocator, block) catch {};
    }

    pub fn invalidate(self: *Bar) void {
        self.needs_redraw = true;
    }

    pub fn draw(self: *Bar, display: *xlib.Display, tags: []const []const u8) void {
        if (!self.needs_redraw) return;

        self.fill_rect(display, 0, 0, self.width, self.height, self.scheme_normal.background);

        var x_position: i32 = 0;
        const padding: i32 = 8;
        const monitor = self.monitor;
        const current_tags = monitor.tagset[monitor.sel_tags];

        for (tags, 0..) |tag, index| {
            const tag_mask: u32 = @as(u32, 1) << @intCast(index);
            const is_selected = (current_tags & tag_mask) != 0;
            const is_occupied = has_clients_on_tag(monitor, tag_mask);

            if (self.hide_vacant_tags and !is_occupied and !is_selected) continue;

            const scheme = if (is_selected) self.scheme_selected else if (is_occupied) self.scheme_occupied else self.scheme_normal;

            const tag_text_width = self.text_width(display, tag);
            const tag_width = tag_text_width + padding * 2;

            if (is_selected) {
                self.fill_rect(display, x_position, self.height - 3, tag_width, 3, scheme.border);
            }

            const text_y = @divTrunc(self.height + self.font_height, 2) - 4;
            self.draw_text(display, x_position + padding, text_y, tag, scheme.foreground);

            x_position += tag_width;
        }

        x_position += padding;

        const layout_symbol = get_layout_symbol(monitor.sel_lt);
        self.draw_text(display, x_position, @divTrunc(self.height + self.font_height, 2) - 4, layout_symbol, self.scheme_normal.foreground);
        x_position += self.text_width(display, layout_symbol) + padding;

        var block_x: i32 = self.width - padding;
        var block_index: usize = self.blocks.items.len;
        while (block_index > 0) {
            block_index -= 1;
            const block = &self.blocks.items[block_index];
            const content = block.get_content();
            const content_width = self.text_width(display, content);
            block_x -= content_width;
            self.draw_text(display, block_x, @divTrunc(self.height + self.font_height, 2) - 4, content, block.color());
            if (block.underline) {
                self.fill_rect(display, block_x, self.height - 2, content_width, 2, block.color());
            }
            block_x -= padding;
        }

        _ = xlib.XCopyArea(display, self.pixmap, self.window, self.graphics_context, 0, 0, @intCast(self.width), @intCast(self.height), 0, 0);
        _ = xlib.XSync(display, xlib.False);

        self.needs_redraw = false;
    }

    fn fill_rect(self: *Bar, display: *xlib.Display, x: i32, y: i32, width: i32, height: i32, color: c_ulong) void {
        _ = xlib.XSetForeground(display, self.graphics_context, color);
        _ = xlib.XFillRectangle(display, self.pixmap, self.graphics_context, x, y, @intCast(width), @intCast(height));
    }

    fn draw_text(self: *Bar, display: *xlib.Display, x: i32, y: i32, text: []const u8, color: c_ulong) void {
        if (self.xft_draw == null or self.font == null) return;

        var xft_color: xlib.XftColor = undefined;
        var render_color: xlib.XRenderColor = undefined;
        render_color.red = @intCast((color >> 16 & 0xff) * 257);
        render_color.green = @intCast((color >> 8 & 0xff) * 257);
        render_color.blue = @intCast((color & 0xff) * 257);
        render_color.alpha = 0xffff;

        const visual = xlib.XDefaultVisual(display, 0);
        const colormap = xlib.XDefaultColormap(display, 0);

        _ = xlib.XftColorAllocValue(display, visual, colormap, &render_color, &xft_color);

        xlib.XftDrawStringUtf8(self.xft_draw, &xft_color, self.font, x, y, text.ptr, @intCast(text.len));

        xlib.XftColorFree(display, visual, colormap, &xft_color);
    }

    fn text_width(self: *Bar, display: *xlib.Display, text: []const u8) i32 {
        if (self.font == null) return 0;

        var extents: xlib.XGlyphInfo = undefined;
        xlib.XftTextExtentsUtf8(display, self.font, text.ptr, @intCast(text.len), &extents);
        return extents.xOff;
    }

    pub fn handle_click(self: *Bar, click_x: i32, tags: []const []const u8) ?usize {
        var x_position: i32 = 0;
        const padding: i32 = 8;
        const display = xlib.c.XOpenDisplay(null) orelse return null;
        defer _ = xlib.XCloseDisplay(display);

        const monitor = self.monitor;
        const current_tags = monitor.tagset[monitor.sel_tags];
        for (tags, 0..) |tag, index| {
            const tag_mask = @as(u32, 1) << @intCast(index);
            const is_selected = (current_tags & tag_mask) != 0;
            const is_occupied = has_clients_on_tag(monitor, tag_mask);

            if (self.hide_vacant_tags and !is_occupied and !is_selected) continue;

            const tag_text_width = self.text_width(display, tag);
            const tag_width = tag_text_width + padding * 2;

            if (click_x >= x_position and click_x < x_position + tag_width) {
                return index;
            }
            x_position += tag_width;
        }
        return null;
    }

    pub fn update_blocks(self: *Bar) void {
        var changed = false;
        for (self.blocks.items) |*block| {
            if (block.update()) {
                changed = true;
            }
        }
        if (changed) {
            self.needs_redraw = true;
        }
    }

    pub fn clear_blocks(self: *Bar) void {
        self.blocks.clearRetainingCapacity();
    }
};

fn has_clients_on_tag(monitor: *Monitor, tag_mask: u32) bool {
    var current = monitor.clients;
    while (current) |client| {
        if ((client.tags & tag_mask) != 0) {
            return true;
        }
        current = client.next;
    }
    return false;
}

pub var bars: ?*Bar = null;

pub fn create_bars(allocator: std.mem.Allocator, display: *xlib.Display, screen: c_int) void {
    var current_monitor = monitor_mod.monitors;
    while (current_monitor) |monitor| {
        const bar = Bar.create(allocator, display, screen, monitor, "monospace:size=10");
        if (bar) |created_bar| {
            bars = created_bar;
        }
        current_monitor = monitor.next;
    }
}

pub fn draw_bars(display: *xlib.Display, tags: []const []const u8) void {
    var current_monitor = monitor_mod.monitors;
    while (current_monitor) |monitor| {
        _ = monitor;
        if (bars) |bar| {
            bar.draw(display, tags);
        }
        current_monitor = if (current_monitor) |m| m.next else null;
    }
}

pub fn invalidate_bars() void {
    var current = bars;
    while (current) |bar| {
        bar.invalidate();
        current = bar.next;
    }
}

pub fn destroy_bars(allocator: std.mem.Allocator, display: *xlib.Display) void {
    var current = bars;
    while (current) |bar| {
        const next = bar.next;
        bar.destroy(allocator, display);
        current = next;
    }
    bars = null;
}

pub fn window_to_bar(win: xlib.Window) ?*Bar {
    var current = bars;
    while (current) |bar| {
        if (bar.window == win) {
            return bar;
        }
        current = bar.next;
    }
    return null;
}
