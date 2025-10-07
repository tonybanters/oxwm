use crate::bar::Bar;
use crate::config::{
    BORDER_FOCUSED, BORDER_UNFOCUSED, BORDER_WIDTH, GAP_INNER_HORIZONTAL, GAP_INNER_VERTICAL,
    GAP_OUTER_HORIZONTAL, GAP_OUTER_VERTICAL, GAPS_ENABLED, TAG_COUNT,
};
use crate::keyboard::{self, Arg, KeyAction};
use crate::layout::GapConfig;
use crate::layout::Layout;
use crate::layout::tiling::TilingLayout;
use anyhow::Result;
use std::fs;
use std::path::PathBuf;
use std::process::Command;

use x11rb::connection::Connection;
use x11rb::protocol::Event;
use x11rb::protocol::xproto::*;
use x11rb::rust_connection::RustConnection;

pub type TagMask = u32;
pub fn tag_mask(tag: usize) -> TagMask {
    1 << tag
}

pub struct WindowManager {
    connection: RustConnection,
    screen_number: usize,
    root: Window,
    screen: Screen,
    windows: Vec<Window>,
    focused_window: Option<Window>,
    layout: Box<dyn Layout>,
    window_tags: std::collections::HashMap<Window, TagMask>,
    selected_tags: TagMask,
    gaps_enabled: bool,
    bar: Bar,
}

impl WindowManager {
    pub fn new() -> Result<Self> {
        let (connection, screen_number) = x11rb::connect(None)?;
        let root = connection.setup().roots[screen_number].root;
        let screen = connection.setup().roots[screen_number].clone();

        connection
            .change_window_attributes(
                root,
                &ChangeWindowAttributesAux::new().event_mask(
                    EventMask::SUBSTRUCTURE_REDIRECT
                        | EventMask::SUBSTRUCTURE_NOTIFY
                        | EventMask::PROPERTY_CHANGE
                        | EventMask::KEY_PRESS,
                ),
            )?
            .check()?;

        let bar = Bar::new(&connection, &screen, screen_number)?;

        let selected_tags = Self::get_saved_selected_tags(&connection, root)?;
        let gaps_enabled = GAPS_ENABLED;

        let mut window_manger = Self {
            connection,
            screen_number,
            root,
            screen,
            windows: Vec::new(),
            focused_window: None,
            layout: Box::new(TilingLayout),
            window_tags: std::collections::HashMap::new(),
            selected_tags,
            gaps_enabled,
            bar,
        };

        window_manger.scan_existing_windows()?;
        window_manger.update_bar()?;

        Ok(window_manger)
    }

    fn get_saved_selected_tags(connection: &RustConnection, root: Window) -> Result<TagMask> {
        let net_current_desktop = connection
            .intern_atom(false, b"_NET_CURRENT_DESKTOP")?
            .reply()?
            .atom;

        match connection
            .get_property(false, root, net_current_desktop, AtomEnum::CARDINAL, 0, 1)?
            .reply()
        {
            // I don't undestand this but I got it from dwm->persist_tags patch and it worked.
            Ok(prop) if prop.value.len() >= 4 => {
                let desktop = u32::from_ne_bytes([
                    prop.value[0],
                    prop.value[1],
                    prop.value[2],
                    prop.value[3],
                ]);
                if desktop < TAG_COUNT as u32 {
                    let mask = tag_mask(desktop as usize);
                    return Ok(mask);
                }
            }
            Ok(_) => {}
            Err(e) => {
                eprintln!("No _NET_CURRENT_DESKTOP property ({})", e);
            }
        }
        Ok(tag_mask(0))
    }

    fn scan_existing_windows(&mut self) -> Result<()> {
        let tree = self.connection.query_tree(self.root)?.reply()?;
        let net_client_info = self
            .connection
            .intern_atom(false, b"_NET_CLIENT_INFO")?
            .reply()?
            .atom;

        let wm_state_atom = self
            .connection
            .intern_atom(false, b"WM_STATE")?
            .reply()?
            .atom;

        for &window in &tree.children {
            if window == self.bar.window() {
                continue;
            }

            let attrs = match self.connection.get_window_attributes(window)?.reply() {
                Ok(attrs) => attrs,
                Err(_) => continue,
            };

            if attrs.override_redirect {
                continue;
            }

            if attrs.map_state == MapState::VIEWABLE {
                let tag = self.get_saved_tag(window, net_client_info)?;
                self.windows.push(window);
                self.window_tags.insert(window, tag);
                continue;
            }

            if attrs.map_state == MapState::UNMAPPED {
                let has_wm_state = match self
                    .connection
                    .get_property(false, window, wm_state_atom, AtomEnum::ANY, 0, 2)?
                    .reply()
                {
                    Ok(prop) => !prop.value.is_empty(),
                    Err(_) => false,
                };

                if !has_wm_state {
                    continue;
                }

                let has_wm_class = match self
                    .connection
                    .get_property(false, window, AtomEnum::WM_CLASS, AtomEnum::STRING, 0, 1024)?
                    .reply()
                {
                    Ok(prop) => !prop.value.is_empty(),
                    Err(_) => false,
                };

                if has_wm_class {
                    let tag = self.get_saved_tag(window, net_client_info)?;
                    self.windows.push(window);
                    self.window_tags.insert(window, tag);
                }
            }
        }

        if let Some(&first) = self.windows.first() {
            self.set_focus(Some(first))?;
        }

        self.apply_layout()?;
        Ok(())
    }

    fn get_saved_tag(&self, window: Window, net_client_info: Atom) -> Result<TagMask> {
        match self
            .connection
            .get_property(false, window, net_client_info, AtomEnum::CARDINAL, 0, 2)?
            .reply()
        {
            Ok(prop) if prop.value.len() >= 4 => {
                let tags = u32::from_ne_bytes([
                    prop.value[0],
                    prop.value[1],
                    prop.value[2],
                    prop.value[3],
                ]);

                if tags != 0 && tags < (1 << crate::config::TAG_COUNT) {
                    return Ok(tags);
                }
            }
            Ok(_) => {}
            Err(e) => {
                eprintln!("No _NET_CLIENT_INFO property ({})", e);
            }
        }

        Ok(self.selected_tags)
    }

    fn save_client_tag(&self, window: Window, tag: TagMask) -> Result<()> {
        let net_client_info = self
            .connection
            .intern_atom(false, b"_NET_CLIENT_INFO")?
            .reply()?
            .atom;

        let bytes = tag.to_ne_bytes().to_vec();

        self.connection.change_property(
            PropMode::REPLACE,
            window,
            net_client_info,
            AtomEnum::CARDINAL,
            32,
            1,
            &bytes,
        )?;

        self.connection.flush()?;
        Ok(())
    }

    fn set_wm_state(&self, window: Window, state: u32) -> Result<()> {
        let wm_state_atom = self
            .connection
            .intern_atom(false, b"WM_STATE")?
            .reply()?
            .atom;

        let data = [state, 0u32]; // No icon window
        let bytes: Vec<u8> = data.iter().flat_map(|&v| v.to_ne_bytes()).collect();

        self.connection.change_property(
            PropMode::REPLACE,
            window,
            wm_state_atom,
            wm_state_atom,
            32,
            2,
            &bytes,
        )?;

        self.connection.flush()?;
        Ok(())
    }

    fn get_config_file() -> Option<PathBuf> {
        if let Ok(home) = std::env::var("HOME") {
            let config_file = PathBuf::from(home).join(".config/oxwm/config.rs");
            if config_file.exists() {
                return Some(config_file);
            }
        }
        None
    }

    fn get_build_dir() -> PathBuf {
        let home = std::env::var("HOME").expect("HOME not set");
        PathBuf::from(home).join(".local/share/oxwm")
    }

    fn ensure_build_setup() -> Result<PathBuf> {
        let build_dir = Self::get_build_dir();
        let config_file = Self::get_config_file()
            .ok_or_else(|| anyhow::anyhow!("Config file not found at ~/.config/oxwm/config.rs"))?;

        fs::create_dir_all(&build_dir)?;
        fs::create_dir_all(build_dir.join("src"))?;

        let oxwm_lib_path = env!("CARGO_MANIFEST_DIR");

        let cargo_toml = format!(
            r#"[package]
name = "oxwm-config"
version = "0.1.0"
edition = "2024"

[dependencies]
oxwm = {{ path = "{}" }}
x11 = {{ version = "2.21", features = ["xlib", "xft"] }}
x11rb = "0.13"
anyhow = "1"
chrono = "0.4"
"#,
            oxwm_lib_path
        );
        fs::write(build_dir.join("Cargo.toml"), cargo_toml)?;

        let config_path = config_file.display();
        let main_rs = format!(
            r#"// Auto-generated - do not edit
#[path = "{}"]
mod config;

fn main() -> anyhow::Result<()> {{
    oxwm::run()
}}
"#,
            config_path
        );

        fs::write(build_dir.join("src/main.rs"), main_rs)?;

        Ok(build_dir)
    }

    fn rebuild_config() -> Result<PathBuf> {
        println!("Rebuilding config...");

        let build_dir = Self::ensure_build_setup()?;

        let status = Command::new("cargo")
            .args(["build", "--release"])
            .current_dir(&build_dir)
            .status()?;

        if !status.success() {
            anyhow::bail!("Config build failed! Check your ~/.config/oxwm/config.rs");
        }

        let binary = build_dir.join("target/release/oxwm-config");
        println!("Config rebuilt: {}", binary.display());

        Ok(binary)
    }
    // fn rebuild_config() -> Result<()> {
    //     let config_dir = Self::get_config_dir()
    //         .ok_or_else(|| anyhow::anyhow!("Config directory not found at ~/.config/oxwm"))?;
    //
    //     println!("Rebuilding config from {:?}", config_dir);
    //
    //     let status = Command::new("cargo")
    //         .args(["build", "--release"])
    //         .current_dir(&config_dir)
    //         .status()?;
    //
    //     if !status.success() {
    //         anyhow::bail!("Config build failed. Check your ~/.config/oxwm/src/config.rs");
    //     }
    //
    //     println!("Config rebuilt successfully");
    //     Ok(())
    // }

    pub fn run(&mut self) -> Result<bool> {
        println!("oxwm started on display {}", self.screen_number);

        keyboard::setup_keybinds(&self.connection, self.root)?;
        self.update_bar()?;

        loop {
            self.bar.update_blocks()?;

            if let Ok(Some(event)) = self.connection.poll_for_event() {
                if let Some(should_restart) = self.handle_event(event)? {
                    return Ok(should_restart);
                }
            }

            if self.bar.needs_redraw() {
                self.update_bar()?;
            }

            std::thread::sleep(std::time::Duration::from_millis(10));
        }
    }

    fn update_bar(&mut self) -> Result<()> {
        let mut occupied_tags: TagMask = 0;
        for &tags in self.window_tags.values() {
            occupied_tags |= tags;
        }

        self.bar.invalidate();
        self.bar
            .draw(&self.connection, self.selected_tags, occupied_tags)?;
        Ok(())
    }

    fn handle_key_action(&mut self, action: KeyAction, arg: &Arg) -> Result<()> {
        match action {
            KeyAction::Spawn => match arg {
                Arg::Str(command) => {
                    std::process::Command::new(command).spawn()?;
                }
                Arg::Array(cmd) => {
                    if let Some((program, args)) = cmd.split_first() {
                        std::process::Command::new(program).args(args).spawn()?;
                    }
                }
                _ => {}
            },
            KeyAction::KillClient => {
                if let Some(focused) = self.focused_window {
                    match self.connection.kill_client(focused) {
                        Ok(_) => {
                            self.connection.flush()?;
                        }
                        Err(e) => {
                            eprintln!("Failed to kill window {}: {}", focused, e);
                        }
                    }
                }
            }
            KeyAction::FocusStack => {
                if let Arg::Int(direction) = arg {
                    self.cycle_focus(*direction)?;
                }
            }
            KeyAction::Quit => {
                //no-op
            }
            KeyAction::Restart => {
                if let Err(e) = Self::rebuild_config() {
                    eprintln!("Rebuild failed: {}", e);
                    eprintln!("Restarting with current binary anyway...");
                }
            }
            KeyAction::ViewTag => {
                if let Arg::Int(tag_index) = arg {
                    self.view_tag(*tag_index as usize)?;
                }
            }
            KeyAction::MoveToTag => {
                if let Arg::Int(tag_index) = arg {
                    self.move_to_tag(*tag_index as usize)?;
                }
            }
            KeyAction::ToggleGaps => {
                self.gaps_enabled = !self.gaps_enabled;
                self.apply_layout()?;
            }
            KeyAction::None => {
                //no-op
            }
        }
        Ok(())
    }

    fn is_window_visible(&self, window: Window) -> bool {
        if let Some(&tags) = self.window_tags.get(&window) {
            (tags & self.selected_tags) != 0
        } else {
            false
        }
    }

    fn visible_windows(&self) -> Vec<Window> {
        self.windows
            .iter()
            .filter(|&&w| self.is_window_visible(w))
            .copied()
            .collect()
    }

    fn update_window_visibility(&self) -> Result<()> {
        for &window in &self.windows {
            if self.is_window_visible(window) {
                self.connection.map_window(window)?;
            } else {
                self.connection.unmap_window(window)?;
            }
        }
        self.connection.flush()?;
        Ok(())
    }

    pub fn view_tag(&mut self, tag_index: usize) -> Result<()> {
        if tag_index >= TAG_COUNT {
            return Ok(());
        }

        self.selected_tags = tag_mask(tag_index);

        self.save_selected_tags()?;

        self.update_window_visibility()?;
        self.apply_layout()?;
        self.update_bar()?;

        let visible = self.visible_windows();
        self.set_focus(visible.first().copied())?;

        Ok(())
    }

    fn save_selected_tags(&self) -> Result<()> {
        let net_current_desktop = self
            .connection
            .intern_atom(false, b"_NET_CURRENT_DESKTOP")?
            .reply()?
            .atom;

        let desktop = self.selected_tags.trailing_zeros();

        let bytes = (desktop).to_ne_bytes();
        self.connection.change_property(
            PropMode::REPLACE,
            self.root,
            net_current_desktop,
            AtomEnum::CARDINAL,
            32,
            1,
            &bytes,
        )?;

        self.connection.flush()?;
        Ok(())
    }

    pub fn move_to_tag(&mut self, tag_index: usize) -> Result<()> {
        if tag_index >= TAG_COUNT {
            return Ok(());
        }

        if let Some(focused) = self.focused_window {
            let mask = tag_mask(tag_index);
            self.window_tags.insert(focused, mask);

            let _ = self.save_client_tag(focused, mask);

            self.update_window_visibility()?;
            self.apply_layout()?;
            self.update_bar()?;
        }

        Ok(())
    }

    pub fn cycle_focus(&mut self, direction: i32) -> Result<()> {
        let visible = self.visible_windows();

        if visible.is_empty() {
            return Ok(());
        }

        let next_window = if let Some(current) = self.focused_window {
            if let Some(current_index) = visible.iter().position(|&w| w == current) {
                let next_index = if direction > 0 {
                    (current_index + 1) % visible.len()
                } else {
                    (current_index + visible.len() - 1) % visible.len()
                };
                visible[next_index]
            } else {
                visible[0]
            }
        } else {
            visible[0]
        };

        self.set_focus(Some(next_window))?;
        Ok(())
    }

    pub fn set_focus(&mut self, window: Option<Window>) -> Result<()> {
        self.focused_window = window;

        if let Some(win) = window {
            self.connection
                .set_input_focus(InputFocus::POINTER_ROOT, win, x11rb::CURRENT_TIME)?;
            self.connection.flush()?;
        }

        self.update_focus_visuals()?;
        Ok(())
    }

    fn update_focus_visuals(&self) -> Result<()> {
        for &window in &self.windows {
            let (border_color, border_width) = if self.focused_window == Some(window) {
                (BORDER_FOCUSED, BORDER_WIDTH)
            } else {
                (BORDER_UNFOCUSED, BORDER_WIDTH)
            };

            self.connection.configure_window(
                window,
                &ConfigureWindowAux::new().border_width(border_width),
            )?;

            self.connection.change_window_attributes(
                window,
                &ChangeWindowAttributesAux::new().border_pixel(border_color),
            )?;
        }
        self.connection.flush()?;
        Ok(())
    }

    fn handle_event(&mut self, event: Event) -> Result<Option<bool>> {
        match event {
            Event::MapRequest(event) => {
                let attrs = match self.connection.get_window_attributes(event.window)?.reply() {
                    Ok(attrs) => attrs,
                    Err(_) => return Ok(None),
                };

                if attrs.override_redirect {
                    return Ok(None);
                }

                if self.windows.contains(&event.window) {
                    return Ok(None);
                }

                self.connection.map_window(event.window)?;
                self.connection.change_window_attributes(
                    event.window,
                    &ChangeWindowAttributesAux::new().event_mask(EventMask::ENTER_WINDOW),
                )?;

                self.windows.push(event.window);
                self.window_tags.insert(event.window, self.selected_tags);
                self.set_wm_state(event.window, 1)?;
                let _ = self.save_client_tag(event.window, self.selected_tags);

                self.apply_layout()?;
                self.update_bar()?;
                self.set_focus(Some(event.window))?;
            }
            Event::UnmapNotify(event) => {
                if self.windows.contains(&event.window) && self.is_window_visible(event.window) {
                    self.remove_window(event.window)?;
                }
            }
            Event::DestroyNotify(event) => {
                if self.windows.contains(&event.window) {
                    self.remove_window(event.window)?;
                }
            }
            Event::EnterNotify(event) => {
                if event.mode != x11rb::protocol::xproto::NotifyMode::NORMAL {
                    return Ok(None);
                }
                if self.windows.contains(&event.event) {
                    self.set_focus(Some(event.event))?;
                }
            }
            Event::KeyPress(event) => {
                let (action, arg) = keyboard::handle_key_press(event)?;
                match action {
                    KeyAction::Quit => return Ok(Some(false)),
                    KeyAction::Restart => return Ok(Some(true)),
                    _ => self.handle_key_action(action, arg)?,
                }
            }
            Event::ButtonPress(event) => {
                if event.event == self.bar.window() {
                    if let Some(tag_index) = self.bar.handle_click(event.event_x) {
                        self.view_tag(tag_index)?;
                    }
                }
            }
            Event::Expose(event) => {
                if event.window == self.bar.window() {
                    self.bar.invalidate();
                    self.update_bar()?;
                }
            }
            _ => {}
        }
        Ok(None)
    }

    fn apply_layout(&self) -> Result<()> {
        let screen_width = self.screen.width_in_pixels as u32;
        let screen_height = self.screen.height_in_pixels as u32;
        let border_width = BORDER_WIDTH;

        let bar_height = self.bar.height() as u32;
        let usable_height = screen_height.saturating_sub(bar_height);

        let gaps = if self.gaps_enabled {
            GapConfig {
                inner_horizontal: GAP_INNER_HORIZONTAL,
                inner_vertical: GAP_INNER_VERTICAL,
                outer_horizontal: GAP_OUTER_HORIZONTAL,
                outer_vertical: GAP_OUTER_VERTICAL,
            }
        } else {
            GapConfig {
                inner_horizontal: 0,
                inner_vertical: 0,
                outer_horizontal: 0,
                outer_vertical: 0,
            }
        };

        let visible = self.visible_windows();
        let geometries = self
            .layout
            .arrange(&visible, screen_width, usable_height, &gaps);

        for (window, geometry) in visible.iter().zip(geometries.iter()) {
            let adjusted_width = geometry.width.saturating_sub(2 * border_width);
            let adjusted_height = geometry.height.saturating_sub(2 * border_width);

            let adjusted_y = geometry.y_coordinate + bar_height as i32;

            self.connection.configure_window(
                *window,
                &ConfigureWindowAux::new()
                    .x(geometry.x_coordinate)
                    .y(adjusted_y)
                    .width(adjusted_width)
                    .height(adjusted_height),
            )?;
        }
        self.connection.flush()?;
        Ok(())
    }

    fn remove_window(&mut self, window: Window) -> Result<()> {
        let initial_count = self.windows.len();
        self.windows.retain(|&w| w != window);
        self.window_tags.remove(&window);

        if self.windows.len() < initial_count {
            if self.focused_window == Some(window) {
                let new_focus = if self.windows.is_empty() {
                    None
                } else {
                    Some(self.windows[self.windows.len() - 1])
                };
                self.set_focus(new_focus)?;
            }

            self.apply_layout()?;
            self.update_bar()?;
        }
        Ok(())
    }
}
