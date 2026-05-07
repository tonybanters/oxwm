const std = @import("std");
const xlib = @import("../x11/xlib.zig");
const monitor_mod = @import("../monitor.zig");
const blocks_mod = @import("blocks/blocks.zig");
const config_mod = @import("../config/config.zig");
const ColorScheme = config_mod.ColorScheme;

const Monitor = monitor_mod.Monitor;
const Block = blocks_mod.Block;

fn getLayoutSymbol(layout_index: u32, config: config_mod.Config) []const u8 {
    const layout = std.meta.intToEnum(config_mod.Layouts, layout_index) catch return "[?]";
    return switch (layout) {
        .tiling => config.layout_tile_symbol,
        .monocle => config.layout_monocle_symbol,
        .floating => config.layout_floating_symbol,
        .scrolling => config.layout_scrolling_symbol,
        .grid => config.layout_grid_symbol,
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
    show_title: bool,
    max_title_len: u32,

    allocator: std.mem.Allocator,
    blocks: std.ArrayList(Block),
    needs_redraw: bool,
    next: ?*Bar,

    /// Creates a bar window for `monitor` using the given config.
    /// Returns null on allocation failure or if the font cannot be loaded.
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

        const font_name_z = allocator.dupeZ(u8, config.font) catch {
            allocator.destroy(bar);
            return null;
        };
        defer allocator.free(font_name_z);

        const font = xlib.XftFontOpenName(display, screen, font_name_z);
        if (font == null) {
            allocator.destroy(bar);
            return null;
        }

        const font_height = font.*.ascent + font.*.descent;
        const bar_height: i32 = @intCast(@as(i32, font_height) + 8);

        var bar_y: i32 = 0;

        if (std.mem.eql(u8, config.bar_position, "top")) {
            bar_y = monitor.mon_y;
            monitor.win_y = monitor.mon_y + bar_height;
        } else if (std.mem.eql(u8, config.bar_position, "bottom")) {
            bar_y = monitor.mon_y + monitor.mon_h - bar_height;
            monitor.win_y = monitor.mon_y;
        } else {
            return null;
        }

        const window = xlib.c.XCreateSimpleWindow(
            display,
            root,
            monitor.mon_x,
            bar_y,
            @intCast(monitor.mon_w),
            @intCast(bar_height),
            0,
            0,
            0x1a1b26,
        );

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
            .show_title = config.show_bar_title,
            .max_title_len = config.bar_title_max_length,
            .allocator = allocator,
            .blocks = .empty,
            .needs_redraw = true,
            .next = null,
        };

        monitor.bar_win = window;
        monitor.win_h = monitor.mon_h - bar_height;

        return bar;
    }

    /// Destroys the bar's X resources and frees the allocation.
    pub fn destroy(self: *Bar, display: *xlib.Display) void {
        if (self.xft_draw) |xft_draw| xlib.XftDrawDestroy(xft_draw);
        if (self.font) |font| xlib.XftFontClose(display, font);

        _ = xlib.XFreeGC(display, self.graphics_context);
        _ = xlib.XFreePixmap(display, self.pixmap);
        _ = xlib.c.XDestroyWindow(display, self.window);
        self.blocks.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn addBlock(self: *Bar, block: Block) void {
        self.blocks.append(self.allocator, block) catch {};
    }

    pub fn clearBlocks(self: *Bar) void {
        self.blocks.clearRetainingCapacity();
    }

    pub fn invalidate(self: *Bar) void {
        self.needs_redraw = true;
    }

    /// Redraws the bar if marked dirty. Tags are taken from `config.tags`
    pub fn draw(self: *Bar, display: *xlib.Display, config: config_mod.Config) void {
        if (!self.needs_redraw) return;

        self.fillRect(display, 0, 0, self.width, self.height, self.scheme_normal.background);

        var x_position: i32 = 0;
        const padding: i32 = 8;
        const monitor = self.monitor;
        const current_tags = monitor.tagset[monitor.sel_tags];

        for (config.tags, 0..) |tag, index| {
            const tag_mask: u32 = @as(u32, 1) << @intCast(index);
            const is_selected = (current_tags & tag_mask) != 0;
            const is_occupied = hasClientsOnTag(monitor, tag_mask);

            if (self.hide_vacant_tags and !is_occupied and !is_selected) continue;

            const scheme = if (is_selected)
                self.scheme_selected
            else if (is_occupied)
                self.scheme_occupied
            else
                self.scheme_normal;

            const tag_text_width = self.textWidth(display, tag);
            const tag_width = tag_text_width + padding * 2;

            if (is_selected) {
                self.fillRect(display, x_position, self.height - 3, tag_width, 3, scheme.border);
            }

            const text_y = @divTrunc(self.height + self.font_height, 2) - 4;
            self.drawText(display, x_position + padding, text_y, tag, scheme.foreground);
            x_position += tag_width;
        }

        x_position += padding;

        const layout_symbol = getLayoutSymbol(monitor.sel_lt, config);
        self.drawText(display, x_position, @divTrunc(self.height + self.font_height, 2) - 4, layout_symbol, self.scheme_normal.foreground);
        x_position += self.textWidth(display, layout_symbol) + padding;

        var block_x: i32 = self.width - padding;
        var block_index: usize = self.blocks.items.len;
        while (block_index > 0) {
            block_index -= 1;
            const block = &self.blocks.items[block_index];
            const content = block.getContent();
            const content_width = self.textWidth(display, content);
            block_x -= content_width;
            block.x_start = block_x;
            block.x_end = block_x + content_width;
            self.drawText(display, block_x, @divTrunc(self.height + self.font_height, 2) - 4, content, block.color());
            if (block.underline) {
                self.fillRect(display, block_x, self.height - 2, content_width, 2, block.color());
            }
            block_x -= padding;
        }

        if (self.show_title) {
            const middle_right = block_x + padding;
            const middle_width = middle_right - x_position;
            if (middle_width > 0) {
                if (self.monitor.sel) |sel| {
                    var title = std.mem.sliceTo(&sel.name, 0);
                    if (title.len > 0) {
                        var trunc_buf: [256]u8 = undefined;
                        if (self.max_title_len > 0 and title.len > self.max_title_len) {
                            if (self.max_title_len >= 3) {
                                const keep = self.max_title_len - 3;
                                @memcpy(trunc_buf[0..keep], title[0..keep]);
                                @memcpy(trunc_buf[keep..self.max_title_len], "...");
                                title = trunc_buf[0..self.max_title_len];
                            } else {
                                title = title[0..self.max_title_len];
                            }
                        }
                        const title_width = self.textWidth(display, title);
                        if (title_width <= middle_width) {
                            const title_x = x_position + @divTrunc(middle_width - title_width, 2);
                            const title_y = @divTrunc(self.height + self.font_height, 2) - 4;
                            self.drawText(display, title_x, title_y, title, self.scheme_normal.foreground);
                        }
                    }
                }
            }
        }

        _ = xlib.XCopyArea(display, self.pixmap, self.window, self.graphics_context, 0, 0, @intCast(self.width), @intCast(self.height), 0, 0);
        _ = xlib.XSync(display, xlib.False);

        self.needs_redraw = false;
    }

    /// Returns the index of the tag the user clicked on, or null if the
    /// click was outside the tag area.
    pub fn handleClick(self: *Bar, display: *xlib.Display, click_x: i32, config: config_mod.Config) ?usize {
        var x_position: i32 = 0;
        const padding: i32 = 8;
        const monitor = self.monitor;
        const current_tags = monitor.tagset[monitor.sel_tags];

        for (config.tags, 0..) |tag, index| {
            const tag_mask = @as(u32, 1) << @intCast(index);
            const is_selected = (current_tags & tag_mask) != 0;
            const is_occupied = hasClientsOnTag(monitor, tag_mask);

            if (self.hide_vacant_tags and !is_occupied and !is_selected) continue;

            const tag_text_width = self.textWidth(display, tag);
            const tag_width = tag_text_width + padding * 2;

            if (click_x >= x_position and click_x < x_position + tag_width) {
                return index;
            }
            x_position += tag_width;
        }
        return null;
    }

    /// Returns the click action of the block the user clicked on, or null.
    pub fn handleBlockClick(self: *Bar, click_x: i32) ?config_mod.ClickAction {
        for (self.blocks.items) |*block| {
            if (block.click != null and click_x >= block.x_start and click_x < block.x_end) {
                return block.click;
            }
        }
        return null;
    }

    /// Updates all blocks and marks the bar dirty if any block changed.
    pub fn updateBlocks(self: *Bar) void {
        var changed = false;
        for (self.blocks.items) |*block| {
            if (block.update()) changed = true;
        }
        if (changed) self.needs_redraw = true;
    }

    fn fillRect(self: *Bar, display: *xlib.Display, x: i32, y: i32, width: i32, height: i32, color: c_ulong) void {
        _ = xlib.XSetForeground(display, self.graphics_context, color);
        _ = xlib.XFillRectangle(display, self.pixmap, self.graphics_context, x, y, @intCast(width), @intCast(height));
    }

    fn drawText(self: *Bar, display: *xlib.Display, x: i32, y: i32, text: []const u8, color: c_ulong) void {
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

    fn textWidth(self: *Bar, display: *xlib.Display, text: []const u8) i32 {
        if (self.font == null) return 0;

        var extents: xlib.XGlyphInfo = undefined;
        xlib.XftTextExtentsUtf8(display, self.font, text.ptr, @intCast(text.len), &extents);
        return extents.xOff;
    }
};

// Bar list helpers >.<

/// Marks all bars in the list as needing a redraw.
pub fn invalidateBars(bars: ?*Bar) void {
    var current = bars;
    while (current) |bar| {
        bar.invalidate();
        current = bar.next;
    }
}

/// Destroys all bars in the list and frees their resources.
pub fn destroyBars(bars: ?*Bar, display: *xlib.Display) void {
    var current = bars;
    while (current) |bar| {
        const next = bar.next;
        bar.destroy(display);
        current = next;
    }
}

/// Returns the bar whose window matches `win`, or null.
pub fn windowToBar(bars: ?*Bar, win: xlib.Window) ?*Bar {
    var current = bars;
    while (current) |bar| {
        if (bar.window == win) return bar;
        current = bar.next;
    }
    return null;
}

fn hasClientsOnTag(monitor: *Monitor, tag_mask: u32) bool {
    var current = monitor.clients;
    while (current) |client| {
        if ((client.tags & tag_mask) != 0) return true;
        current = client.next;
    }
    return false;
}
