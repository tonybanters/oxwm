use super::{Overlay, OverlayBase};
use crate::bar::font::Font;
use crate::errors::X11Error;
use crate::keyboard::KeyAction;
use crate::keyboard::handlers::{KeyBinding, KeyPress};
use std::time::Instant;
use x11rb::connection::Connection;
use x11rb::protocol::xproto::*;
use x11rb::rust_connection::RustConnection;

const PADDING: i16 = 24;
const KEY_ACTION_SPACING: i16 = 20;
const LINE_SPACING: i16 = 8;
const BORDER_WIDTH: u16 = 4;
const BORDER_COLOR: u32 = 0x7fccff;
const TITLE_BOTTOM_MARGIN: i16 = 20;
const INPUT_SUPPRESS_MS: u128 = 200;

pub struct KeybindOverlay {
    base: OverlayBase,
    keybindings: Vec<(String, String)>,
    key_bg_color: u32,
    modkey: KeyButMask,
    last_shown_at: Option<Instant>,
    max_key_width: u16,
}

impl KeybindOverlay {
    pub fn new(
        connection: &RustConnection,
        screen: &Screen,
        screen_num: usize,
        display: *mut x11::xlib::Display,
        modkey: KeyButMask,
    ) -> Result<Self, X11Error> {
        let base = OverlayBase::new(
            connection,
            screen,
            screen_num,
            display,
            800,
            600,
            BORDER_WIDTH,
            BORDER_COLOR,
            0x1a1a1a,
            0xffffff,
        )?;

        Ok(KeybindOverlay {
            base,
            keybindings: Vec::new(),
            key_bg_color: 0x2a2a2a,
            modkey,
            last_shown_at: None,
            max_key_width: 0,
        })
    }

    pub fn show(
        &mut self,
        connection: &RustConnection,
        font: &Font,
        keybindings: &[KeyBinding],
        monitor_x: i16,
        monitor_y: i16,
        screen_width: u16,
        screen_height: u16,
    ) -> Result<(), X11Error> {
        self.keybindings = self.collect_keybindings(keybindings);

        let title = "Important Keybindings";
        let title_width = font.text_width(title);

        let mut max_key_width = 0u16;
        let mut max_action_width = 0u16;

        for (key, action) in &self.keybindings {
            let key_width = font.text_width(key);
            let action_width = font.text_width(action);
            if key_width > max_key_width {
                max_key_width = key_width;
            }
            if action_width > max_action_width {
                max_action_width = action_width;
            }
        }

        let content_width = max_key_width + KEY_ACTION_SPACING as u16 + max_action_width;
        let min_width = title_width.max(content_width);

        let width = min_width + (PADDING as u16 * 2);

        let line_height = font.height() + LINE_SPACING as u16;
        let title_height = font.height() + TITLE_BOTTOM_MARGIN as u16;
        let height =
            title_height + (self.keybindings.len() as u16 * line_height) + (PADDING as u16 * 2);

        let x = monitor_x + ((screen_width - width) / 2) as i16;
        let y = monitor_y + ((screen_height - height) / 2) as i16;

        self.base.configure(connection, x, y, width, height)?;

        self.last_shown_at = Some(Instant::now());
        self.max_key_width = max_key_width;

        self.base.is_visible = true;
        self.draw(connection, font)?;

        self.base.show(connection)?;

        Ok(())
    }

    pub fn toggle(
        &mut self,
        connection: &RustConnection,
        font: &Font,
        keybindings: &[KeyBinding],
        monitor_x: i16,
        monitor_y: i16,
        screen_width: u16,
        screen_height: u16,
    ) -> Result<(), X11Error> {
        if self.base.is_visible {
            self.hide(connection)?;
        } else {
            self.show(
                connection,
                font,
                keybindings,
                monitor_x,
                monitor_y,
                screen_width,
                screen_height,
            )?;
        }
        Ok(())
    }

    pub fn should_suppress_input(&self) -> bool {
        if let Some(shown_at) = self.last_shown_at {
            shown_at.elapsed().as_millis() < INPUT_SUPPRESS_MS
        } else {
            false
        }
    }

    fn collect_keybindings(&self, keybindings: &[KeyBinding]) -> Vec<(String, String)> {
        let mut result = Vec::new();

        let priority_actions = [
            KeyAction::ShowKeybindOverlay,
            KeyAction::Quit,
            KeyAction::Restart,
            KeyAction::KillClient,
            KeyAction::Spawn,
            KeyAction::SpawnTerminal,
            KeyAction::ToggleFullScreen,
            KeyAction::ToggleFloating,
            KeyAction::CycleLayout,
            KeyAction::FocusStack,
            KeyAction::ViewTag,
        ];

        for &action in &priority_actions {
            let binding = keybindings
                .iter()
                .filter(|kb| kb.func == action)
                .min_by_key(|kb| kb.keys.len());

            if let Some(binding) = binding {
                if !binding.keys.is_empty() {
                    let key_str = self.format_key_combo(&binding.keys[0]);
                    let action_str = self.action_description(binding);
                    result.push((key_str, action_str));
                }
            }
        }

        result
    }

    fn format_key_combo(&self, key: &KeyPress) -> String {
        let mut parts = Vec::new();

        for modifier in &key.modifiers {
            let mod_str = match *modifier {
                m if m == self.modkey => "Mod",
                KeyButMask::SHIFT => "Shift",
                KeyButMask::CONTROL => "Ctrl",
                KeyButMask::MOD1 => "Alt",
                KeyButMask::MOD4 => "Super",
                _ => continue,
            };
            parts.push(mod_str.to_string());
        }

        parts.push(crate::keyboard::keysyms::format_keysym(key.keysym));

        parts.join(" + ")
    }

    fn action_description(&self, binding: &KeyBinding) -> String {
        use crate::keyboard::Arg;

        match binding.func {
            KeyAction::ShowKeybindOverlay => "Show This Keybind Help".to_string(),
            KeyAction::Quit => "Quit Window Manager".to_string(),
            KeyAction::Restart => "Restart Window Manager".to_string(),
            KeyAction::KillClient => "Close Focused Window".to_string(),
            KeyAction::Spawn => match &binding.arg {
                Arg::Str(cmd) => format!("Launch: {}", cmd),
                Arg::Array(arr) if !arr.is_empty() => format!("Launch: {}", arr[0]),
                _ => "Launch Program".to_string(),
            },
            KeyAction::SpawnTerminal => "Launch Terminal".to_string(),
            KeyAction::FocusStack => "Focus Next/Previous Window".to_string(),
            KeyAction::MoveStack => "Move Window Up/Down Stack".to_string(),
            KeyAction::ViewTag => match &binding.arg {
                Arg::Int(n) => format!("View Workspace {}", n),
                _ => "View Workspace".to_string(),
            },
            KeyAction::ToggleView => match &binding.arg {
                Arg::Int(n) => format!("Toggle View Workspace {}", n),
                _ => "Toggle View Workspace".to_string(),
            },
            KeyAction::MoveToTag => "Move Window to Workspace".to_string(),
            KeyAction::ToggleTag => "Toggle Window on Workspace".to_string(),
            KeyAction::ToggleGaps => "Toggle Window Gaps".to_string(),
            KeyAction::ToggleFullScreen => "Toggle Fullscreen Mode".to_string(),
            KeyAction::ToggleFloating => "Toggle Floating Mode".to_string(),
            KeyAction::ChangeLayout => "Change Layout".to_string(),
            KeyAction::CycleLayout => "Cycle Through Layouts".to_string(),
            KeyAction::FocusMonitor => "Focus Next Monitor".to_string(),
            KeyAction::TagMonitor => "Send Window to Monitor".to_string(),
            KeyAction::SetMasterFactor => "Adjust Master Area Size".to_string(),
            KeyAction::IncNumMaster => "Adjust Number of Master Windows".to_string(),
            KeyAction::None => "No Action".to_string(),
        }
    }
}

impl Overlay for KeybindOverlay {
    fn window(&self) -> Window {
        self.base.window
    }

    fn is_visible(&self) -> bool {
        self.base.is_visible
    }

    fn hide(&mut self, connection: &RustConnection) -> Result<(), X11Error> {
        self.base.hide(connection)?;
        self.last_shown_at = None;
        self.keybindings.clear();
        Ok(())
    }

    fn draw(&self, connection: &RustConnection, font: &Font) -> Result<(), X11Error> {
        if !self.base.is_visible {
            return Ok(());
        }

        self.base.draw_background(connection)?;

        let title = "Important Keybindings";
        let title_width = font.text_width(title);
        let title_x = ((self.base.width - title_width) / 2) as i16;
        let title_y = PADDING + font.ascent();

        self.base
            .font_draw
            .draw_text(font, self.base.foreground_color, title_x, title_y, title);

        let line_height = font.height() + LINE_SPACING as u16;
        let mut y = PADDING + font.height() as i16 + TITLE_BOTTOM_MARGIN + font.ascent();

        for (key, action) in &self.keybindings {
            let key_width = font.text_width(key);
            let key_x = PADDING;

            connection.change_gc(
                self.base.graphics_context,
                &ChangeGCAux::new().foreground(self.key_bg_color),
            )?;
            connection.poly_fill_rectangle(
                self.base.window,
                self.base.graphics_context,
                &[Rectangle {
                    x: key_x - 4,
                    y: y - font.ascent() - 2,
                    width: key_width + 8,
                    height: font.height() + 4,
                }],
            )?;

            self.base
                .font_draw
                .draw_text(font, self.base.foreground_color, key_x, y, key);

            let action_x = PADDING + self.max_key_width as i16 + KEY_ACTION_SPACING;
            self.base
                .font_draw
                .draw_text(font, self.base.foreground_color, action_x, y, action);

            y += line_height as i16;
        }

        connection.flush()?;
        self.base.font_draw.sync();

        Ok(())
    }
}
