use super::blocks::Block;
use super::font::{Font, FontDraw};
use crate::Config;
use crate::errors::X11Error;
use std::time::Instant;
use x11rb::COPY_DEPTH_FROM_PARENT;
use x11rb::connection::Connection;
use x11rb::protocol::xproto::*;
use x11rb::rust_connection::RustConnection;

pub struct Bar {
    window: Window,
    width: u16,
    height: u16,
    graphics_context: Gcontext,
    pixmap: x11::xlib::Pixmap,
    display: *mut x11::xlib::Display,

    font_draw: FontDraw,

    tag_widths: Vec<u16>,
    needs_redraw: bool,

    blocks: Vec<Box<dyn Block>>,
    block_last_updates: Vec<Instant>,
    block_underlines: Vec<bool>,
    status_text: String,

    tags: Vec<String>,
    scheme_normal: crate::ColorScheme,
    scheme_occupied: crate::ColorScheme,
    scheme_selected: crate::ColorScheme,
}

impl Bar {
    pub fn new(
        connection: &RustConnection,
        screen: &Screen,
        screen_num: usize,
        config: &Config,
        display: *mut x11::xlib::Display,
        font: &Font,
        x: i16,
        y: i16,
        width: u16,
    ) -> Result<Self, X11Error> {
        let window = connection.generate_id()?;
        let graphics_context = connection.generate_id()?;

        let height = (font.height() as f32 * 1.4) as u16;

        connection.create_window(
            COPY_DEPTH_FROM_PARENT,
            window,
            screen.root,
            x,
            y,
            width,
            height,
            0,
            WindowClass::INPUT_OUTPUT,
            screen.root_visual,
            &CreateWindowAux::new()
                .background_pixel(config.scheme_normal.background)
                .event_mask(EventMask::EXPOSURE | EventMask::BUTTON_PRESS)
                .override_redirect(1),
        )?;

        connection.create_gc(
            graphics_context,
            window,
            &CreateGCAux::new()
                .foreground(config.scheme_normal.foreground)
                .background(config.scheme_normal.background),
        )?;

        connection.map_window(window)?;
        connection.flush()?;

        let visual = unsafe { x11::xlib::XDefaultVisual(display, screen_num as i32) };
        let colormap = unsafe { x11::xlib::XDefaultColormap(display, screen_num as i32) };
        let depth = unsafe { x11::xlib::XDefaultDepth(display, screen_num as i32) };

        let pixmap = unsafe {
            x11::xlib::XCreatePixmap(
                display,
                window as x11::xlib::Drawable,
                width as u32,
                height as u32,
                depth as u32,
            )
        };

        let font_draw = FontDraw::new(display, pixmap, visual, colormap)?;

        let horizontal_padding = (font.height() as f32 * 0.4) as u16;

        let tag_widths = config
            .tags
            .iter()
            .map(|tag| {
                let text_width = font.text_width(tag);
                text_width + (horizontal_padding * 2)
            })
            .collect();

        let blocks: Vec<Box<dyn Block>> = config
            .status_blocks
            .iter()
            .map(|block_config| block_config.to_block())
            .collect();

        let block_underlines: Vec<bool> = config
            .status_blocks
            .iter()
            .map(|block_config| block_config.underline)
            .collect();

        let block_last_updates = vec![Instant::now(); blocks.len()];

        Ok(Bar {
            window,
            width,
            height,
            graphics_context,
            pixmap,
            display,
            font_draw,
            tag_widths,
            needs_redraw: true,
            blocks,
            block_last_updates,
            block_underlines,
            status_text: String::new(),
            tags: config.tags.clone(),
            scheme_normal: config.scheme_normal,
            scheme_occupied: config.scheme_occupied,
            scheme_selected: config.scheme_selected,
        })
    }

    pub fn window(&self) -> Window {
        self.window
    }

    pub fn height(&self) -> u16 {
        self.height
    }

    pub fn invalidate(&mut self) {
        self.needs_redraw = true;
    }

    pub fn update_blocks(&mut self) {
        let now = Instant::now();
        let mut changed = false;

        for (i, block) in self.blocks.iter_mut().enumerate() {
            let elapsed = now.duration_since(self.block_last_updates[i]);

            if elapsed >= block.interval() {
                if block.content().is_ok() {
                    self.block_last_updates[i] = now;
                    changed = true;
                }
            }
        }

        if changed {
            let mut parts = Vec::new();
            for block in &mut self.blocks {
                if let Ok(text) = block.content() {
                    parts.push(text);
                }
            }
            self.status_text = parts.join("");
            self.needs_redraw = true;
        }
    }

    pub fn draw(
        &mut self,
        connection: &RustConnection,
        font: &Font,
        display: *mut x11::xlib::Display,
        current_tags: u32,
        occupied_tags: u32,
        draw_blocks: bool,
        layout_symbol: &str,
        keychord_indicator: Option<&str>,
    ) -> Result<(), X11Error> {
        if !self.needs_redraw {
            return Ok(());
        }

        connection.change_gc(
            self.graphics_context,
            &ChangeGCAux::new().foreground(self.scheme_normal.background),
        )?;
        connection.flush()?;

        unsafe {
            let gc = x11::xlib::XCreateGC(display, self.pixmap, 0, std::ptr::null_mut());
            x11::xlib::XSetForeground(display, gc, self.scheme_normal.background as u64);
            x11::xlib::XFillRectangle(
                display,
                self.pixmap,
                gc,
                0,
                0,
                self.width as u32,
                self.height as u32,
            );
            x11::xlib::XFreeGC(display, gc);
        }

        let mut x_position: i16 = 0;

        for (tag_index, tag) in self.tags.iter().enumerate() {
            let tag_mask = 1 << tag_index;
            let is_selected = (current_tags & tag_mask) != 0;
            let is_occupied = (occupied_tags & tag_mask) != 0;

            let tag_width = self.tag_widths[tag_index];

            let scheme = if is_selected {
                &self.scheme_selected
            } else if is_occupied {
                &self.scheme_occupied
            } else {
                &self.scheme_normal
            };

            let text_width = font.text_width(tag);
            let text_x = x_position + ((tag_width - text_width) / 2) as i16;

            let top_padding = 4;
            let text_y = top_padding + font.ascent();

            self.font_draw
                .draw_text(font, scheme.foreground, text_x, text_y, tag);

            if is_selected {
                let font_height = font.height();
                let underline_height = font_height / 8;
                let bottom_gap = 3;
                let underline_y = self.height as i16 - underline_height as i16 - bottom_gap;

                let underline_padding = 4;
                let underline_width = tag_width - underline_padding;
                let underline_x = x_position + (underline_padding / 2) as i16;

                unsafe {
                    let gc = x11::xlib::XCreateGC(display, self.pixmap, 0, std::ptr::null_mut());
                    x11::xlib::XSetForeground(display, gc, scheme.underline as u64);
                    x11::xlib::XFillRectangle(
                        display,
                        self.pixmap,
                        gc,
                        underline_x as i32,
                        underline_y as i32,
                        underline_width as u32,
                        underline_height as u32,
                    );
                    x11::xlib::XFreeGC(display, gc);
                }
            }

            x_position += tag_width as i16;
        }

        x_position += 10;

        let text_x = x_position;
        let top_padding = 4;
        let text_y = top_padding + font.ascent();

        self.font_draw.draw_text(
            font,
            self.scheme_normal.foreground,
            text_x,
            text_y,
            layout_symbol,
        );

        x_position += font.text_width(layout_symbol) as i16;

        if let Some(indicator) = keychord_indicator {
            x_position += 10;

            let text_x = x_position;
            let text_y = top_padding + font.ascent();

            self.font_draw.draw_text(
                font,
                self.scheme_selected.foreground,
                text_x,
                text_y,
                indicator,
            );
        }

        if draw_blocks && !self.status_text.is_empty() {
            let padding = 10;
            let mut x_position = self.width as i16 - padding;

            for (i, block) in self.blocks.iter_mut().enumerate().rev() {
                if let Ok(text) = block.content() {
                    let text_width = font.text_width(&text);
                    x_position -= text_width as i16;

                    let top_padding = 4;
                    let text_y = top_padding + font.ascent();

                    self.font_draw
                        .draw_text(font, block.color(), x_position, text_y, &text);

                    if self.block_underlines[i] {
                        let font_height = font.height();
                        let underline_height = font_height / 8;
                        let bottom_gap = 3;
                        let underline_y = self.height as i16 - underline_height as i16 - bottom_gap;

                        let underline_padding = 8;
                        let underline_width = text_width + underline_padding;
                        let underline_x = x_position - (underline_padding / 2) as i16;

                        unsafe {
                            let gc =
                                x11::xlib::XCreateGC(display, self.pixmap, 0, std::ptr::null_mut());
                            x11::xlib::XSetForeground(display, gc, block.color() as u64);
                            x11::xlib::XFillRectangle(
                                display,
                                self.pixmap,
                                gc,
                                underline_x as i32,
                                underline_y as i32,
                                underline_width as u32,
                                underline_height as u32,
                            );
                            x11::xlib::XFreeGC(display, gc);
                        }
                    }
                }
            }
        }

        unsafe {
            let gc = x11::xlib::XCreateGC(
                display,
                self.window as x11::xlib::Drawable,
                0,
                std::ptr::null_mut(),
            );
            x11::xlib::XCopyArea(
                display,
                self.pixmap,
                self.window as x11::xlib::Drawable,
                gc,
                0,
                0,
                self.width as u32,
                self.height as u32,
                0,
                0,
            );
            x11::xlib::XFreeGC(display, gc);
            x11::xlib::XSync(display, 0);
        }

        self.needs_redraw = false;

        Ok(())
    }

    pub fn handle_click(&self, click_x: i16) -> Option<usize> {
        let mut current_x_position = 0;

        for (tag_index, &tag_width) in self.tag_widths.iter().enumerate() {
            if click_x >= current_x_position && click_x < current_x_position + tag_width as i16 {
                return Some(tag_index);
            }
            current_x_position += tag_width as i16;
        }
        None
    }

    pub fn needs_redraw(&self) -> bool {
        self.needs_redraw
    }

    pub fn update_from_config(&mut self, config: &Config) {
        self.blocks = config
            .status_blocks
            .iter()
            .map(|block_config| block_config.to_block())
            .collect();

        self.block_underlines = config
            .status_blocks
            .iter()
            .map(|block_config| block_config.underline)
            .collect();

        self.block_last_updates = vec![Instant::now(); self.blocks.len()];

        self.tags = config.tags.clone();
        self.scheme_normal = config.scheme_normal;
        self.scheme_occupied = config.scheme_occupied;
        self.scheme_selected = config.scheme_selected;

        self.status_text.clear();
        self.needs_redraw = true;
    }
}

impl Drop for Bar {
    fn drop(&mut self) {
        unsafe {
            x11::xlib::XFreePixmap(self.display, self.pixmap);
        }
    }
}
