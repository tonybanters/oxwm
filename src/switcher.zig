const std = @import("std");
const xlib = @import("x11/xlib.zig");
const config_mod = @import("config/config.zig");
const monitor_mod = @import("monitor.zig");
const wm_mod = @import("wm/wm.zig");
const core = @import("wm/core.zig");

const padding: i32 = 24;
const cell_padding_x: i32 = 16;
const cell_padding_y: i32 = 12;
const cell_gap: i32 = 8;
const border_width: i32 = 4;

const border_color: c_ulong = 0x7fccff;
const bg_color: c_ulong = 0x1a1a1a;
const cell_bg_color: c_ulong = 0x2a2a2a;
const cell_selected_bg: c_ulong = 0x7fccff;
const cell_fg_color: c_ulong = 0xffffff;
const cell_selected_fg: c_ulong = 0x101010;

const KeySym_Tab: u64 = 0xff09;
const KeySym_ISO_Left_Tab: u64 = 0xfe20;
const KeySym_Return: u64 = 0xff0d;
const KeySym_Escape: u64 = 0xff1b;

pub const WorkspaceSwitcher = struct {
    window: xlib.Window = 0,
    pixmap: xlib.Pixmap = 0,
    gc: xlib.GC = null,
    xft_draw: ?*xlib.XftDraw = null,
    font: ?*xlib.XftFont = null,
    font_height: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,
    visible: bool = false,
    display: ?*xlib.Display = null,
    root: xlib.Window = 0,
    screen: c_int = 0,

    cell_w: i32 = 0,
    cell_h: i32 = 0,
    cols: usize = 0,
    rows: usize = 0,

    tag_indices: [9]u8 = undefined,
    tag_counts: [9]u32 = undefined,
    item_count: usize = 0,
    selected: usize = 0,

    label_bufs: [9][32]u8 = undefined,
    label_lens: [9]usize = undefined,

    master_mod_mask: c_uint = 0,
    master_keycodes: [16]u8 = undefined,
    master_keycode_count: usize = 0,

    pub fn init(display: *xlib.Display, screen: c_int, root: xlib.Window, font_name: []const u8, allocator: std.mem.Allocator) ?*WorkspaceSwitcher {
        const sw = allocator.create(WorkspaceSwitcher) catch return null;

        const font_name_z = allocator.dupeZ(u8, font_name) catch {
            allocator.destroy(sw);
            return null;
        };
        defer allocator.free(font_name_z);

        const font = xlib.XftFontOpenName(display, screen, font_name_z);
        if (font == null) {
            allocator.destroy(sw);
            return null;
        }

        const font_height = font.*.ascent + font.*.descent;

        sw.* = .{
            .display = display,
            .root = root,
            .font = font,
            .font_height = font_height,
            .screen = screen,
        };

        return sw;
    }

    pub fn deinit(self: *WorkspaceSwitcher, allocator: std.mem.Allocator) void {
        if (self.display) |display| {
            self.destroyWindow(display);
            if (self.font) |font| {
                xlib.XftFontClose(display, font);
            }
        }
        allocator.destroy(self);
    }

    fn destroyWindow(self: *WorkspaceSwitcher, display: *xlib.Display) void {
        if (self.xft_draw) |xft_draw| {
            xlib.XftDrawDestroy(xft_draw);
            self.xft_draw = null;
        }
        if (self.gc) |gc| {
            _ = xlib.XFreeGC(display, gc);
            self.gc = null;
        }
        if (self.pixmap != 0) {
            _ = xlib.XFreePixmap(display, self.pixmap);
            self.pixmap = 0;
        }
        if (self.window != 0) {
            _ = xlib.c.XDestroyWindow(display, self.window);
            self.window = 0;
        }
    }

    pub fn isSwitcherWindow(self: *WorkspaceSwitcher, win: xlib.Window) bool {
        return self.visible and self.window != 0 and self.window == win;
    }

    pub fn show(self: *WorkspaceSwitcher, monitor: *monitor_mod.Monitor, master_mod_mask: c_uint, cfg: *config_mod.Config) void {
        const display = self.display orelse return;

        self.collectTags(monitor, cfg);
        if (self.item_count == 0) return;

        self.master_mod_mask = master_mod_mask;
        self.captureMasterKeycodes(display, master_mod_mask);

        const current_mask = monitor.tagset[monitor.sel_tags];
        self.selected = 0;

        var found_prev = false;
        if (monitor.pertag.prevtag >= 1 and monitor.pertag.prevtag <= 9 and monitor.pertag.prevtag != monitor.pertag.curtag) {
            const prev_mask: u32 = @as(u32, 1) << @intCast(monitor.pertag.prevtag - 1);
            if (prev_mask != current_mask) {
                for (0..self.item_count) |i| {
                    const tag_mask: u32 = @as(u32, 1) << @intCast(self.tag_indices[i]);
                    if (tag_mask == prev_mask) {
                        self.selected = i;
                        found_prev = true;
                        break;
                    }
                }
            }
        }

        if (!found_prev) {
            for (0..self.item_count) |i| {
                const tag_mask: u32 = @as(u32, 1) << @intCast(self.tag_indices[i]);
                if (tag_mask == current_mask) {
                    self.selected = i;
                    break;
                }
            }
        }

        var max_label_w: i32 = 0;
        for (0..self.item_count) |i| {
            const label = self.label_bufs[i][0..self.label_lens[i]];
            const w = self.textWidth(display, label);
            if (w > max_label_w) max_label_w = w;
        }

        self.cell_w = max_label_w + cell_padding_x * 2;
        self.cell_h = self.font_height + cell_padding_y * 2;

        const item_count_f: f32 = @floatFromInt(self.item_count);
        const cols_f: f32 = @ceil(@sqrt(item_count_f));
        self.cols = @intFromFloat(cols_f);
        if (self.cols == 0) self.cols = 1;
        self.rows = (self.item_count + self.cols - 1) / self.cols;

        const cols_i: i32 = @intCast(self.cols);
        const rows_i: i32 = @intCast(self.rows);
        self.width = padding * 2 + cols_i * self.cell_w + (cols_i - 1) * cell_gap;
        self.height = padding * 2 + rows_i * self.cell_h + (rows_i - 1) * cell_gap;

        self.destroyWindow(display);

        const x: i32 = monitor.mon_x + @divTrunc(monitor.mon_w - self.width, 2);
        const y: i32 = monitor.mon_y + @divTrunc(monitor.mon_h - self.height, 2);

        const visual = xlib.XDefaultVisual(display, self.screen);
        const colormap = xlib.XDefaultColormap(display, self.screen);
        const depth = xlib.XDefaultDepth(display, self.screen);

        self.window = xlib.c.XCreateSimpleWindow(
            display,
            self.root,
            x,
            y,
            @intCast(self.width),
            @intCast(self.height),
            @intCast(border_width),
            border_color,
            bg_color,
        );

        var attrs: xlib.c.XSetWindowAttributes = undefined;
        attrs.override_redirect = xlib.True;
        attrs.event_mask = xlib.c.ExposureMask | xlib.c.KeyPressMask | xlib.c.KeyReleaseMask;
        _ = xlib.c.XChangeWindowAttributes(display, self.window, xlib.c.CWOverrideRedirect | xlib.c.CWEventMask, &attrs);

        self.pixmap = xlib.XCreatePixmap(display, self.window, @intCast(self.width), @intCast(self.height), @intCast(depth));
        self.gc = xlib.XCreateGC(display, self.pixmap, 0, null);
        self.xft_draw = xlib.XftDrawCreate(display, self.pixmap, visual, colormap);

        _ = xlib.XMapWindow(display, self.window);
        _ = xlib.XRaiseWindow(display, self.window);

        self.draw(display);

        _ = xlib.XGrabKeyboard(display, self.window, xlib.True, xlib.GrabModeAsync, xlib.GrabModeAsync, xlib.CurrentTime);

        _ = xlib.XSync(display, xlib.False);

        self.visible = true;
    }

    pub fn hide(self: *WorkspaceSwitcher) void {
        if (!self.visible) return;
        if (self.display) |display| {
            _ = xlib.XUngrabKeyboard(display, xlib.CurrentTime);
            if (self.window != 0) {
                _ = xlib.XUnmapWindow(display, self.window);
            }
        }
        self.visible = false;
    }

    pub fn handleKey(self: *WorkspaceSwitcher, keysym: u64, state: c_uint, wm: *wm_mod.WindowManager) bool {
        if (!self.visible) return false;

        switch (keysym) {
            KeySym_Tab => {
                if ((state & xlib.ShiftMask) != 0) {
                    self.cyclePrev();
                } else {
                    self.cycleNext();
                }
                self.redraw();
                return true;
            },
            KeySym_ISO_Left_Tab => {
                self.cyclePrev();
                self.redraw();
                return true;
            },
            KeySym_Return => {
                self.confirm(wm);
                return true;
            },
            KeySym_Escape => {
                self.hide();
                return true;
            },
            else => return true,
        }
    }

    pub fn handleKeyRelease(self: *WorkspaceSwitcher, keycode: u8, wm: *wm_mod.WindowManager) bool {
        if (!self.visible) return false;
        if (self.master_keycode_count == 0) return false;

        var matched = false;
        for (0..self.master_keycode_count) |i| {
            if (self.master_keycodes[i] == keycode) {
                matched = true;
                break;
            }
        }
        if (!matched) return false;

        const display = self.display orelse return false;
        var keymap: [32]u8 = undefined;
        _ = xlib.XQueryKeymap(display, &keymap);

        for (0..self.master_keycode_count) |i| {
            const kc = self.master_keycodes[i];
            if (kc == keycode) continue;
            const byte = keymap[kc / 8];
            if ((byte & (@as(u8, 1) << @intCast(kc % 8))) != 0) {
                return true;
            }
        }

        self.confirm(wm);
        return true;
    }

    fn cycleNext(self: *WorkspaceSwitcher) void {
        if (self.item_count == 0) return;
        self.selected = (self.selected + 1) % self.item_count;
    }

    fn cyclePrev(self: *WorkspaceSwitcher) void {
        if (self.item_count == 0) return;
        self.selected = (self.selected + self.item_count - 1) % self.item_count;
    }

    fn confirm(self: *WorkspaceSwitcher, wm: *wm_mod.WindowManager) void {
        if (self.item_count == 0) {
            self.hide();
            return;
        }
        const tag_mask: u32 = @as(u32, 1) << @intCast(self.tag_indices[self.selected]);
        self.hide();
        core.view(tag_mask, wm);
    }

    fn redraw(self: *WorkspaceSwitcher) void {
        const display = self.display orelse return;
        if (!self.visible) return;
        self.draw(display);
    }

    fn collectTags(self: *WorkspaceSwitcher, monitor: *monitor_mod.Monitor, cfg: *config_mod.Config) void {
        self.item_count = 0;
        var i: u8 = 0;
        while (i < 9) : (i += 1) {
            const tag_mask: u32 = @as(u32, 1) << @intCast(i);
            if (!core.hasClientsOnTag(monitor, tag_mask)) continue;

            var count: u32 = 0;
            var c = monitor.clients;
            while (c) |cl| : (c = cl.next) {
                if ((cl.tags & tag_mask) != 0) count += 1;
            }

            const idx = self.item_count;
            self.tag_indices[idx] = i;
            self.tag_counts[idx] = count;

            const name: []const u8 = if (i < cfg.tags.len) cfg.tags[i] else "?";
            const written = std.fmt.bufPrint(&self.label_bufs[idx], "{s} ({d})", .{ name, count }) catch self.label_bufs[idx][0..0];
            self.label_lens[idx] = written.len;

            self.item_count += 1;
        }
    }

    fn captureMasterKeycodes(self: *WorkspaceSwitcher, display: *xlib.Display, mod_mask: c_uint) void {
        self.master_keycode_count = 0;

        const bit_index: ?usize = blk: {
            var bit: usize = 0;
            while (bit < 8) : (bit += 1) {
                if ((mod_mask & (@as(c_uint, 1) << @intCast(bit))) != 0) break :blk bit;
            }
            break :blk null;
        };
        const idx = bit_index orelse return;

        const modmap = xlib.XGetModifierMapping(display);
        if (modmap == null) return;
        defer _ = xlib.XFreeModifiermap(modmap);

        const max_per_mod: usize = @intCast(modmap.*.max_keypermod);
        var k: usize = 0;
        while (k < max_per_mod and self.master_keycode_count < self.master_keycodes.len) : (k += 1) {
            const kc = modmap.*.modifiermap[idx * max_per_mod + k];
            if (kc != 0) {
                self.master_keycodes[self.master_keycode_count] = kc;
                self.master_keycode_count += 1;
            }
        }
    }

    fn draw(self: *WorkspaceSwitcher, display: *xlib.Display) void {
        self.fillRect(display, 0, 0, self.width, self.height, bg_color);

        for (0..self.item_count) |i| {
            const col: i32 = @intCast(i % self.cols);
            const row: i32 = @intCast(i / self.cols);

            const cx = padding + col * (self.cell_w + cell_gap);
            const cy = padding + row * (self.cell_h + cell_gap);

            const is_selected = (i == self.selected);
            const cell_bg = if (is_selected) cell_selected_bg else cell_bg_color;
            const cell_fg = if (is_selected) cell_selected_fg else cell_fg_color;

            self.fillRect(display, cx, cy, self.cell_w, self.cell_h, cell_bg);

            const label = self.label_bufs[i][0..self.label_lens[i]];
            const tw = self.textWidth(display, label);
            const text_x = cx + @divTrunc(self.cell_w - tw, 2);
            const text_y = cy + @divTrunc(self.cell_h - self.font_height, 2) + self.font.?.*.ascent;
            self.drawText(display, text_x, text_y, label, cell_fg);
        }

        _ = xlib.c.XCopyArea(display, self.pixmap, self.window, self.gc, 0, 0, @intCast(self.width), @intCast(self.height), 0, 0);
        _ = xlib.c.XFlush(display);
    }

    fn fillRect(self: *WorkspaceSwitcher, display: *xlib.Display, x: i32, y: i32, w: i32, h: i32, color: c_ulong) void {
        _ = xlib.XSetForeground(display, self.gc, color);
        _ = xlib.XFillRectangle(display, self.pixmap, self.gc, x, y, @intCast(w), @intCast(h));
    }

    fn drawText(self: *WorkspaceSwitcher, display: *xlib.Display, x: i32, y: i32, text: []const u8, color: c_ulong) void {
        if (self.xft_draw == null or self.font == null) return;
        if (text.len == 0) return;

        var xft_color: xlib.XftColor = undefined;
        var render_color: xlib.XRenderColor = undefined;
        render_color.red = @intCast((color >> 16 & 0xff) * 257);
        render_color.green = @intCast((color >> 8 & 0xff) * 257);
        render_color.blue = @intCast((color & 0xff) * 257);
        render_color.alpha = 0xffff;

        const visual = xlib.XDefaultVisual(display, self.screen);
        const colormap = xlib.XDefaultColormap(display, self.screen);

        _ = xlib.XftColorAllocValue(display, visual, colormap, &render_color, &xft_color);
        xlib.XftDrawStringUtf8(self.xft_draw, &xft_color, self.font, x, y, text.ptr, @intCast(text.len));
        xlib.XftColorFree(display, visual, colormap, &xft_color);
    }

    fn textWidth(self: *WorkspaceSwitcher, display: *xlib.Display, text: []const u8) i32 {
        if (self.font == null or text.len == 0) return 0;
        var extents: xlib.XGlyphInfo = undefined;
        xlib.XftTextExtentsUtf8(display, self.font, text.ptr, @intCast(text.len), &extents);
        return extents.xOff;
    }
};
