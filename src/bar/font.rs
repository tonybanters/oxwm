use std::ffi::CString;
use x11::xft::{XftColor, XftDraw, XftDrawStringUtf8, XftFont, XftFontOpenName};
use x11::xlib::{Colormap, Display, Drawable, Visual};
use x11::xrender::XRenderColor;

use crate::errors::X11Error;

pub struct Font {
    xft_font: *mut XftFont,
    display: *mut Display,
}

impl Font {
    pub fn new(display: *mut Display, screen: i32, font_name: &str) -> Result<Self, X11Error> {
        let font_name_cstr =
            CString::new(font_name).map_err(|_| X11Error::FontLoadFailed(font_name.to_string()))?;

        let xft_font = unsafe { XftFontOpenName(display, screen, font_name_cstr.as_ptr()) };

        if xft_font.is_null() {
            return Err(X11Error::FontLoadFailed(font_name.to_string()));
        }

        Ok(Font { xft_font, display })
    }

    pub fn height(&self) -> u16 {
        unsafe {
            let font = &*self.xft_font;
            font.height as u16
        }
    }

    pub fn ascent(&self) -> i16 {
        unsafe {
            let font = &*self.xft_font;
            font.ascent as i16
        }
    }

    pub fn text_width(&self, text: &str) -> u16 {
        unsafe {
            let mut extents = std::mem::zeroed();
            x11::xft::XftTextExtentsUtf8(
                self.display,
                self.xft_font,
                text.as_ptr(),
                text.len() as i32,
                &mut extents,
            );
            extents.width
        }
    }
}

impl Drop for Font {
    fn drop(&mut self) {
        unsafe {
            if !self.xft_font.is_null() {
                x11::xft::XftFontClose(self.display, self.xft_font);
            }
        }
    }
}

pub struct FontDraw {
    xft_draw: *mut XftDraw,
}

impl FontDraw {
    pub fn new(
        display: *mut Display,
        drawable: Drawable,
        visual: *mut Visual,
        colormap: Colormap,
    ) -> Result<Self, X11Error> {
        let xft_draw = unsafe { x11::xft::XftDrawCreate(display, drawable, visual, colormap) };

        if xft_draw.is_null() {
            return Err(X11Error::DrawCreateFailed);
        }

        Ok(FontDraw { xft_draw })
    }

    pub fn draw_text(&self, font: &Font, color: u32, x: i16, y: i16, text: &str) {
        let red = ((color >> 16) & 0xFF) as u16;
        let green = ((color >> 8) & 0xFF) as u16;
        let blue = (color & 0xFF) as u16;

        let render_color = XRenderColor {
            red: red << 8 | red,
            green: green << 8 | green,
            blue: blue << 8 | blue,
            alpha: 0xFFFF,
        };

        let mut xft_color: XftColor = unsafe { std::mem::zeroed() };

        unsafe {
            x11::xft::XftColorAllocValue(
                x11::xft::XftDrawDisplay(self.xft_draw),
                x11::xft::XftDrawVisual(self.xft_draw),
                x11::xft::XftDrawColormap(self.xft_draw),
                &render_color,
                &mut xft_color,
            );

            XftDrawStringUtf8(
                self.xft_draw,
                &xft_color,
                font.xft_font,
                x as i32,
                y as i32,
                text.as_ptr(),
                text.len() as i32,
            );

            x11::xft::XftColorFree(
                x11::xft::XftDrawDisplay(self.xft_draw),
                x11::xft::XftDrawVisual(self.xft_draw),
                x11::xft::XftDrawColormap(self.xft_draw),
                &mut xft_color,
            );
        }
    }

    pub fn flush(&self) {
        unsafe {
            let display = x11::xft::XftDrawDisplay(self.xft_draw);
            x11::xlib::XFlush(display);
        }
    }

    pub fn sync(&self) {
        unsafe {
            let display = x11::xft::XftDrawDisplay(self.xft_draw);
            x11::xlib::XSync(display, 0);
        }
    }
}

impl Drop for FontDraw {
    fn drop(&mut self) {
        unsafe {
            if !self.xft_draw.is_null() {
                x11::xft::XftDrawDestroy(self.xft_draw);
            }
        }
    }
}
