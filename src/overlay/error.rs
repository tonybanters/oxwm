use super::{Overlay, OverlayBase};
use crate::bar::font::Font;
use crate::errors::X11Error;
use x11rb::connection::Connection;
use x11rb::protocol::xproto::*;
use x11rb::rust_connection::RustConnection;

const PADDING: i16 = 20;
const LINE_SPACING: i16 = 5;
const BORDER_WIDTH: u16 = 2;
const BORDER_COLOR: u32 = 0xff5555;

pub struct ErrorOverlay {
    base: OverlayBase,
    lines: Vec<String>,
}

impl ErrorOverlay {
    pub fn new(
        connection: &RustConnection,
        screen: &Screen,
        screen_num: usize,
        display: *mut x11::xlib::Display,
        _font: &Font,
        _max_width: u16,
    ) -> Result<Self, X11Error> {
        let base = OverlayBase::new(
            connection,
            screen,
            screen_num,
            display,
            400,
            200,
            BORDER_WIDTH,
            BORDER_COLOR,
            0x1a1a1a,
            0xffffff,
        )?;

        Ok(ErrorOverlay {
            base,
            lines: Vec::new(),
        })
    }

    pub fn show_error(
        &mut self,
        connection: &RustConnection,
        font: &Font,
        error_text: &str,
        monitor_x: i16,
        monitor_y: i16,
        screen_width: u16,
        screen_height: u16,
    ) -> Result<(), X11Error> {
        let max_line_width = (screen_width as i16 / 2 - PADDING * 4).max(300) as u16;
        let error_with_instruction = format!("{}\n\nFix the config file and reload.", error_text);
        self.lines = self.wrap_text(&error_with_instruction, font, max_line_width);

        let mut content_width = 0u16;
        for line in &self.lines {
            let line_width = font.text_width(line);
            if line_width > content_width {
                content_width = line_width;
            }
        }

        let width = content_width + (PADDING as u16 * 2);
        let line_height = font.height() + LINE_SPACING as u16;
        let height = (self.lines.len() as u16 * line_height) + (PADDING as u16 * 2);

        let x = monitor_x + ((screen_width - width) / 2) as i16;
        let y = monitor_y + ((screen_height - height) / 2) as i16;

        self.base.configure(connection, x, y, width, height)?;
        self.base.is_visible = true;
        self.draw(connection, font)?;
        self.base.show(connection)?;
        Ok(())
    }

    fn wrap_text(&self, text: &str, font: &Font, max_width: u16) -> Vec<String> {
        let mut lines = Vec::new();
        for paragraph in text.lines() {
            if paragraph.trim().is_empty() {
                lines.push(String::new());
                continue;
            }

            let words: Vec<&str> = paragraph.split_whitespace().collect();
            let mut current_line = String::new();

            for word in words {
                let test_line = if current_line.is_empty() {
                    word.to_string()
                } else {
                    format!("{} {}", current_line, word)
                };
                if font.text_width(&test_line) <= max_width {
                    current_line = test_line;
                } else {
                    if !current_line.is_empty() {
                        lines.push(current_line);
                    }
                    current_line = word.to_string();
                }
            }
            if !current_line.is_empty() {
                lines.push(current_line);
            }
        }
        lines
    }
}

impl Overlay for ErrorOverlay {
    fn window(&self) -> Window {
        self.base.window
    }

    fn is_visible(&self) -> bool {
        self.base.is_visible
    }

    fn hide(&mut self, connection: &RustConnection) -> Result<(), X11Error> {
        self.base.hide(connection)?;
        self.lines.clear();
        Ok(())
    }

    fn draw(&self, connection: &RustConnection, font: &Font) -> Result<(), X11Error> {
        if !self.base.is_visible {
            return Ok(());
        }
        self.base.draw_background(connection)?;
        let line_height = font.height() + LINE_SPACING as u16;
        let mut y = PADDING + font.ascent();
        for line in &self.lines {
            self.base
                .font_draw
                .draw_text(font, self.base.foreground_color, PADDING, y, line);
            y += line_height as i16;
        }
        connection.flush()?;
        self.base.font_draw.sync();
        Ok(())
    }
}
