use crate::ColorScheme;
use crate::bar::font::{Font, FontDraw};
use crate::errors::X11Error;
use crate::layout::tabbed::TAB_BAR_HEIGHT;
use x11rb::COPY_DEPTH_FROM_PARENT;
use x11rb::connection::Connection;
use x11rb::protocol::xproto::*;
use x11rb::rust_connection::RustConnection;

pub struct TabBar {
    window: Window,
    width: u16,
    height: u16,
    x_offset: i16,
    y_offset: i16,
    graphics_context: Gcontext,
    pixmap: x11::xlib::Pixmap,
    display: *mut x11::xlib::Display,
    font_draw: FontDraw,
    scheme_normal: ColorScheme,
    scheme_selected: ColorScheme,
}

impl TabBar {
    pub fn new(
        connection: &RustConnection,
        screen: &Screen,
        screen_num: usize,
        display: *mut x11::xlib::Display,
        _font: &Font,
        x: i16,
        y: i16,
        width: u16,
        scheme_normal: ColorScheme,
        scheme_selected: ColorScheme,
    ) -> Result<Self, X11Error> {
        let window = connection.generate_id()?;
        let graphics_context = connection.generate_id()?;

        let height = TAB_BAR_HEIGHT as u16;

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
                .background_pixel(scheme_normal.background)
                .event_mask(EventMask::EXPOSURE | EventMask::BUTTON_PRESS)
                .override_redirect(1),
        )?;

        connection.create_gc(
            graphics_context,
            window,
            &CreateGCAux::new()
                .foreground(scheme_normal.foreground)
                .background(scheme_normal.background),
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

        Ok(Self {
            window,
            width,
            height,
            x_offset: x,
            y_offset: y,
            graphics_context,
            pixmap,
            display,
            font_draw,
            scheme_normal,
            scheme_selected,
        })
    }

    pub fn window(&self) -> Window {
        self.window
    }

    pub fn draw(
        &mut self,
        connection: &RustConnection,
        font: &Font,
        windows: &[(Window, String)],
        focused_window: Option<Window>,
    ) -> Result<(), X11Error> {
        connection.change_gc(
            self.graphics_context,
            &ChangeGCAux::new().foreground(self.scheme_normal.background),
        )?;
        connection.flush()?;

        unsafe {
            let gc = x11::xlib::XCreateGC(self.display, self.pixmap, 0, std::ptr::null_mut());
            x11::xlib::XSetForeground(self.display, gc, self.scheme_normal.background as u64);
            x11::xlib::XFillRectangle(
                self.display,
                self.pixmap,
                gc,
                0,
                0,
                self.width as u32,
                self.height as u32,
            );
            x11::xlib::XFreeGC(self.display, gc);
        }

        if windows.is_empty() {
            self.copy_pixmap_to_window();
            return Ok(());
        }

        let tab_width = self.width / windows.len() as u16;
        let mut x_position: i16 = 0;

        for (index, &(window, ref title)) in windows.iter().enumerate() {
            let is_focused = Some(window) == focused_window;
            let scheme = if is_focused {
                &self.scheme_selected
            } else {
                &self.scheme_normal
            };

            let display_title = if title.is_empty() {
                format!("Window {}", index + 1)
            } else {
                title.clone()
            };

            let text_width = font.text_width(&display_title);
            let text_x = x_position + ((tab_width.saturating_sub(text_width)) / 2) as i16;

            let top_padding = 6;
            let text_y = top_padding + font.ascent();

            self.font_draw
                .draw_text(font, scheme.foreground, text_x, text_y, &display_title);

            if is_focused {
                let underline_height = 3;
                let underline_y = self.height as i16 - underline_height;

                unsafe {
                    let gc =
                        x11::xlib::XCreateGC(self.display, self.pixmap, 0, std::ptr::null_mut());
                    x11::xlib::XSetForeground(self.display, gc, scheme.underline as u64);
                    x11::xlib::XFillRectangle(
                        self.display,
                        self.pixmap,
                        gc,
                        x_position as i32,
                        underline_y as i32,
                        tab_width as u32,
                        underline_height as u32,
                    );
                    x11::xlib::XFreeGC(self.display, gc);
                }
            }

            x_position += tab_width as i16;
        }

        self.copy_pixmap_to_window();
        Ok(())
    }

    fn copy_pixmap_to_window(&self) {
        unsafe {
            let gc =
                x11::xlib::XCreateGC(self.display, self.window as u64, 0, std::ptr::null_mut());
            x11::xlib::XCopyArea(
                self.display,
                self.pixmap,
                self.window as u64,
                gc,
                0,
                0,
                self.width as u32,
                self.height as u32,
                0,
                0,
            );
            x11::xlib::XFreeGC(self.display, gc);
        }
    }

    pub fn get_clicked_window(&self, windows: &[(Window, String)], click_x: i16) -> Option<Window> {
        if windows.is_empty() {
            return None;
        }

        let tab_width = self.width / windows.len() as u16;
        let tab_index = (click_x as u16 / tab_width) as usize;

        windows.get(tab_index).map(|&(win, _)| win)
    }

    pub fn reposition(
        &mut self,
        connection: &RustConnection,
        x: i16,
        y: i16,
        width: u16,
    ) -> Result<(), X11Error> {
        self.x_offset = x;
        self.y_offset = y;
        self.width = width;

        connection.configure_window(
            self.window,
            &ConfigureWindowAux::new()
                .x(x as i32)
                .y(y as i32)
                .width(width as u32),
        )?;

        unsafe {
            x11::xlib::XFreePixmap(self.display, self.pixmap);
        }

        let depth = unsafe { x11::xlib::XDefaultDepth(self.display, 0) };
        self.pixmap = unsafe {
            x11::xlib::XCreatePixmap(
                self.display,
                self.window as x11::xlib::Drawable,
                width as u32,
                self.height as u32,
                depth as u32,
            )
        };

        let visual = unsafe { x11::xlib::XDefaultVisual(self.display, 0) };
        let colormap = unsafe { x11::xlib::XDefaultColormap(self.display, 0) };
        self.font_draw = FontDraw::new(self.display, self.pixmap, visual, colormap)?;

        connection.flush()?;
        Ok(())
    }

    pub fn hide(&self, connection: &RustConnection) -> Result<(), X11Error> {
        connection.unmap_window(self.window)?;
        connection.flush()?;
        Ok(())
    }

    pub fn show(&self, connection: &RustConnection) -> Result<(), X11Error> {
        connection.map_window(self.window)?;
        connection.flush()?;
        Ok(())
    }
}

impl Drop for TabBar {
    fn drop(&mut self) {
        unsafe {
            x11::xlib::XFreePixmap(self.display, self.pixmap);
        }
    }
}
