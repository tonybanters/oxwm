use crate::Config;
use crate::bar::Bar;
use crate::client::{Client, TagMask};
use crate::errors::WmError;
use crate::keyboard::{self, Arg, KeyAction, handlers};
use crate::layout::GapConfig;
use crate::layout::tiling::TilingLayout;
use crate::layout::{Layout, LayoutBox, LayoutType, layout_from_str, next_layout};
use crate::monitor::{Monitor, detect_monitors};
use crate::overlay::{ErrorOverlay, KeybindOverlay, Overlay};
use std::collections::{HashMap, HashSet};
use x11rb::cursor::Handle as CursorHandle;

use x11rb::connection::Connection;
use x11rb::protocol::Event;
use x11rb::protocol::xproto::*;
use x11rb::rust_connection::RustConnection;

pub fn tag_mask(tag: usize) -> TagMask {
    1 << tag
}

/// Get back a tag index from a [`TagMask`]
pub fn unmask_tag(mask: TagMask) -> usize {
    // mask only has one bit set, so this works.
    mask.trailing_zeros() as usize
}

struct AtomCache {
    net_current_desktop: Atom,
    net_client_info: Atom,
    wm_state: Atom,
    wm_protocols: Atom,
    wm_delete_window: Atom,
    net_wm_state: Atom,
    net_wm_state_fullscreen: Atom,
    net_wm_window_type: Atom,
    net_wm_window_type_dialog: Atom,
    wm_name: Atom,
    net_wm_name: Atom,
    utf8_string: Atom,
    net_active_window: Atom,
}

impl AtomCache {
    fn new(connection: &RustConnection) -> WmResult<Self> {
        let net_current_desktop = connection
            .intern_atom(false, b"_NET_CURRENT_DESKTOP")?
            .reply()?
            .atom;

        let net_client_info = connection
            .intern_atom(false, b"_NET_CLIENT_INFO")?
            .reply()?
            .atom;

        let wm_state = connection.intern_atom(false, b"WM_STATE")?.reply()?.atom;

        let wm_protocols = connection
            .intern_atom(false, b"WM_PROTOCOLS")?
            .reply()?
            .atom;

        let wm_delete_window = connection
            .intern_atom(false, b"WM_DELETE_WINDOW")?
            .reply()?
            .atom;

        let net_wm_state = connection
            .intern_atom(false, b"_NET_WM_STATE")?
            .reply()?
            .atom;

        let net_wm_state_fullscreen = connection
            .intern_atom(false, b"_NET_WM_STATE_FULLSCREEN")?
            .reply()?
            .atom;

        let net_wm_window_type = connection
            .intern_atom(false, b"_NET_WM_WINDOW_TYPE")?
            .reply()?
            .atom;

        let net_wm_window_type_dialog = connection
            .intern_atom(false, b"_NET_WM_WINDOW_TYPE_DIALOG")?
            .reply()?
            .atom;

        let wm_name = AtomEnum::WM_NAME.into();
        let net_wm_name = connection
            .intern_atom(false, b"_NET_WM_NAME")?
            .reply()?
            .atom;
        let utf8_string = connection.intern_atom(false, b"UTF8_STRING")?.reply()?.atom;
        let net_active_window = connection
            .intern_atom(false, b"_NET_ACTIVE_WINDOW")?
            .reply()?
            .atom;

        Ok(Self {
            net_current_desktop,
            net_client_info,
            wm_state,
            wm_protocols,
            wm_delete_window,
            net_wm_state,
            net_wm_state_fullscreen,
            net_wm_window_type,
            net_wm_window_type_dialog,
            wm_name,
            net_wm_name,
            utf8_string,
            net_active_window,
        })
    }
}

pub struct WindowManager {
    config: Config,
    connection: RustConnection,
    screen_number: usize,
    root: Window,
    screen: Screen,
    windows: Vec<Window>,
    clients: HashMap<Window, Client>,
    layout: LayoutBox,
    gaps_enabled: bool,
    floating_windows: HashSet<Window>,
    fullscreen_windows: HashSet<Window>,
    floating_geometry_before_fullscreen: HashMap<Window, (i16, i16, u16, u16, u16)>,
    bars: Vec<Bar>,
    tab_bars: Vec<crate::tab_bar::TabBar>,
    show_bar: bool,
    last_layout: Option<&'static str>,
    monitors: Vec<Monitor>,
    selected_monitor: usize,
    atoms: AtomCache,
    previous_focused: Option<Window>,
    display: *mut x11::xlib::Display,
    font: crate::bar::font::Font,
    keychord_state: keyboard::handlers::KeychordState,
    current_key: usize,
    keyboard_mapping: Option<keyboard::KeyboardMapping>,
    error_message: Option<String>,
    overlay: ErrorOverlay,
    keybind_overlay: KeybindOverlay,
}

type WmResult<T> = Result<T, WmError>;

impl WindowManager {
    pub fn new(config: Config) -> WmResult<Self> {
        let (connection, screen_number) = x11rb::connect(None)?;
        let root = connection.setup().roots[screen_number].root;
        let screen = connection.setup().roots[screen_number].clone();

        let normal_cursor = CursorHandle::new(
            &connection,
            screen_number,
            &x11rb::resource_manager::new_from_default(&connection)?,
        )?
        .reply()?
        .load_cursor(&connection, "left_ptr")?;

        connection
            .change_window_attributes(
                root,
                &ChangeWindowAttributesAux::new()
                    .cursor(normal_cursor)
                    .event_mask(
                        EventMask::SUBSTRUCTURE_REDIRECT
                            | EventMask::SUBSTRUCTURE_NOTIFY
                            | EventMask::PROPERTY_CHANGE
                            | EventMask::KEY_PRESS
                            | EventMask::BUTTON_PRESS
                            | EventMask::POINTER_MOTION,
                    ),
            )?
            .check()?;

        let ignore_modifiers = [
            0,
            u16::from(ModMask::LOCK),
            u16::from(ModMask::M2),
            u16::from(ModMask::LOCK | ModMask::M2),
        ];

        for &ignore_mask in &ignore_modifiers {
            let grab_mask = u16::from(config.modkey) | ignore_mask;

            connection.grab_button(
                false,
                root,
                EventMask::BUTTON_PRESS | EventMask::BUTTON_RELEASE,
                GrabMode::SYNC,
                GrabMode::ASYNC,
                x11rb::NONE,
                x11rb::NONE,
                ButtonIndex::M1,
                grab_mask.into(),
            )?;

            connection.grab_button(
                false,
                root,
                EventMask::BUTTON_PRESS | EventMask::BUTTON_RELEASE,
                GrabMode::SYNC,
                GrabMode::ASYNC,
                x11rb::NONE,
                x11rb::NONE,
                ButtonIndex::M3,
                grab_mask.into(),
            )?;
        }

        let monitors = detect_monitors(&connection, &screen, root)?;

        let display = unsafe { x11::xlib::XOpenDisplay(std::ptr::null()) };
        if display.is_null() {
            return Err(WmError::X11(crate::errors::X11Error::DisplayOpenFailed));
        }

        let font = crate::bar::font::Font::new(display, screen_number as i32, &config.font)?;

        let mut bars = Vec::new();
        for monitor in monitors.iter() {
            let bar = Bar::new(
                &connection,
                &screen,
                screen_number,
                &config,
                display,
                &font,
                monitor.screen_x as i16,
                monitor.screen_y as i16,
                monitor.screen_width as u16,
            )?;
            bars.push(bar);
        }

        let bar_height = font.height() as f32 * 1.4;
        let mut tab_bars = Vec::new();
        for monitor in monitors.iter() {
            let tab_bar = crate::tab_bar::TabBar::new(
                &connection,
                &screen,
                screen_number,
                display,
                &font,
                (monitor.screen_x + config.gap_outer_horizontal as i32) as i16,
                (monitor.screen_y as f32 + bar_height + config.gap_outer_vertical as f32) as i16,
                monitor
                    .screen_width
                    .saturating_sub(2 * config.gap_outer_horizontal as i32) as u16,
                config.scheme_occupied,
                config.scheme_selected,
            )?;
            tab_bars.push(tab_bar);
        }

        let gaps_enabled = config.gaps_enabled;

        let atoms = AtomCache::new(&connection)?;

        let overlay = ErrorOverlay::new(
            &connection,
            &screen,
            screen_number,
            display,
            &font,
            screen.width_in_pixels,
        )?;

        let keybind_overlay =
            KeybindOverlay::new(&connection, &screen, screen_number, display, config.modkey)?;

        let mut window_manager = Self {
            config,
            connection,
            screen_number,
            root,
            screen,
            windows: Vec::new(),
            clients: HashMap::new(),
            layout: Box::new(TilingLayout),
            gaps_enabled,
            floating_windows: HashSet::new(),
            fullscreen_windows: HashSet::new(),
            floating_geometry_before_fullscreen: HashMap::new(),
            bars,
            tab_bars,
            show_bar: true,
            last_layout: None,
            monitors,
            selected_monitor: 0,
            atoms,
            previous_focused: None,
            display,
            font,
            keychord_state: keyboard::handlers::KeychordState::Idle,
            current_key: 0,
            keyboard_mapping: None,
            error_message: None,
            overlay,
            keybind_overlay,
        };

        for tab_bar in &window_manager.tab_bars {
            tab_bar.hide(&window_manager.connection)?;
        }

        window_manager.scan_existing_windows()?;
        window_manager.update_bar()?;
        window_manager.run_autostart_commands();

        Ok(window_manager)
    }

    pub fn show_migration_overlay(&mut self) {
        let message = "We are on version 0.8.0 now.\n\n\
                       Your config file has been deprecated once again.\n\
                       Backup your current config, and run oxwm --init to generate a new one with correct values.\n\n\
                       Please reach out to Tony, or check out the\n\
                       documentation for help with migration.\n\n\
                       We appreciate you testing oxwm!\n\n\
                       Press Mod+Shift+/ to see keybinds\n\
                       Press Mod+Shift+R to reload after fixing your config";

        let monitor = &self.monitors[self.selected_monitor];
        let monitor_x = monitor.screen_x as i16;
        let monitor_y = monitor.screen_y as i16;
        let screen_width = monitor.screen_width as u16;
        let screen_height = monitor.screen_height as u16;

        if let Err(e) = self.overlay.show_error(
            &self.connection,
            &self.font,
            message,
            monitor_x,
            monitor_y,
            screen_width,
            screen_height,
        ) {
            eprintln!("Failed to show migration overlay: {:?}", e);
        }
    }

    fn try_reload_config(&mut self) -> Result<(), String> {
        let config_dir = if let Some(xdg_config) = std::env::var_os("XDG_CONFIG_HOME") {
            std::path::PathBuf::from(xdg_config).join("oxwm")
        } else if let Some(home) = std::env::var_os("HOME") {
            std::path::PathBuf::from(home).join(".config").join("oxwm")
        } else {
            return Err("Could not find config directory".to_string());
        };

        let lua_path = config_dir.join("config.lua");

        if !lua_path.exists() {
            return Err("No config.lua file found".to_string());
        }

        let config_str = std::fs::read_to_string(&lua_path)
            .map_err(|e| format!("Failed to read config: {}", e))?;

        let new_config = crate::config::parse_lua_config(&config_str, Some(&config_dir))
            .map_err(|e| format!("{}", e))?;

        self.config = new_config;
        self.error_message = None;

        for bar in &mut self.bars {
            bar.update_from_config(&self.config);
        }

        Ok(())
    }

    fn scan_existing_windows(&mut self) -> WmResult<()> {
        let tree = self.connection.query_tree(self.root)?.reply()?;
        let net_client_info = self.atoms.net_client_info;
        let wm_state_atom = self.atoms.wm_state;

        for &window in &tree.children {
            if self.bars.iter().any(|bar| bar.window() == window) {
                continue;
            }

            let Ok(attrs) = self.connection.get_window_attributes(window)?.reply() else {
                continue;
            };

            if attrs.override_redirect {
                continue;
            }

            if attrs.map_state == MapState::VIEWABLE {
                let _tag = self.get_saved_tag(window, net_client_info)?;
                self.windows.push(window);
                continue;
            }

            if attrs.map_state == MapState::UNMAPPED {
                let has_wm_state = self
                    .connection
                    .get_property(false, window, wm_state_atom, AtomEnum::ANY, 0, 2)?
                    .reply()
                    .is_ok_and(|prop| !prop.value.is_empty());

                if !has_wm_state {
                    continue;
                }

                let has_wm_class = self
                    .connection
                    .get_property(false, window, AtomEnum::WM_CLASS, AtomEnum::STRING, 0, 1024)?
                    .reply()
                    .is_ok_and(|prop| !prop.value.is_empty());

                if has_wm_class {
                    let _tag = self.get_saved_tag(window, net_client_info)?;
                    self.connection.map_window(window)?;
                    self.windows.push(window);
                }
            }
        }

        if let Some(&first) = self.windows.first() {
            self.focus(Some(first))?;
        }

        self.apply_layout()?;
        Ok(())
    }

    fn get_saved_tag(&self, window: Window, net_client_info: Atom) -> WmResult<TagMask> {
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

                if tags != 0 && tags < (1 << self.config.tags.len()) {
                    return Ok(tags);
                }
            }
            Ok(_) => {}
            Err(e) => {
                eprintln!("No _NET_CLIENT_INFO property ({})", e);
            }
        }

        Ok(self
            .monitors
            .get(self.selected_monitor)
            .map(|m| m.tagset[m.selected_tags_index])
            .unwrap_or(tag_mask(0)))
    }

    fn save_client_tag(&self, window: Window, tag: TagMask) -> WmResult<()> {
        let net_client_info = self.atoms.net_client_info;

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

    fn set_wm_state(&self, window: Window, state: u32) -> WmResult<()> {
        let wm_state_atom = self.atoms.wm_state;

        let data = [state, 0u32];
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

    pub fn run(&mut self) -> WmResult<bool> {
        println!("oxwm started on display {}", self.screen_number);

        self.grab_keys()?;
        self.update_bar()?;

        let mut last_bar_update = std::time::Instant::now();
        const BAR_UPDATE_INTERVAL_MS: u64 = 100;

        loop {
            match self.connection.poll_for_event_with_sequence()? {
                Some((event, _sequence)) => {
                    if let Some(should_restart) = self.handle_event(event)? {
                        return Ok(should_restart);
                    }
                }
                None => {
                    if last_bar_update.elapsed().as_millis() >= BAR_UPDATE_INTERVAL_MS as u128 {
                        if let Some(bar) = self.bars.get_mut(self.selected_monitor) {
                            bar.update_blocks();
                        }
                        if self.bars.iter().any(|bar| bar.needs_redraw()) {
                            self.update_bar()?;
                        }
                        last_bar_update = std::time::Instant::now();
                    }

                    self.connection.flush()?;
                    std::thread::sleep(std::time::Duration::from_millis(16));
                }
            }
        }
    }

    fn toggle_floating(&mut self) -> WmResult<()> {
        let focused = self
            .monitors
            .get(self.selected_monitor)
            .and_then(|m| m.selected_client);

        if focused.is_none() {
            return Ok(());
        }
        let focused = focused.unwrap();

        if let Some(client) = self.clients.get(&focused) {
            if client.is_fullscreen {
                return Ok(());
            }
        }

        let (is_fixed, x, y, w, h) = if let Some(client) = self.clients.get(&focused) {
            (
                client.is_fixed,
                client.x_position as i32,
                client.y_position as i32,
                client.width as u32,
                client.height as u32,
            )
        } else {
            return Ok(());
        };

        let was_floating = self.floating_windows.contains(&focused);

        if was_floating {
            self.floating_windows.remove(&focused);
            if let Some(client) = self.clients.get_mut(&focused) {
                client.is_floating = false;
            }
        } else {
            self.floating_windows.insert(focused);
            if let Some(client) = self.clients.get_mut(&focused) {
                client.is_floating = is_fixed || !client.is_floating;
            }

            self.connection.configure_window(
                focused,
                &ConfigureWindowAux::new()
                    .x(x)
                    .y(y)
                    .width(w)
                    .height(h)
                    .stack_mode(StackMode::ABOVE),
            )?;
        }

        self.apply_layout()?;
        Ok(())
    }

    fn set_master_factor(&mut self, delta: f32) -> WmResult<()> {
        if let Some(monitor) = self.monitors.get_mut(self.selected_monitor) {
            let new_mfact = (monitor.master_factor + delta).max(0.05).min(0.95);
            monitor.master_factor = new_mfact;
            self.apply_layout()?;
        }
        Ok(())
    }

    fn inc_num_master(&mut self, delta: i32) -> WmResult<()> {
        if let Some(monitor) = self.monitors.get_mut(self.selected_monitor) {
            let new_nmaster = (monitor.num_master + delta).max(0);
            monitor.num_master = new_nmaster;
            self.apply_layout()?;
        }
        Ok(())
    }

    fn get_layout_symbol(&self) -> String {
        let layout_name = self.layout.name();
        self.config
            .layout_symbols
            .iter()
            .find(|l| l.name == layout_name)
            .map(|l| l.symbol.clone())
            .unwrap_or_else(|| self.layout.symbol().to_string())
    }

    fn get_keychord_indicator(&self) -> Option<String> {
        match &self.keychord_state {
            keyboard::handlers::KeychordState::Idle => None,
            keyboard::handlers::KeychordState::InProgress {
                candidates,
                keys_pressed,
            } => {
                if candidates.is_empty() {
                    return None;
                }

                let binding = &self.config.keybindings[candidates[0]];
                let mut indicator = String::new();

                for (i, key_press) in binding.keys.iter().take(*keys_pressed).enumerate() {
                    if i > 0 {
                        indicator.push(' ');
                    }

                    for modifier in &key_press.modifiers {
                        indicator.push_str(Self::format_modifier(*modifier));
                        indicator.push('+');
                    }

                    indicator.push_str(&keyboard::keysyms::format_keysym(key_press.keysym));
                }

                indicator.push('-');
                Some(indicator)
            }
        }
    }

    fn format_modifier(modifier: KeyButMask) -> &'static str {
        match modifier {
            KeyButMask::MOD1 => "Alt",
            KeyButMask::MOD4 => "Super",
            KeyButMask::SHIFT => "Shift",
            KeyButMask::CONTROL => "Ctrl",
            _ => "Mod",
        }
    }

    fn update_bar(&mut self) -> WmResult<()> {
        let layout_symbol = self.get_layout_symbol();
        let keychord_indicator = self.get_keychord_indicator();

        for (monitor_index, monitor) in self.monitors.iter().enumerate() {
            if let Some(bar) = self.bars.get_mut(monitor_index) {
                let mut occupied_tags: TagMask = 0;
                for client in self.clients.values() {
                    if client.monitor_index == monitor_index {
                        occupied_tags |= client.tags;
                    }
                }

                let draw_blocks = monitor_index == self.selected_monitor;
                bar.invalidate();
                bar.draw(
                    &self.connection,
                    &self.font,
                    self.display,
                    monitor.tagset[monitor.selected_tags_index],
                    occupied_tags,
                    draw_blocks,
                    &layout_symbol,
                    keychord_indicator.as_deref(),
                )?;
            }
        }
        Ok(())
    }

    fn update_tab_bars(&mut self) -> WmResult<()> {
        for (monitor_index, monitor) in self.monitors.iter().enumerate() {
            if let Some(tab_bar) = self.tab_bars.get_mut(monitor_index) {
                let visible_windows: Vec<(Window, String)> = self
                    .windows
                    .iter()
                    .filter_map(|&window| {
                        if let Some(client) = self.clients.get(&window) {
                            if client.monitor_index != monitor_index
                                || self.floating_windows.contains(&window)
                                || self.fullscreen_windows.contains(&window)
                            {
                                return None;
                            }
                            if (client.tags & monitor.tagset[monitor.selected_tags_index]) != 0 {
                                return Some((window, client.name.clone()));
                            }
                        }
                        None
                    })
                    .collect();

                let focused_window = monitor.selected_client;

                tab_bar.draw(
                    &self.connection,
                    &self.font,
                    &visible_windows,
                    focused_window,
                )?;
            }
        }
        Ok(())
    }

    fn handle_key_action(&mut self, action: KeyAction, arg: &Arg) -> WmResult<()> {
        match action {
            KeyAction::Spawn => handlers::handle_spawn_action(action, arg, self.selected_monitor)?,
            KeyAction::SpawnTerminal => {
                crate::signal::spawn_detached(&self.config.terminal);
            }
            KeyAction::KillClient => {
                if let Some(focused) = self
                    .monitors
                    .get(self.selected_monitor)
                    .and_then(|m| m.selected_client)
                {
                    self.kill_client(focused)?;
                }
            }
            KeyAction::ToggleFullScreen => {
                // Disable gaps and save previous state in config if not already in fullscreen
                if self.fullscreen_windows.is_empty() {
                    self.config.gaps_enabled = std::mem::take(&mut self.gaps_enabled);
                } else {
                    self.gaps_enabled = self.config.gaps_enabled;
                }

                self.fullscreen()?;
                self.restack()?;
            }
            KeyAction::ChangeLayout => {
                if let Arg::Str(layout_name) = arg {
                    match layout_from_str(layout_name) {
                        Ok(layout) => {
                            self.layout = layout;
                            if layout_name != "normie" && layout_name != "floating" {
                                self.floating_windows.clear();
                            }
                            self.apply_layout()?;
                            self.update_bar()?;
                            self.restack()?;
                        }
                        Err(e) => eprintln!("Failed to change layout: {}", e),
                    }
                }
            }
            KeyAction::CycleLayout => {
                let current_name = self.layout.name();
                let next_name = next_layout(current_name);
                match layout_from_str(next_name) {
                    Ok(layout) => {
                        self.layout = layout;
                        if next_name != "normie" && next_name != "floating" {
                            self.floating_windows.clear();
                        }
                        self.apply_layout()?;
                        self.update_bar()?;
                        self.restack()?;
                    }
                    Err(e) => eprintln!("Failed to cycle layout: {}", e),
                }
            }
            KeyAction::ToggleFloating => {
                self.toggle_floating()?;
                self.restack()?;
            }

            KeyAction::FocusStack => {
                if let Arg::Int(direction) = arg {
                    self.focusstack(*direction)?;
                }
            }
            KeyAction::MoveStack => {
                if let Arg::Int(direction) = arg {
                    self.move_stack(*direction)?;
                }
            }
            KeyAction::Quit | KeyAction::Restart => {
                // Handled in handle_event
            }
            KeyAction::ViewTag => {
                if let Arg::Int(tag_index) = arg {
                    self.view_tag(*tag_index as usize)?;
                }
            }
            KeyAction::ViewNextTag => {
                let monitor = self.get_selected_monitor();
                let current_tag_mask = monitor.get_selected_tag();

                let current_tag_index = unmask_tag(current_tag_mask);
                self.view_tag(current_tag_index.saturating_add(1))?;
            }
            KeyAction::ViewPreviousTag => {
                let monitor = self.get_selected_monitor();
                let current_tag_mask = monitor.get_selected_tag();

                let current_tag_index = unmask_tag(current_tag_mask);
                self.view_tag(current_tag_index.saturating_sub(1))?;
            }
            KeyAction::ToggleView => {
                if let Arg::Int(tag_index) = arg {
                    self.toggleview(*tag_index as usize)?;
                }
            }
            KeyAction::MoveToTag => {
                if let Arg::Int(tag_index) = arg {
                    self.move_to_tag(*tag_index as usize)?;
                }
            }
            KeyAction::ToggleTag => {
                if let Arg::Int(tag_index) = arg {
                    self.toggletag(*tag_index as usize)?;
                }
            }
            KeyAction::ToggleGaps => {
                self.gaps_enabled = !self.gaps_enabled;
                self.apply_layout()?;
                self.restack()?;
            }
            KeyAction::FocusMonitor => {
                if let Arg::Int(direction) = arg {
                    self.focus_monitor(*direction)?;
                }
            }
            KeyAction::TagMonitor => {
                if let Arg::Int(direction) = arg {
                    self.send_window_to_adjacent_monitor(*direction)?;
                }
            }
            KeyAction::ShowKeybindOverlay => {
                let monitor = &self.monitors[self.selected_monitor];
                self.keybind_overlay.toggle(
                    &self.connection,
                    &self.font,
                    &self.config.keybindings,
                    monitor.screen_x as i16,
                    monitor.screen_y as i16,
                    monitor.screen_width as u16,
                    monitor.screen_height as u16,
                )?;
            }
            KeyAction::SetMasterFactor => {
                if let Arg::Int(delta) = arg {
                    self.set_master_factor(*delta as f32 / 100.0)?;
                }
            }
            KeyAction::IncNumMaster => {
                if let Arg::Int(delta) = arg {
                    self.inc_num_master(*delta)?;
                }
            }
            KeyAction::None => {}
        }
        Ok(())
    }

    fn is_window_visible(&self, window: Window) -> bool {
        if let Some(client) = self.clients.get(&window) {
            let monitor = self.monitors.get(client.monitor_index);
            let selected_tags = monitor
                .map(|m| m.tagset[m.selected_tags_index])
                .unwrap_or(0);
            (client.tags & selected_tags) != 0
        } else {
            false
        }
    }

    fn visible_windows(&self) -> Vec<Window> {
        let mut result = Vec::new();
        for monitor in &self.monitors {
            let mut current = monitor.clients_head;
            while let Some(window) = current {
                if let Some(client) = self.clients.get(&window) {
                    let visible_tags = client.tags & monitor.tagset[monitor.selected_tags_index];
                    if visible_tags != 0 {
                        result.push(window);
                    }
                    current = client.next;
                } else {
                    break;
                }
            }
        }
        result
    }

    fn visible_windows_on_monitor(&self, monitor_index: usize) -> Vec<Window> {
        let mut result = Vec::new();
        if let Some(monitor) = self.monitors.get(monitor_index) {
            let mut current = monitor.clients_head;
            while let Some(window) = current {
                if let Some(client) = self.clients.get(&window) {
                    let visible_tags = client.tags & monitor.tagset[monitor.selected_tags_index];
                    if visible_tags != 0 {
                        result.push(window);
                    }
                    current = client.next;
                } else {
                    break;
                }
            }
        }
        result
    }

    fn get_monitor_at_point(&self, x: i32, y: i32) -> Option<usize> {
        self.monitors
            .iter()
            .position(|mon| mon.contains_point(x, y))
    }

    fn get_monitor_for_rect(&self, x: i32, y: i32, w: i32, h: i32) -> usize {
        let mut best_monitor = self.selected_monitor;
        let mut max_area = 0;

        for (idx, monitor) in self.monitors.iter().enumerate() {
            let intersect_width = 0.max(
                (x + w).min(monitor.window_area_x + monitor.window_area_width)
                    - x.max(monitor.window_area_x),
            );
            let intersect_height = 0.max(
                (y + h).min(monitor.window_area_y + monitor.window_area_height)
                    - y.max(monitor.window_area_y),
            );
            let area = intersect_width * intersect_height;

            if area > max_area {
                max_area = area;
                best_monitor = idx;
            }
        }

        best_monitor
    }

    fn move_window_to_monitor(
        &mut self,
        window: Window,
        target_monitor_index: usize,
    ) -> WmResult<()> {
        let current_monitor_index = self.clients.get(&window).map(|c| c.monitor_index);

        if let Some(current_idx) = current_monitor_index {
            if current_idx == target_monitor_index {
                return Ok(());
            }
        }

        self.unfocus(window)?;
        self.detach(window);
        self.detach_stack(window);

        if let Some(client) = self.clients.get_mut(&window) {
            client.monitor_index = target_monitor_index;
            if let Some(target_monitor) = self.monitors.get(target_monitor_index) {
                client.tags = target_monitor.tagset[target_monitor.selected_tags_index];
            }
        }

        self.attach_aside(window, target_monitor_index);
        self.attach_stack(window, target_monitor_index);

        self.focus(None)?;
        self.apply_layout()?;

        Ok(())
    }

    fn get_adjacent_monitor(&self, direction: i32) -> Option<usize> {
        if self.monitors.len() <= 1 {
            return None;
        }

        if direction > 0 {
            if self.selected_monitor + 1 < self.monitors.len() {
                Some(self.selected_monitor + 1)
            } else {
                Some(0)
            }
        } else {
            if self.selected_monitor == 0 {
                Some(self.monitors.len() - 1)
            } else {
                Some(self.selected_monitor - 1)
            }
        }
    }

    fn is_visible(&self, window: Window) -> bool {
        let Some(client) = self.clients.get(&window) else {
            return false;
        };

        let Some(monitor) = self.monitors.get(client.monitor_index) else {
            return false;
        };

        (client.tags & monitor.tagset[monitor.selected_tags_index]) != 0
    }

    fn showhide(&mut self, window: Option<Window>) -> WmResult<()> {
        let Some(window) = window else {
            return Ok(());
        };

        let Some(client) = self.clients.get(&window).cloned() else {
            return Ok(());
        };

        let monitor = match self.monitors.get(client.monitor_index) {
            Some(m) => m,
            None => return Ok(()),
        };

        let is_visible = (client.tags & monitor.tagset[monitor.selected_tags_index]) != 0;

        if is_visible {
            self.connection.configure_window(
                window,
                &ConfigureWindowAux::new()
                    .x(client.x_position as i32)
                    .y(client.y_position as i32),
            )?;

            let is_floating = client.is_floating;
            let is_fullscreen = client.is_fullscreen;
            let has_no_layout = self.layout.name() == LayoutType::Normie.as_str();

            if (has_no_layout || is_floating) && !is_fullscreen {
                let (x, y, w, h, changed) = self.apply_size_hints(
                    window,
                    client.x_position as i32,
                    client.y_position as i32,
                    client.width as i32,
                    client.height as i32,
                );
                if changed {
                    if let Some(c) = self.clients.get_mut(&window) {
                        c.old_x_position = c.x_position;
                        c.old_y_position = c.y_position;
                        c.old_width = c.width;
                        c.old_height = c.height;
                        c.x_position = x as i16;
                        c.y_position = y as i16;
                        c.width = w as u16;
                        c.height = h as u16;
                    }
                    self.connection.configure_window(
                        window,
                        &ConfigureWindowAux::new()
                            .x(x)
                            .y(y)
                            .width(w as u32)
                            .height(h as u32)
                            .border_width(self.config.border_width),
                    )?;
                    self.send_configure_notify(window)?;
                    self.connection.flush()?;
                }
            }

            self.showhide(client.stack_next)?;
        } else {
            self.showhide(client.stack_next)?;

            let width = client.width_with_border() as i32;
            self.connection.configure_window(
                window,
                &ConfigureWindowAux::new()
                    .x(width * -2)
                    .y(client.y_position as i32),
            )?;
        }

        Ok(())
    }

    pub fn view_tag(&mut self, tag_index: usize) -> WmResult<()> {
        if tag_index >= self.config.tags.len() {
            return Ok(());
        }

        let monitor = match self.monitors.get_mut(self.selected_monitor) {
            Some(m) => m,
            None => return Ok(()),
        };

        let new_tagset = tag_mask(tag_index);

        if new_tagset == monitor.tagset[monitor.selected_tags_index] {
            return Ok(());
        }

        monitor.selected_tags_index ^= 1;
        monitor.tagset[monitor.selected_tags_index] = new_tagset;

        self.save_selected_tags()?;
        self.focus(None)?;
        self.apply_layout()?;
        self.update_bar()?;

        Ok(())
    }

    pub fn toggleview(&mut self, tag_index: usize) -> WmResult<()> {
        if tag_index >= self.config.tags.len() {
            return Ok(());
        }

        let monitor = match self.monitors.get_mut(self.selected_monitor) {
            Some(m) => m,
            None => return Ok(()),
        };

        let mask = tag_mask(tag_index);
        let new_tagset = monitor.tagset[monitor.selected_tags_index] ^ mask;

        if new_tagset == 0 {
            return Ok(());
        }

        monitor.tagset[monitor.selected_tags_index] = new_tagset;

        self.save_selected_tags()?;
        self.focus(None)?;
        self.apply_layout()?;
        self.update_bar()?;

        Ok(())
    }

    fn save_selected_tags(&self) -> WmResult<()> {
        let net_current_desktop = self.atoms.net_current_desktop;

        let selected_tags = self
            .monitors
            .get(self.selected_monitor)
            .map(|m| m.tagset[m.selected_tags_index])
            .unwrap_or(tag_mask(0));
        let desktop = selected_tags.trailing_zeros();

        let bytes = (desktop as u32).to_ne_bytes();
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

    pub fn move_to_tag(&mut self, tag_index: usize) -> WmResult<()> {
        if tag_index >= self.config.tags.len() {
            return Ok(());
        }

        let focused = match self
            .monitors
            .get(self.selected_monitor)
            .and_then(|m| m.selected_client)
        {
            Some(win) => win,
            None => return Ok(()),
        };

        let mask = tag_mask(tag_index);

        if let Some(client) = self.clients.get_mut(&focused) {
            client.tags = mask;
        }

        if let Err(error) = self.save_client_tag(focused, mask) {
            eprintln!("Failed to save client tag: {:?}", error);
        }

        self.focus(None)?;
        self.apply_layout()?;
        self.update_bar()?;

        Ok(())
    }

    pub fn toggletag(&mut self, tag_index: usize) -> WmResult<()> {
        if tag_index >= self.config.tags.len() {
            return Ok(());
        }

        let focused = match self
            .monitors
            .get(self.selected_monitor)
            .and_then(|m| m.selected_client)
        {
            Some(win) => win,
            None => return Ok(()),
        };

        let mask = tag_mask(tag_index);
        let current_tags = self.clients.get(&focused).map(|c| c.tags).unwrap_or(0);
        let new_tags = current_tags ^ mask;

        if new_tags == 0 {
            return Ok(());
        }

        if let Some(client) = self.clients.get_mut(&focused) {
            client.tags = new_tags;
        }

        if let Err(error) = self.save_client_tag(focused, new_tags) {
            eprintln!("Failed to save client tag: {:?}", error);
        }

        self.focus(None)?;
        self.apply_layout()?;
        self.update_bar()?;

        Ok(())
    }

    pub fn cycle_focus(&mut self, direction: i32) -> WmResult<()> {
        let visible = self.visible_windows();

        if visible.is_empty() {
            return Ok(());
        }

        let current = self
            .monitors
            .get(self.selected_monitor)
            .and_then(|m| m.selected_client);

        let next_window = if let Some(current) = current {
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

        let is_tabbed = self.layout.name() == "tabbed";
        if is_tabbed {
            self.connection.configure_window(
                next_window,
                &ConfigureWindowAux::new().stack_mode(StackMode::ABOVE),
            )?;
        }

        self.focus(Some(next_window))?;

        if is_tabbed {
            self.update_tab_bars()?;
        }

        Ok(())
    }

    fn grab_keys(&mut self) -> WmResult<()> {
        self.keyboard_mapping = Some(keyboard::grab_keys(
            &self.connection,
            self.root,
            &self.config.keybindings,
            self.current_key,
        )?);
        Ok(())
    }

    fn kill_client(&self, window: Window) -> WmResult<()> {
        if self.send_event(window, self.atoms.wm_delete_window)? {
            self.connection.flush()?;
        } else {
            eprintln!(
                "Window {} doesn't support WM_DELETE_WINDOW, killing forcefully",
                window
            );
            self.connection.kill_client(window)?;
            self.connection.flush()?;
        }
        Ok(())
    }

    fn send_event(&self, window: Window, protocol: Atom) -> WmResult<bool> {
        let protocols_reply = self
            .connection
            .get_property(
                false,
                window,
                self.atoms.wm_protocols,
                AtomEnum::ATOM,
                0,
                100,
            )?
            .reply();

        let protocols_reply = match protocols_reply {
            Ok(reply) => reply,
            Err(_) => return Ok(false),
        };

        let protocols: Vec<Atom> = protocols_reply
            .value
            .chunks_exact(4)
            .map(|chunk| u32::from_ne_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]))
            .collect();

        if !protocols.contains(&protocol) {
            return Ok(false);
        }

        let event = x11rb::protocol::xproto::ClientMessageEvent {
            response_type: x11rb::protocol::xproto::CLIENT_MESSAGE_EVENT,
            format: 32,
            sequence: 0,
            window,
            type_: self.atoms.wm_protocols,
            data: x11rb::protocol::xproto::ClientMessageData::from([
                protocol,
                x11rb::CURRENT_TIME,
                0,
                0,
                0,
            ]),
        };

        self.connection
            .send_event(false, window, EventMask::NO_EVENT, event)?;
        self.connection.flush()?;
        Ok(true)
    }

    fn set_urgent(&mut self, window: Window, urgent: bool) -> WmResult<()> {
        if let Some(client) = self.clients.get_mut(&window) {
            client.is_urgent = urgent;
        }

        let hints_reply = self
            .connection
            .get_property(false, window, AtomEnum::WM_HINTS, AtomEnum::WM_HINTS, 0, 9)?
            .reply();

        if let Ok(hints) = hints_reply {
            if hints.value.len() >= 4 {
                let mut flags = u32::from_ne_bytes([
                    hints.value[0],
                    hints.value[1],
                    hints.value[2],
                    hints.value[3],
                ]);

                if urgent {
                    flags |= 256;
                } else {
                    flags &= !256;
                }

                let mut new_hints = hints.value.clone();
                new_hints[0..4].copy_from_slice(&flags.to_ne_bytes());

                self.connection.change_property(
                    PropMode::REPLACE,
                    window,
                    AtomEnum::WM_HINTS,
                    AtomEnum::WM_HINTS,
                    32,
                    new_hints.len() as u32 / 4,
                    &new_hints,
                )?;
            }
        }

        Ok(())
    }

    fn get_window_atom_property(&self, window: Window, property: Atom) -> WmResult<Option<Atom>> {
        let reply = self
            .connection
            .get_property(false, window, property, AtomEnum::ATOM, 0, 1)?
            .reply();

        match reply {
            Ok(prop) if !prop.value.is_empty() && prop.value.len() >= 4 => {
                let atom = u32::from_ne_bytes([
                    prop.value[0],
                    prop.value[1],
                    prop.value[2],
                    prop.value[3],
                ]);
                Ok(Some(atom))
            }
            _ => Ok(None),
        }
    }

    fn fullscreen(&mut self) -> WmResult<()> {
        if self.show_bar {
            let Some(focused_window) = self
                .monitors
                .get(self.selected_monitor)
                .and_then(|m| m.selected_client)
            else {
                return Ok(());
            };

            self.fullscreen_windows.insert(focused_window);

            let windows: Vec<Window> = self
                .windows
                .iter()
                .filter(|&&w| self.is_window_visible(w))
                .copied()
                .collect();

            for window in &windows {
                if let Ok(geom) = self.connection.get_geometry(*window)?.reply() {
                    self.floating_geometry_before_fullscreen.insert(
                        *window,
                        (
                            geom.x,
                            geom.y,
                            geom.width,
                            geom.height,
                            geom.border_width as u16,
                        ),
                    );
                }
            }

            self.last_layout = Some(self.layout.name());
            if let Ok(layout) = layout_from_str("monocle") {
                self.layout = layout;
            }
            self.toggle_bar()?;
            self.apply_layout()?;

            for window in &windows {
                self.connection.configure_window(
                    *window,
                    &x11rb::protocol::xproto::ConfigureWindowAux::new().border_width(0),
                )?;
            }

            let border_width = self.config.border_width;
            let floating_windows: Vec<Window> = windows
                .iter()
                .filter(|&&w| self.floating_windows.contains(&w))
                .copied()
                .collect();

            for window in floating_windows {
                let monitor_idx = self
                    .clients
                    .get(&window)
                    .map(|c| c.monitor_index)
                    .unwrap_or(self.selected_monitor);
                let monitor = &self.monitors[monitor_idx];

                let (outer_gap_h, outer_gap_v) = if self.gaps_enabled {
                    (
                        self.config.gap_outer_horizontal,
                        self.config.gap_outer_vertical,
                    )
                } else {
                    (0, 0)
                };

                let window_x = monitor.screen_x + outer_gap_h as i32;
                let window_y = monitor.screen_y + outer_gap_v as i32;
                let window_width = monitor
                    .screen_width
                    .saturating_sub(2 * outer_gap_h as i32)
                    .saturating_sub(2 * border_width as i32);
                let window_height = monitor
                    .screen_height
                    .saturating_sub(2 * outer_gap_v as i32)
                    .saturating_sub(2 * border_width as i32);

                self.connection.configure_window(
                    window,
                    &x11rb::protocol::xproto::ConfigureWindowAux::new()
                        .x(window_x)
                        .y(window_y)
                        .width(window_width as u32)
                        .height(window_height as u32),
                )?;
            }
            self.connection.flush()?;
        } else {
            let Some(focused_window) = self
                .monitors
                .get(self.selected_monitor)
                .and_then(|m| m.selected_client)
            else {
                return Ok(());
            };

            self.fullscreen_windows.remove(&focused_window);

            if let Some(last) = self.last_layout {
                if let Ok(layout) = layout_from_str(last) {
                    self.layout = layout;
                }
            }

            let windows_to_restore: Vec<Window> = self
                .floating_geometry_before_fullscreen
                .keys()
                .copied()
                .collect();

            for window in windows_to_restore {
                if let Some(&(x, y, width, height, border_width)) =
                    self.floating_geometry_before_fullscreen.get(&window)
                {
                    self.connection.configure_window(
                        window,
                        &ConfigureWindowAux::new()
                            .x(x as i32)
                            .y(y as i32)
                            .width(width as u32)
                            .height(height as u32)
                            .border_width(border_width as u32),
                    )?;

                    if let Some(c) = self.clients.get_mut(&window) {
                        c.x_position = x;
                        c.y_position = y;
                        c.width = width;
                        c.height = height;
                        c.border_width = border_width;
                    }

                    self.floating_geometry_before_fullscreen.remove(&window);
                }
            }
            self.connection.flush()?;

            self.toggle_bar()?;

            if self.layout.name() != "normie" {
                self.apply_layout()?;
            } else {
                if let Some(bar) = self.bars.get(self.selected_monitor) {
                    self.connection.configure_window(
                        bar.window(),
                        &x11rb::protocol::xproto::ConfigureWindowAux::new()
                            .stack_mode(x11rb::protocol::xproto::StackMode::ABOVE),
                    )?;
                    self.connection.flush()?;
                }
            }
        }
        Ok(())
    }

    fn set_window_fullscreen(&mut self, window: Window, fullscreen: bool) -> WmResult<()> {
        let monitor_idx = self
            .clients
            .get(&window)
            .map(|c| c.monitor_index)
            .unwrap_or(self.selected_monitor);
        let monitor = &self.monitors[monitor_idx];

        if fullscreen && !self.fullscreen_windows.contains(&window) {
            let bytes = self.atoms.net_wm_state_fullscreen.to_ne_bytes().to_vec();
            self.connection.change_property(
                PropMode::REPLACE,
                window,
                self.atoms.net_wm_state,
                AtomEnum::ATOM,
                32,
                1,
                &bytes,
            )?;

            if let Some(client) = self.clients.get_mut(&window) {
                client.is_fullscreen = true;
                client.old_state = client.is_floating;
                client.old_border_width = client.border_width;
                client.border_width = 0;
                client.is_floating = true;
            }

            self.fullscreen_windows.insert(window);

            self.connection.configure_window(
                window,
                &x11rb::protocol::xproto::ConfigureWindowAux::new()
                    .border_width(0)
                    .x(monitor.screen_x)
                    .y(monitor.screen_y)
                    .width(monitor.screen_width as u32)
                    .height(monitor.screen_height as u32)
                    .stack_mode(x11rb::protocol::xproto::StackMode::ABOVE),
            )?;

            self.connection.flush()?;
        } else if !fullscreen && self.fullscreen_windows.contains(&window) {
            self.connection.change_property(
                PropMode::REPLACE,
                window,
                self.atoms.net_wm_state,
                AtomEnum::ATOM,
                32,
                0,
                &[],
            )?;

            self.fullscreen_windows.remove(&window);

            if let Some(client) = self.clients.get_mut(&window) {
                client.is_fullscreen = false;
                client.is_floating = client.old_state;
                client.border_width = client.old_border_width;

                let x = client.old_x_position;
                let y = client.old_y_position;
                let w = client.old_width;
                let h = client.old_height;
                let bw = client.border_width;

                self.connection.configure_window(
                    window,
                    &x11rb::protocol::xproto::ConfigureWindowAux::new()
                        .x(x as i32)
                        .y(y as i32)
                        .width(w as u32)
                        .height(h as u32)
                        .border_width(bw as u32),
                )?;
            }

            self.apply_layout()?;
        }

        Ok(())
    }

    fn toggle_bar(&mut self) -> WmResult<()> {
        self.show_bar = !self.show_bar;
        if let Some(bar) = self.bars.get(self.selected_monitor) {
            if self.show_bar {
                self.connection.map_window(bar.window())?;
            } else {
                self.connection.unmap_window(bar.window())?;
            }
            self.connection.flush()?;
        }
        self.apply_layout()?;
        Ok(())
    }

    fn get_transient_parent(&self, window: Window) -> Option<Window> {
        self.connection
            .get_property(
                false,
                window,
                AtomEnum::WM_TRANSIENT_FOR,
                AtomEnum::WINDOW,
                0,
                1,
            )
            .ok()
            .and_then(|cookie| cookie.reply().ok())
            .filter(|reply| !reply.value.is_empty())
            .and_then(|reply| {
                if reply.value.len() >= 4 {
                    let parent_window = u32::from_ne_bytes([
                        reply.value[0],
                        reply.value[1],
                        reply.value[2],
                        reply.value[3],
                    ]);
                    Some(parent_window)
                } else {
                    None
                }
            })
    }

    fn get_window_class_instance(&self, window: Window) -> (String, String) {
        let reply = self
            .connection
            .get_property(false, window, AtomEnum::WM_CLASS, AtomEnum::STRING, 0, 1024)
            .ok()
            .and_then(|cookie| cookie.reply().ok());

        if let Some(reply) = reply {
            if !reply.value.is_empty() {
                if let Ok(text) = std::str::from_utf8(&reply.value) {
                    let parts: Vec<&str> = text.split('\0').collect();
                    let instance = parts.get(0).unwrap_or(&"").to_string();
                    let class = parts.get(1).unwrap_or(&"").to_string();
                    return (instance, class);
                }
            }
        }

        (String::new(), String::new())
    }

    fn apply_rules(&mut self, window: Window) -> WmResult<()> {
        let (instance, class) = self.get_window_class_instance(window);
        let title = self
            .clients
            .get(&window)
            .map(|c| c.name.clone())
            .unwrap_or_default();

        let mut rule_tags: Option<u32> = None;
        let mut rule_floating: Option<bool> = None;
        let mut rule_monitor: Option<usize> = None;

        for rule in &self.config.window_rules {
            if rule.matches(&class, &instance, &title) {
                if rule.tags.is_some() {
                    rule_tags = rule.tags;
                }
                if rule.is_floating.is_some() {
                    rule_floating = rule.is_floating;
                }
                if rule.monitor.is_some() {
                    rule_monitor = rule.monitor;
                }
            }
        }

        if let Some(client) = self.clients.get_mut(&window) {
            if let Some(is_floating) = rule_floating {
                client.is_floating = is_floating;
                if is_floating {
                    self.floating_windows.insert(window);
                } else {
                    self.floating_windows.remove(&window);
                }
            }

            if let Some(monitor_index) = rule_monitor {
                if monitor_index < self.monitors.len() {
                    client.monitor_index = monitor_index;
                }
            }

            let tags = rule_tags.unwrap_or_else(|| {
                self.monitors
                    .get(client.monitor_index)
                    .map(|m| m.tagset[m.selected_tags_index])
                    .unwrap_or(tag_mask(0))
            });

            client.tags = tags;
        }

        Ok(())
    }

    fn manage_window(&mut self, window: Window) -> WmResult<()> {
        let geometry = self.connection.get_geometry(window)?.reply()?;
        let border_width = self.config.border_width;

        let transient_parent = self.get_transient_parent(window);
        let is_transient = transient_parent.is_some();

        let (monitor_index, tags) = if let Some(parent) = transient_parent {
            if let Some(parent_client) = self.clients.get(&parent) {
                (parent_client.monitor_index, parent_client.tags)
            } else {
                let tags = self
                    .monitors
                    .get(self.selected_monitor)
                    .map(|m| m.tagset[m.selected_tags_index])
                    .unwrap_or(tag_mask(0));
                (self.selected_monitor, tags)
            }
        } else {
            let tags = self
                .monitors
                .get(self.selected_monitor)
                .map(|m| m.tagset[m.selected_tags_index])
                .unwrap_or(tag_mask(0));
            (self.selected_monitor, tags)
        };

        let mut client = Client::new(window, monitor_index, tags);
        client.x_position = geometry.x;
        client.y_position = geometry.y;
        client.width = geometry.width;
        client.height = geometry.height;
        client.old_x_position = geometry.x;
        client.old_y_position = geometry.y;
        client.old_width = geometry.width;
        client.old_height = geometry.height;
        client.old_border_width = geometry.border_width;
        client.border_width = border_width as u16;

        self.clients.insert(window, client);
        self.update_window_title(window)?;

        if !is_transient {
            self.apply_rules(window)?;
        }

        let client_monitor = self
            .clients
            .get(&window)
            .map(|c| c.monitor_index)
            .unwrap_or(monitor_index);
        let monitor = &self.monitors[client_monitor];

        let mut x = self
            .clients
            .get(&window)
            .map(|c| c.x_position as i32)
            .unwrap_or(0);
        let mut y = self
            .clients
            .get(&window)
            .map(|c| c.y_position as i32)
            .unwrap_or(0);
        let w = self
            .clients
            .get(&window)
            .map(|c| c.width as i32)
            .unwrap_or(1);
        let h = self
            .clients
            .get(&window)
            .map(|c| c.height as i32)
            .unwrap_or(1);
        let bw = border_width as i32;

        if x + w + 2 * bw > monitor.window_area_x + monitor.window_area_width {
            x = monitor.window_area_x + monitor.window_area_width - w - 2 * bw;
        }
        if y + h + 2 * bw > monitor.window_area_y + monitor.window_area_height {
            y = monitor.window_area_y + monitor.window_area_height - h - 2 * bw;
        }
        x = x.max(monitor.window_area_x);
        y = y.max(monitor.window_area_y);

        if let Some(c) = self.clients.get_mut(&window) {
            c.x_position = x as i16;
            c.y_position = y as i16;
        }

        self.connection.configure_window(
            window,
            &ConfigureWindowAux::new().border_width(border_width),
        )?;
        self.connection.change_window_attributes(
            window,
            &ChangeWindowAttributesAux::new().border_pixel(self.config.border_unfocused),
        )?;
        self.send_configure_notify(window)?;
        self.update_window_type(window)?;
        self.update_size_hints(window)?;
        self.update_window_hints(window)?;

        self.connection.change_window_attributes(
            window,
            &ChangeWindowAttributesAux::new().event_mask(
                EventMask::ENTER_WINDOW
                    | EventMask::FOCUS_CHANGE
                    | EventMask::PROPERTY_CHANGE
                    | EventMask::STRUCTURE_NOTIFY,
            ),
        )?;

        let is_fixed = self
            .clients
            .get(&window)
            .map(|c| c.is_fixed)
            .unwrap_or(false);
        if let Some(c) = self.clients.get_mut(&window) {
            if !c.is_floating {
                c.is_floating = is_transient || is_fixed;
                c.old_state = c.is_floating;
            }
        }

        if self
            .clients
            .get(&window)
            .map(|c| c.is_floating)
            .unwrap_or(false)
        {
            self.floating_windows.insert(window);
            self.connection.configure_window(
                window,
                &ConfigureWindowAux::new().stack_mode(StackMode::ABOVE),
            )?;
        }

        self.attach_aside(window, client_monitor);
        self.attach_stack(window, client_monitor);
        self.windows.push(window);

        let off_screen_x = x + 2 * self.screen.width_in_pixels as i32;
        self.connection.configure_window(
            window,
            &ConfigureWindowAux::new()
                .x(off_screen_x)
                .y(y)
                .width(w as u32)
                .height(h as u32),
        )?;

        self.set_wm_state(window, 1)?;

        let final_tags = self.clients.get(&window).map(|c| c.tags).unwrap_or(tags);
        let _ = self.save_client_tag(window, final_tags);

        if client_monitor == self.selected_monitor {
            if let Some(old_sel) = self
                .monitors
                .get(self.selected_monitor)
                .and_then(|m| m.selected_client)
            {
                self.unfocus(old_sel)?;
            }
        }

        if let Some(m) = self.monitors.get_mut(client_monitor) {
            m.selected_client = Some(window);
        }

        self.apply_layout()?;
        self.connection.map_window(window)?;
        self.focus(Some(window))?;
        self.update_bar()?;

        if self.layout.name() == "tabbed" {
            self.update_tab_bars()?;
        }

        Ok(())
    }

    pub fn set_focus(&mut self, window: Window) -> WmResult<()> {
        let old_focused = self.previous_focused;

        if let Some(monitor) = self.monitors.get_mut(self.selected_monitor) {
            monitor.selected_client = Some(window);
        }

        self.connection
            .set_input_focus(InputFocus::POINTER_ROOT, window, x11rb::CURRENT_TIME)?;
        self.connection.flush()?;

        self.update_focus_visuals(old_focused, window)?;
        self.previous_focused = Some(window);

        if self.layout.name() == "tabbed" {
            self.update_tab_bars()?;
        }

        Ok(())
    }

    fn unfocus(&self, window: Window) -> WmResult<()> {
        if !self.windows.contains(&window) {
            return Ok(());
        }

        self.connection.change_window_attributes(
            window,
            &ChangeWindowAttributesAux::new().border_pixel(self.config.border_unfocused),
        )?;

        self.connection.grab_button(
            false,
            window,
            EventMask::BUTTON_PRESS.into(),
            GrabMode::SYNC,
            GrabMode::SYNC,
            x11rb::NONE,
            x11rb::NONE,
            ButtonIndex::ANY,
            ModMask::ANY,
        )?;

        Ok(())
    }

    fn focus(&mut self, window: Option<Window>) -> WmResult<()> {
        let monitor = self.monitors.get_mut(self.selected_monitor).unwrap();
        let old_selected = monitor.selected_client;

        if let Some(old_win) = old_selected {
            if old_selected != window {
                self.unfocus(old_win)?;
            }
        }

        let mut win = window;
        if win.is_none() || !self.is_visible(win.unwrap()) {
            let mut current = self
                .monitors
                .get(self.selected_monitor)
                .and_then(|m| m.stack_head);

            while let Some(w) = current {
                if self.is_visible(w) {
                    win = Some(w);
                    break;
                }
                current = self.clients.get(&w).and_then(|c| c.stack_next);
            }
        }

        if let Some(win) = win {
            if !self.windows.contains(&win) {
                return Ok(());
            }

            let monitor_idx = self
                .clients
                .get(&win)
                .map(|c| c.monitor_index)
                .unwrap_or(self.selected_monitor);
            if monitor_idx != self.selected_monitor {
                self.selected_monitor = monitor_idx;
            }

            self.detach_stack(win);
            self.attach_stack(win, monitor_idx);

            self.connection.change_window_attributes(
                win,
                &ChangeWindowAttributesAux::new().border_pixel(self.config.border_focused),
            )?;

            self.connection
                .ungrab_button(ButtonIndex::ANY, win, ModMask::ANY)?;

            self.connection
                .set_input_focus(InputFocus::POINTER_ROOT, win, x11rb::CURRENT_TIME)?;

            if let Some(monitor) = self.monitors.get_mut(self.selected_monitor) {
                monitor.selected_client = Some(win);
            }

            self.previous_focused = Some(win);
        } else {
            self.connection.set_input_focus(
                InputFocus::POINTER_ROOT,
                self.root,
                x11rb::CURRENT_TIME,
            )?;

            if let Some(monitor) = self.monitors.get_mut(self.selected_monitor) {
                monitor.selected_client = None;
            }
        }

        self.connection.flush()?;

        Ok(())
    }

    fn restack(&mut self) -> WmResult<()> {
        let monitor = match self.monitors.get(self.selected_monitor) {
            Some(m) => m,
            None => return Ok(()),
        };

        let mut windows_to_restack: Vec<Window> = Vec::new();

        if let Some(selected) = monitor.selected_client {
            if self.floating_windows.contains(&selected) {
                windows_to_restack.push(selected);
            }
        }

        let mut current = monitor.stack_head;
        while let Some(win) = current {
            if self.windows.contains(&win) && self.floating_windows.contains(&win) {
                if Some(win) != monitor.selected_client {
                    windows_to_restack.push(win);
                }
            }
            current = self.clients.get(&win).and_then(|c| c.stack_next);
        }

        current = monitor.stack_head;
        while let Some(win) = current {
            if self.windows.contains(&win) && !self.floating_windows.contains(&win) {
                windows_to_restack.push(win);
            }
            current = self.clients.get(&win).and_then(|c| c.stack_next);
        }

        for (i, &win) in windows_to_restack.iter().enumerate() {
            if i == 0 {
                self.connection.configure_window(
                    win,
                    &ConfigureWindowAux::new().stack_mode(StackMode::ABOVE),
                )?;
            } else {
                self.connection.configure_window(
                    win,
                    &ConfigureWindowAux::new()
                        .sibling(windows_to_restack[i - 1])
                        .stack_mode(StackMode::BELOW),
                )?;
            }
        }

        Ok(())
    }

    fn focusstack(&mut self, direction: i32) -> WmResult<()> {
        let monitor = match self.monitors.get(self.selected_monitor) {
            Some(m) => m,
            None => return Ok(()),
        };

        let selected = match monitor.selected_client {
            Some(win) => win,
            None => return Ok(()),
        };

        let selected_tags = monitor.tagset[monitor.selected_tags_index];

        let mut stack_windows: Vec<Window> = Vec::new();
        let mut current = monitor.clients_head;
        while let Some(win) = current {
            if let Some(client) = self.clients.get(&win) {
                if client.tags & selected_tags != 0 && !client.is_floating {
                    stack_windows.push(win);
                }
                current = client.next;
            } else {
                break;
            }
        }

        if stack_windows.is_empty() {
            return Ok(());
        }

        let current_idx = stack_windows.iter().position(|&w| w == selected);

        let next_window = if let Some(idx) = current_idx {
            if direction > 0 {
                if idx + 1 < stack_windows.len() {
                    stack_windows[idx + 1]
                } else {
                    stack_windows[0]
                }
            } else {
                if idx > 0 {
                    stack_windows[idx - 1]
                } else {
                    stack_windows[stack_windows.len() - 1]
                }
            }
        } else {
            return Ok(());
        };

        self.focus(Some(next_window))?;
        self.update_tab_bars()?;

        Ok(())
    }

    pub fn move_stack(&mut self, direction: i32) -> WmResult<()> {
        let monitor_index = self.selected_monitor;
        let monitor = match self.monitors.get(monitor_index) {
            Some(m) => m.clone(),
            None => return Ok(()),
        };

        let selected = match monitor.selected_client {
            Some(win) => win,
            None => return Ok(()),
        };

        let selected_client = match self.clients.get(&selected) {
            Some(c) => c,
            None => return Ok(()),
        };

        let target = if direction > 0 {
            let next = self.next_tiled(selected_client.next, &monitor);
            if next.is_some() {
                next
            } else {
                self.next_tiled(monitor.clients_head, &monitor)
            }
        } else {
            let mut previous = None;
            let mut current = monitor.clients_head;
            while let Some(window) = current {
                if window == selected {
                    break;
                }
                if let Some(client) = self.clients.get(&window) {
                    let visible_tags = client.tags & monitor.tagset[monitor.selected_tags_index];
                    if visible_tags != 0 && !client.is_floating {
                        previous = Some(window);
                    }
                    current = client.next;
                } else {
                    break;
                }
            }
            if previous.is_none() {
                let mut last = None;
                let mut current = monitor.clients_head;
                while let Some(window) = current {
                    if let Some(client) = self.clients.get(&window) {
                        let visible_tags =
                            client.tags & monitor.tagset[monitor.selected_tags_index];
                        if visible_tags != 0 && !client.is_floating {
                            last = Some(window);
                        }
                        current = client.next;
                    } else {
                        break;
                    }
                }
                last
            } else {
                previous
            }
        };

        let target = match target {
            Some(t) if t != selected => t,
            _ => return Ok(()),
        };

        let mut prev_selected = None;
        let mut prev_target = None;
        let mut current = monitor.clients_head;

        while let Some(window) = current {
            if let Some(client) = self.clients.get(&window) {
                if client.next == Some(selected) {
                    prev_selected = Some(window);
                }
                if client.next == Some(target) {
                    prev_target = Some(window);
                }
                current = client.next;
            } else {
                break;
            }
        }

        let selected_next = self.clients.get(&selected).and_then(|c| c.next);
        let target_next = self.clients.get(&target).and_then(|c| c.next);

        let temp = if selected_next == Some(target) {
            Some(selected)
        } else {
            selected_next
        };

        if let Some(client) = self.clients.get_mut(&selected) {
            client.next = if target_next == Some(selected) {
                Some(target)
            } else {
                target_next
            };
        }

        if let Some(client) = self.clients.get_mut(&target) {
            client.next = temp;
        }

        if let Some(prev) = prev_selected {
            if prev != target {
                if let Some(client) = self.clients.get_mut(&prev) {
                    client.next = Some(target);
                }
            }
        }

        if let Some(prev) = prev_target {
            if prev != selected {
                if let Some(client) = self.clients.get_mut(&prev) {
                    client.next = Some(selected);
                }
            }
        }

        if let Some(monitor) = self.monitors.get_mut(monitor_index) {
            if monitor.clients_head == Some(selected) {
                monitor.clients_head = Some(target);
            } else if monitor.clients_head == Some(target) {
                monitor.clients_head = Some(selected);
            }
        }

        self.apply_layout()?;
        Ok(())
    }

    pub fn focus_monitor(&mut self, direction: i32) -> WmResult<()> {
        if self.monitors.len() <= 1 {
            return Ok(());
        }

        let target_monitor = match self.get_adjacent_monitor(direction) {
            Some(idx) if idx != self.selected_monitor => idx,
            _ => return Ok(()),
        };

        let old_selected = self
            .monitors
            .get(self.selected_monitor)
            .and_then(|m| m.selected_client);

        if let Some(win) = old_selected {
            self.unfocus(win)?;
        }

        self.selected_monitor = target_monitor;
        self.focus(None)?;

        Ok(())
    }

    pub fn send_window_to_adjacent_monitor(&mut self, direction: i32) -> WmResult<()> {
        if self.monitors.len() <= 1 {
            return Ok(());
        }

        let selected_window = self
            .monitors
            .get(self.selected_monitor)
            .and_then(|m| m.selected_client);

        let window = match selected_window {
            Some(win) => win,
            None => return Ok(()),
        };

        let target_monitor = match self.get_adjacent_monitor(direction) {
            Some(idx) => idx,
            None => return Ok(()),
        };

        self.move_window_to_monitor(window, target_monitor)?;

        Ok(())
    }

    fn update_focus_visuals(
        &self,
        old_focused: Option<Window>,
        new_focused: Window,
    ) -> WmResult<()> {
        if let Some(old_win) = old_focused {
            if old_win != new_focused {
                self.connection.configure_window(
                    old_win,
                    &ConfigureWindowAux::new().border_width(self.config.border_width),
                )?;

                self.connection.change_window_attributes(
                    old_win,
                    &ChangeWindowAttributesAux::new().border_pixel(self.config.border_unfocused),
                )?;
            }
        }

        self.connection.configure_window(
            new_focused,
            &ConfigureWindowAux::new().border_width(self.config.border_width),
        )?;

        self.connection.change_window_attributes(
            new_focused,
            &ChangeWindowAttributesAux::new().border_pixel(self.config.border_focused),
        )?;

        self.connection.flush()?;
        Ok(())
    }

    fn drag_window(&mut self, window: Window) -> WmResult<()> {
        let is_fullscreen = self
            .clients
            .get(&window)
            .map(|c| c.is_fullscreen)
            .unwrap_or(false);

        if is_fullscreen {
            return Ok(());
        }

        let client_info = self.clients.get(&window).map(|c| {
            (
                c.x_position,
                c.y_position,
                c.width,
                c.height,
                c.is_floating,
                c.monitor_index,
            )
        });

        let Some((orig_x, orig_y, width, height, was_floating, monitor_idx)) = client_info else {
            return Ok(());
        };

        let monitor = self.monitors.get(monitor_idx).cloned();
        let Some(monitor) = monitor else {
            return Ok(());
        };

        let snap = 32;
        let is_normie = self.layout.name() == "normie";

        if !was_floating && !is_normie {
            self.toggle_floating()?;
        }

        self.connection
            .grab_pointer(
                false,
                self.root,
                (EventMask::POINTER_MOTION | EventMask::BUTTON_RELEASE | EventMask::BUTTON_PRESS)
                    .into(),
                GrabMode::ASYNC,
                GrabMode::ASYNC,
                x11rb::NONE,
                x11rb::NONE,
                x11rb::CURRENT_TIME,
            )?
            .reply()?;

        let pointer = self.connection.query_pointer(self.root)?.reply()?;
        let (start_x, start_y) = (pointer.root_x as i32, pointer.root_y as i32);

        let mut last_time = 0u32;

        loop {
            let event = self.connection.wait_for_event()?;
            match event {
                Event::ConfigureRequest(_) | Event::MapRequest(_) | Event::Expose(_) => {}
                Event::MotionNotify(e) => {
                    if e.time.wrapping_sub(last_time) <= 16 {
                        continue;
                    }
                    last_time = e.time;

                    let mut new_x = orig_x as i32 + (e.root_x as i32 - start_x);
                    let mut new_y = orig_y as i32 + (e.root_y as i32 - start_y);

                    if (monitor.window_area_x - new_x).abs() < snap {
                        new_x = monitor.window_area_x;
                    } else if ((monitor.window_area_x + monitor.window_area_width)
                        - (new_x + width as i32))
                        .abs()
                        < snap
                    {
                        new_x = monitor.window_area_x + monitor.window_area_width - width as i32;
                    }

                    if (monitor.window_area_y - new_y).abs() < snap {
                        new_y = monitor.window_area_y;
                    } else if ((monitor.window_area_y + monitor.window_area_height)
                        - (new_y + height as i32))
                        .abs()
                        < snap
                    {
                        new_y = monitor.window_area_y + monitor.window_area_height - height as i32;
                    }

                    let should_resize = is_normie
                        || self
                            .clients
                            .get(&window)
                            .map(|c| c.is_floating)
                            .unwrap_or(false);

                    if should_resize {
                        if let Some(client) = self.clients.get_mut(&window) {
                            client.x_position = new_x as i16;
                            client.y_position = new_y as i16;
                        }

                        self.connection.configure_window(
                            window,
                            &ConfigureWindowAux::new().x(new_x).y(new_y),
                        )?;
                        self.connection.flush()?;
                    }
                }
                Event::ButtonRelease(_) => break,
                _ => {}
            }
        }

        self.connection
            .ungrab_pointer(x11rb::CURRENT_TIME)?
            .check()?;

        let final_client = self
            .clients
            .get(&window)
            .map(|c| (c.x_position, c.y_position, c.width, c.height));

        if let Some((x, y, w, h)) = final_client {
            let new_monitor = self.get_monitor_for_rect(x as i32, y as i32, w as i32, h as i32);
            if new_monitor != monitor_idx {
                self.move_window_to_monitor(window, new_monitor)?;
                self.selected_monitor = new_monitor;
                self.focus(None)?;
            }
        }

        if self.config.auto_tile && !was_floating && !is_normie {
            let drop_monitor_idx = self
                .clients
                .get(&window)
                .map(|c| c.monitor_index)
                .unwrap_or(monitor_idx);

            if let Some((x, y, w, h)) = final_client {
                let center = (x as i32 + w as i32 / 2, y as i32 + h as i32 / 2);
                if let Some(target) = self.tiled_window_at(window, drop_monitor_idx, center) {
                    self.detach(window);
                    self.insert_before(window, target, drop_monitor_idx);
                }
            }

            self.floating_windows.remove(&window);
            if let Some(client) = self.clients.get_mut(&window) {
                client.is_floating = false;
            }
            self.apply_layout()?;
        }

        Ok(())
    }

    fn tiled_window_at(
        &self,
        exclude: Window,
        monitor_idx: usize,
        (px, py): (i32, i32),
    ) -> Option<Window> {
        let monitor = self.monitors.get(monitor_idx)?;
        let tags = monitor.tagset[monitor.selected_tags_index];
        let mut current = monitor.clients_head;

        while let Some(win) = current {
            let c = self.clients.get(&win)?;
            current = c.next;

            if win == exclude || c.is_floating || (c.tags & tags) == 0 {
                continue;
            }

            let (x, y) = (c.x_position as i32, c.y_position as i32);
            let (w, h) = (
                c.width as i32 + c.border_width as i32 * 2,
                c.height as i32 + c.border_width as i32 * 2,
            );

            if px >= x && px < x + w && py >= y && py < y + h {
                return Some(win);
            }
        }
        None
    }

    fn insert_before(&mut self, window: Window, target: Window, monitor_idx: usize) {
        let Some(monitor) = self.monitors.get_mut(monitor_idx) else {
            return;
        };

        if monitor.clients_head == Some(target) {
            if let Some(c) = self.clients.get_mut(&window) {
                c.next = Some(target);
            }
            monitor.clients_head = Some(window);
            return;
        }

        let mut current = monitor.clients_head;
        while let Some(w) = current {
            let Some(c) = self.clients.get(&w) else { break };
            if c.next != Some(target) {
                current = c.next;
                continue;
            }
            if let Some(prev) = self.clients.get_mut(&w) {
                prev.next = Some(window);
            }
            if let Some(inserted) = self.clients.get_mut(&window) {
                inserted.next = Some(target);
            }
            break;
        }
    }

    fn resize_window_with_mouse(&mut self, window: Window) -> WmResult<()> {
        let is_fullscreen = self
            .clients
            .get(&window)
            .map(|c| c.is_fullscreen)
            .unwrap_or(false);

        if is_fullscreen {
            return Ok(());
        }

        let client_info = self.clients.get(&window).map(|c| {
            (
                c.x_position,
                c.y_position,
                c.width,
                c.height,
                c.border_width,
                c.is_floating,
                c.monitor_index,
            )
        });

        let Some((
            orig_x,
            orig_y,
            orig_width,
            orig_height,
            border_width,
            was_floating,
            monitor_idx,
        )) = client_info
        else {
            return Ok(());
        };

        let monitor = match self.monitors.get(monitor_idx) {
            Some(m) => m,
            None => return Ok(()),
        };

        let is_normie = self.layout.name() == "normie";

        if self.config.auto_tile && !was_floating && !is_normie {
            let mut tiled_count = 0;
            let mut current = monitor.clients_head;
            while let Some(w) = current {
                if let Some(c) = self.clients.get(&w) {
                    let visible = (c.tags & monitor.tagset[monitor.selected_tags_index]) != 0;
                    if visible && !c.is_floating {
                        tiled_count += 1;
                    }
                    current = c.next;
                } else {
                    break;
                }
            }
            if tiled_count <= 1 {
                return Ok(());
            }
        }

        if !was_floating && !is_normie {
            self.toggle_floating()?;
        }

        self.connection.warp_pointer(
            x11rb::NONE,
            window,
            0,
            0,
            0,
            0,
            (orig_width + border_width - 1) as i16,
            (orig_height + border_width - 1) as i16,
        )?;

        self.connection
            .grab_pointer(
                false,
                self.root,
                (EventMask::POINTER_MOTION | EventMask::BUTTON_RELEASE | EventMask::BUTTON_PRESS)
                    .into(),
                GrabMode::ASYNC,
                GrabMode::ASYNC,
                x11rb::NONE,
                x11rb::NONE,
                x11rb::CURRENT_TIME,
            )?
            .reply()?;

        let mut last_time = 0u32;

        loop {
            let event = self.connection.wait_for_event()?;
            match event {
                Event::ConfigureRequest(_) | Event::MapRequest(_) | Event::Expose(_) => {}
                Event::MotionNotify(e) => {
                    if e.time.wrapping_sub(last_time) <= 16 {
                        continue;
                    }
                    last_time = e.time;

                    let new_width = ((e.root_x as i32 - orig_x as i32 - 2 * border_width as i32
                        + 1)
                    .max(1)) as u32;
                    let new_height = ((e.root_y as i32 - orig_y as i32 - 2 * border_width as i32
                        + 1)
                    .max(1)) as u32;

                    let should_resize = is_normie
                        || self
                            .clients
                            .get(&window)
                            .map(|c| c.is_floating)
                            .unwrap_or(false);

                    if should_resize {
                        if let Some(client) = self.clients.get(&window).cloned() {
                            let (_, _, hint_width, hint_height, _) = self.apply_size_hints(
                                window,
                                client.x_position as i32,
                                client.y_position as i32,
                                new_width as i32,
                                new_height as i32,
                            );

                            if let Some(client_mut) = self.clients.get_mut(&window) {
                                client_mut.width = hint_width as u16;
                                client_mut.height = hint_height as u16;
                            }

                            self.connection.configure_window(
                                window,
                                &ConfigureWindowAux::new()
                                    .width(hint_width as u32)
                                    .height(hint_height as u32),
                            )?;
                            self.connection.flush()?;
                        }
                    }
                }
                Event::ButtonRelease(_) => break,
                _ => {}
            }
        }

        let final_client = self.clients.get(&window).map(|c| (c.width, c.border_width));

        if let Some((w, bw)) = final_client {
            self.connection.warp_pointer(
                x11rb::NONE,
                window,
                0,
                0,
                0,
                0,
                (w + bw - 1) as i16,
                (w + bw - 1) as i16,
            )?;
        }

        self.connection
            .ungrab_pointer(x11rb::CURRENT_TIME)?
            .check()?;

        let final_client_pos = self
            .clients
            .get(&window)
            .map(|c| (c.x_position, c.y_position, c.width, c.height));

        if let Some((x, y, w, h)) = final_client_pos {
            let new_monitor = self.get_monitor_for_rect(x as i32, y as i32, w as i32, h as i32);
            if new_monitor != monitor_idx {
                self.move_window_to_monitor(window, new_monitor)?;
                self.selected_monitor = new_monitor;
                self.focus(None)?;
            }
        }

        if self.config.auto_tile && !was_floating && !is_normie {
            self.floating_windows.remove(&window);
            if let Some(client) = self.clients.get_mut(&window) {
                client.is_floating = false;
            }
            self.apply_layout()?;
        }

        Ok(())
    }

    fn handle_event(&mut self, event: Event) -> WmResult<Option<bool>> {
        match event {
            Event::KeyPress(ref key_event) if key_event.event == self.overlay.window() => {
                if self.overlay.is_visible() {
                    if let Err(error) = self.overlay.hide(&self.connection) {
                        eprintln!("Failed to hide overlay: {:?}", error);
                    }
                }
                return Ok(None);
            }
            Event::ButtonPress(ref button_event) if button_event.event == self.overlay.window() => {
                if self.overlay.is_visible() {
                    if let Err(error) = self.overlay.hide(&self.connection) {
                        eprintln!("Failed to hide overlay: {:?}", error);
                    }
                }
                return Ok(None);
            }
            Event::Expose(ref expose_event) if expose_event.window == self.overlay.window() => {
                if self.overlay.is_visible() {
                    if let Err(error) = self.overlay.draw(&self.connection, &self.font) {
                        eprintln!("Failed to draw overlay: {:?}", error);
                    }
                }
                return Ok(None);
            }
            Event::KeyPress(ref e) if e.event == self.keybind_overlay.window() => {
                if self.keybind_overlay.is_visible()
                    && !self.keybind_overlay.should_suppress_input()
                {
                    use crate::keyboard::keysyms;
                    if let Some(mapping) = &self.keyboard_mapping {
                        let keysym = mapping.keycode_to_keysym(e.detail);
                        let is_escape = keysym == keysyms::XK_ESCAPE;
                        let is_q = keysym == keysyms::XK_Q || keysym == 0x0051;
                        if is_escape || is_q {
                            if let Err(error) = self.keybind_overlay.hide(&self.connection) {
                                eprintln!("Failed to hide keybind overlay: {:?}", error);
                            }
                        }
                    }
                }
                return Ok(None);
            }
            Event::ButtonPress(ref e) if e.event == self.keybind_overlay.window() => {
                self.connection
                    .allow_events(Allow::REPLAY_POINTER, e.time)?;
                return Ok(None);
            }
            Event::Expose(ref expose_event)
                if expose_event.window == self.keybind_overlay.window() =>
            {
                if self.keybind_overlay.is_visible() {
                    if let Err(error) = self.keybind_overlay.draw(&self.connection, &self.font) {
                        eprintln!("Failed to draw keybind overlay: {:?}", error);
                    }
                }
                return Ok(None);
            }
            Event::MapRequest(event) => {
                let attrs = match self.connection.get_window_attributes(event.window)?.reply() {
                    Ok(attrs) => attrs,
                    Err(_) => return Ok(None),
                };

                if attrs.override_redirect {
                    return Ok(None);
                }

                if !self.windows.contains(&event.window) {
                    self.manage_window(event.window)?;
                }
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
            Event::PropertyNotify(event) => {
                if event.state == Property::DELETE {
                    return Ok(None);
                }

                if !self.clients.contains_key(&event.window) {
                    return Ok(None);
                }

                if event.atom == AtomEnum::WM_TRANSIENT_FOR.into() {
                    let is_floating = self
                        .clients
                        .get(&event.window)
                        .map(|c| c.is_floating)
                        .unwrap_or(false);
                    if !is_floating {
                        if let Some(parent) = self.get_transient_parent(event.window) {
                            if self.clients.contains_key(&parent) {
                                if let Some(c) = self.clients.get_mut(&event.window) {
                                    c.is_floating = true;
                                }
                                self.floating_windows.insert(event.window);
                                self.apply_layout()?;
                            }
                        }
                    }
                } else if event.atom == AtomEnum::WM_NORMAL_HINTS.into() {
                    if let Some(c) = self.clients.get_mut(&event.window) {
                        c.hints_valid = false;
                    }
                } else if event.atom == AtomEnum::WM_HINTS.into() {
                    self.update_window_hints(event.window)?;
                    self.update_bar()?;
                }

                if event.atom == self.atoms.wm_name || event.atom == self.atoms.net_wm_name {
                    let _ = self.update_window_title(event.window);
                    if self.layout.name() == "tabbed" {
                        self.update_tab_bars()?;
                    }
                }

                if event.atom == self.atoms.net_wm_window_type {
                    self.update_window_type(event.window)?;
                }
            }
            Event::EnterNotify(event) => {
                if event.mode != x11rb::protocol::xproto::NotifyMode::NORMAL {
                    return Ok(None);
                }
                if self.windows.contains(&event.event) {
                    if let Some(client) = self.clients.get(&event.event) {
                        if client.monitor_index != self.selected_monitor {
                            self.selected_monitor = client.monitor_index;
                            self.update_bar()?;
                        }
                    }
                    self.focus(Some(event.event))?;
                    self.update_tab_bars()?;
                }
            }
            Event::MotionNotify(event) => {
                if event.event != self.root {
                    return Ok(None);
                }

                if let Some(monitor_index) =
                    self.get_monitor_at_point(event.root_x as i32, event.root_y as i32)
                {
                    if monitor_index != self.selected_monitor {
                        self.selected_monitor = monitor_index;
                        self.update_bar()?;

                        let visible = self.visible_windows_on_monitor(monitor_index);
                        if let Some(&win) = visible.first() {
                            self.focus(Some(win))?;
                            self.update_tab_bars()?;
                        }
                    }
                }
            }
            Event::KeyPress(event) => {
                let Some(mapping) = &self.keyboard_mapping else {
                    return Ok(None);
                };

                let result = keyboard::handle_key_press(
                    event,
                    &self.config.keybindings,
                    &self.keychord_state,
                    mapping,
                );

                match result {
                    keyboard::handlers::KeychordResult::Completed(action, arg) => {
                        self.keychord_state = keyboard::handlers::KeychordState::Idle;
                        self.current_key = 0;
                        self.grab_keys()?;
                        self.update_bar()?;

                        match action {
                            KeyAction::Quit => return Ok(Some(false)),
                            KeyAction::Restart => match self.try_reload_config() {
                                Ok(()) => {
                                    self.gaps_enabled = self.config.gaps_enabled;
                                    self.error_message = None;
                                    if let Err(error) = self.overlay.hide(&self.connection) {
                                        eprintln!(
                                            "Failed to hide overlay after config reload: {:?}",
                                            error
                                        );
                                    }
                                    self.apply_layout()?;
                                    self.update_bar()?;
                                }
                                Err(err) => {
                                    eprintln!("Config reload error: {}", err);
                                    self.error_message = Some(err.clone());
                                    let monitor = &self.monitors[self.selected_monitor];
                                    let monitor_x = monitor.screen_x as i16;
                                    let monitor_y = monitor.screen_y as i16;
                                    let screen_width = monitor.screen_width as u16;
                                    let screen_height = monitor.screen_height as u16;
                                    match self.overlay.show_error(
                                        &self.connection,
                                        &self.font,
                                        &err,
                                        monitor_x,
                                        monitor_y,
                                        screen_width,
                                        screen_height,
                                    ) {
                                        Ok(()) => eprintln!("Error modal displayed"),
                                        Err(e) => eprintln!("Failed to show error modal: {:?}", e),
                                    }
                                }
                            },
                            _ => self.handle_key_action(action, &arg)?,
                        }
                    }
                    keyboard::handlers::KeychordResult::InProgress(candidates) => {
                        self.current_key += 1;
                        self.keychord_state = keyboard::handlers::KeychordState::InProgress {
                            candidates: candidates.clone(),
                            keys_pressed: self.current_key,
                        };
                        self.grab_keys()?;
                        self.update_bar()?;
                    }
                    keyboard::handlers::KeychordResult::Cancelled
                    | keyboard::handlers::KeychordResult::None => {
                        self.keychord_state = keyboard::handlers::KeychordState::Idle;
                        self.current_key = 0;
                        self.grab_keys()?;
                        self.update_bar()?;
                    }
                }
            }
            Event::ButtonPress(event) => {
                if self.keybind_overlay.is_visible() && event.event != self.keybind_overlay.window()
                {
                    if let Err(error) = self.keybind_overlay.hide(&self.connection) {
                        eprintln!("Failed to hide keybind overlay: {:?}", error);
                    }
                }

                let is_bar_click = self
                    .bars
                    .iter()
                    .enumerate()
                    .find(|(_, bar)| bar.window() == event.event);

                if let Some((monitor_index, bar)) = is_bar_click {
                    if let Some(tag_index) = bar.handle_click(event.event_x) {
                        if monitor_index != self.selected_monitor {
                            self.selected_monitor = monitor_index;
                        }
                        self.view_tag(tag_index)?;
                    }
                } else {
                    let is_tab_bar_click = self
                        .tab_bars
                        .iter()
                        .enumerate()
                        .find(|(_, tab_bar)| tab_bar.window() == event.event);

                    if let Some((monitor_index, tab_bar)) = is_tab_bar_click {
                        if monitor_index != self.selected_monitor {
                            self.selected_monitor = monitor_index;
                        }

                        let visible_windows: Vec<(Window, String)> = self
                            .windows
                            .iter()
                            .filter_map(|&window| {
                                if let Some(client) = self.clients.get(&window) {
                                    if client.monitor_index != monitor_index
                                        || self.floating_windows.contains(&window)
                                        || self.fullscreen_windows.contains(&window)
                                    {
                                        return None;
                                    }
                                    let monitor_tags = self
                                        .monitors
                                        .get(monitor_index)
                                        .map(|m| m.tagset[m.selected_tags_index])
                                        .unwrap_or(0);
                                    if (client.tags & monitor_tags) != 0 {
                                        return Some((window, client.name.clone()));
                                    }
                                }
                                None
                            })
                            .collect();

                        if let Some(clicked_window) =
                            tab_bar.get_clicked_window(&visible_windows, event.event_x)
                        {
                            self.connection.configure_window(
                                clicked_window,
                                &ConfigureWindowAux::new().stack_mode(StackMode::ABOVE),
                            )?;
                            self.focus(Some(clicked_window))?;
                            self.update_tab_bars()?;
                        }
                    } else if event.child != x11rb::NONE {
                        self.focus(Some(event.child))?;
                        self.restack()?;
                        self.update_tab_bars()?;

                        let state_clean = u16::from(event.state)
                            & !(u16::from(ModMask::LOCK) | u16::from(ModMask::M2));
                        let modkey_held = state_clean & u16::from(self.config.modkey) != 0;

                        if modkey_held && event.detail == ButtonIndex::M1.into() {
                            if self.clients.contains_key(&event.child) {
                                self.drag_window(event.child)?;
                            }
                            self.connection
                                .allow_events(Allow::REPLAY_POINTER, event.time)?;
                        } else if modkey_held && event.detail == ButtonIndex::M3.into() {
                            if self.clients.contains_key(&event.child) {
                                self.resize_window_with_mouse(event.child)?;
                            }
                            self.connection
                                .allow_events(Allow::REPLAY_POINTER, event.time)?;
                        } else {
                            self.connection
                                .allow_events(Allow::REPLAY_POINTER, event.time)?;
                        }
                    } else if self.windows.contains(&event.event) {
                        self.focus(Some(event.event))?;
                        self.restack()?;
                        self.update_tab_bars()?;

                        let state_clean = u16::from(event.state)
                            & !(u16::from(ModMask::LOCK) | u16::from(ModMask::M2));
                        let modkey_held = state_clean & u16::from(self.config.modkey) != 0;

                        if modkey_held && event.detail == ButtonIndex::M1.into() {
                            self.drag_window(event.event)?;
                            self.connection
                                .allow_events(Allow::REPLAY_POINTER, event.time)?;
                        } else if modkey_held && event.detail == ButtonIndex::M3.into() {
                            self.resize_window_with_mouse(event.event)?;
                            self.connection
                                .allow_events(Allow::REPLAY_POINTER, event.time)?;
                        } else {
                            self.connection
                                .allow_events(Allow::REPLAY_POINTER, event.time)?;
                        }
                    } else {
                        self.connection
                            .allow_events(Allow::REPLAY_POINTER, event.time)?;
                    }
                }
            }
            Event::Expose(event) => {
                for bar in &mut self.bars {
                    if event.window == bar.window() {
                        bar.invalidate();
                        self.update_bar()?;
                        break;
                    }
                }
                for _tab_bar in &self.tab_bars {
                    if event.window == _tab_bar.window() {
                        self.update_tab_bars()?;
                        break;
                    }
                }
            }
            Event::ConfigureRequest(event) => {
                if let Some(client) = self.clients.get(&event.window) {
                    let monitor = &self.monitors[client.monitor_index];
                    let is_floating = client.is_floating;
                    let has_layout = self.layout.name() != "normie";

                    if event.value_mask.contains(ConfigWindow::BORDER_WIDTH) {
                        if let Some(c) = self.clients.get_mut(&event.window) {
                            c.border_width = event.border_width;
                        }
                    } else if is_floating || !has_layout {
                        let mut x = client.x_position as i32;
                        let mut y = client.y_position as i32;
                        let mut w = client.width as i32;
                        let mut h = client.height as i32;

                        if event.value_mask.contains(ConfigWindow::X) {
                            if let Some(c) = self.clients.get_mut(&event.window) {
                                c.old_x_position = c.x_position;
                            }
                            x = monitor.screen_x + event.x as i32;
                        }
                        if event.value_mask.contains(ConfigWindow::Y) {
                            if let Some(c) = self.clients.get_mut(&event.window) {
                                c.old_y_position = c.y_position;
                            }
                            y = monitor.screen_y + event.y as i32;
                        }
                        if event.value_mask.contains(ConfigWindow::WIDTH) {
                            if let Some(c) = self.clients.get_mut(&event.window) {
                                c.old_width = c.width;
                            }
                            w = event.width as i32;
                        }
                        if event.value_mask.contains(ConfigWindow::HEIGHT) {
                            if let Some(c) = self.clients.get_mut(&event.window) {
                                c.old_height = c.height;
                            }
                            h = event.height as i32;
                        }

                        let bw = self.config.border_width as i32;
                        let width_with_border = w + 2 * bw;
                        let height_with_border = h + 2 * bw;

                        if (x + w) > monitor.screen_x + monitor.screen_width as i32 && is_floating {
                            x = monitor.screen_x
                                + (monitor.screen_width as i32 / 2 - width_with_border / 2);
                        }
                        if (y + h) > monitor.screen_y + monitor.screen_height as i32 && is_floating
                        {
                            y = monitor.screen_y
                                + (monitor.screen_height as i32 / 2 - height_with_border / 2);
                        }

                        if let Some(c) = self.clients.get_mut(&event.window) {
                            c.x_position = x as i16;
                            c.y_position = y as i16;
                            c.width = w as u16;
                            c.height = h as u16;
                        }

                        let only_position_change = event.value_mask.contains(ConfigWindow::X)
                            || event.value_mask.contains(ConfigWindow::Y);
                        let no_size_change = !event.value_mask.contains(ConfigWindow::WIDTH)
                            && !event.value_mask.contains(ConfigWindow::HEIGHT);
                        if only_position_change && no_size_change {
                            self.send_configure_notify(event.window)?;
                        }

                        if self.is_visible(event.window) {
                            self.connection.configure_window(
                                event.window,
                                &ConfigureWindowAux::new()
                                    .x(x)
                                    .y(y)
                                    .width(w as u32)
                                    .height(h as u32),
                            )?;
                        }
                    } else {
                        self.send_configure_notify(event.window)?;
                    }
                } else {
                    let mut aux = ConfigureWindowAux::new();
                    if event.value_mask.contains(ConfigWindow::X) {
                        aux = aux.x(event.x as i32);
                    }
                    if event.value_mask.contains(ConfigWindow::Y) {
                        aux = aux.y(event.y as i32);
                    }
                    if event.value_mask.contains(ConfigWindow::WIDTH) {
                        aux = aux.width(event.width as u32);
                    }
                    if event.value_mask.contains(ConfigWindow::HEIGHT) {
                        aux = aux.height(event.height as u32);
                    }
                    if event.value_mask.contains(ConfigWindow::BORDER_WIDTH) {
                        aux = aux.border_width(event.border_width as u32);
                    }
                    if event.value_mask.contains(ConfigWindow::SIBLING) {
                        aux = aux.sibling(event.sibling);
                    }
                    if event.value_mask.contains(ConfigWindow::STACK_MODE) {
                        aux = aux.stack_mode(event.stack_mode);
                    }
                    self.connection.configure_window(event.window, &aux)?;
                }
                self.connection.flush()?;
            }
            Event::ClientMessage(event) => {
                if !self.clients.contains_key(&event.window) {
                    return Ok(None);
                }

                if event.type_ == self.atoms.net_wm_state {
                    if let Some(data) = event.data.as_data32().get(1) {
                        if *data == self.atoms.net_wm_state_fullscreen {
                            let action = event.data.as_data32()[0];
                            let fullscreen = match action {
                                1 => true,
                                0 => false,
                                2 => !self.fullscreen_windows.contains(&event.window),
                                _ => return Ok(None),
                            };
                            self.set_window_fullscreen(event.window, fullscreen)?;
                        }
                    }
                } else if event.type_ == self.atoms.net_active_window {
                    let selected_window = self
                        .monitors
                        .get(self.selected_monitor)
                        .and_then(|m| m.selected_client);

                    let is_urgent = self
                        .clients
                        .get(&event.window)
                        .map(|c| c.is_urgent)
                        .unwrap_or(false);

                    if Some(event.window) != selected_window && !is_urgent {
                        self.set_urgent(event.window, true)?;
                    }
                }
            }
            Event::FocusIn(event) => {
                let selected_window = self
                    .monitors
                    .get(self.selected_monitor)
                    .and_then(|m| m.selected_client);

                if let Some(sel_win) = selected_window {
                    if event.event != sel_win {
                        self.set_focus(sel_win)?;
                    }
                }
            }
            Event::MappingNotify(event) => {
                if event.request == x11rb::protocol::xproto::Mapping::KEYBOARD {
                    self.grab_keys()?;
                }
            }
            Event::ConfigureNotify(event) => {
                if event.window == self.root {
                    let old_width = self.screen.width_in_pixels;
                    let old_height = self.screen.height_in_pixels;

                    if event.width != old_width || event.height != old_height {
                        self.screen = self.connection.setup().roots[self.screen_number].clone();
                        self.apply_layout()?;
                    }
                }
            }
            _ => {}
        }
        Ok(None)
    }

    fn apply_layout(&mut self) -> WmResult<()> {
        for monitor_index in 0..self.monitors.len() {
            let stack_head = self.monitors.get(monitor_index).and_then(|m| m.stack_head);
            self.showhide(stack_head)?;
        }

        let is_normie = self.layout.name() == LayoutType::Normie.as_str();

        if !is_normie {
            let monitor_count = self.monitors.len();
            for monitor_index in 0..monitor_count {
                let monitor = &self.monitors[monitor_index];
                let border_width = self.config.border_width;

                let gaps = if self.gaps_enabled {
                    GapConfig {
                        inner_horizontal: self.config.gap_inner_horizontal,
                        inner_vertical: self.config.gap_inner_vertical,
                        outer_horizontal: self.config.gap_outer_horizontal,
                        outer_vertical: self.config.gap_outer_vertical,
                    }
                } else {
                    GapConfig {
                        inner_horizontal: 0,
                        inner_vertical: 0,
                        outer_horizontal: 0,
                        outer_vertical: 0,
                    }
                };

                let monitor_x = monitor.screen_x;
                let monitor_y = monitor.screen_y;
                let monitor_width = monitor.screen_width;
                let monitor_height = monitor.screen_height;

                let mut visible: Vec<Window> = Vec::new();
                let mut current = self.next_tiled(monitor.clients_head, monitor);
                while let Some(window) = current {
                    visible.push(window);
                    if let Some(client) = self.clients.get(&window) {
                        current = self.next_tiled(client.next, monitor);
                    } else {
                        break;
                    }
                }

                let bar_height = if self.show_bar {
                    self.bars
                        .get(monitor_index)
                        .map(|bar| bar.height() as u32)
                        .unwrap_or(0)
                } else {
                    0
                };
                let usable_height = monitor_height.saturating_sub(bar_height as i32);
                let master_factor = monitor.master_factor;
                let num_master = monitor.num_master;
                let smartgaps_enabled = self.config.smartgaps_enabled;

                let geometries = self.layout.arrange(
                    &visible,
                    monitor_width as u32,
                    usable_height as u32,
                    &gaps,
                    master_factor,
                    num_master,
                    smartgaps_enabled,
                );

                for (window, geometry) in visible.iter().zip(geometries.iter()) {
                    let mut adjusted_width = geometry.width.saturating_sub(2 * border_width);
                    let mut adjusted_height = geometry.height.saturating_sub(2 * border_width);

                    if let Some(client) = self.clients.get(window).cloned() {
                        if !client.is_floating {
                            let (_, _, hint_width, hint_height, _) = self.apply_size_hints(
                                *window,
                                geometry.x_coordinate as i32,
                                geometry.y_coordinate as i32,
                                adjusted_width as i32,
                                adjusted_height as i32,
                            );
                            adjusted_width = hint_width as u32;
                            adjusted_height = hint_height as u32;
                        }
                    }

                    let adjusted_x = geometry.x_coordinate + monitor_x;
                    let adjusted_y = geometry.y_coordinate + monitor_y + bar_height as i32;

                    if let Some(client) = self.clients.get_mut(window) {
                        client.x_position = adjusted_x as i16;
                        client.y_position = adjusted_y as i16;
                        client.width = adjusted_width as u16;
                        client.height = adjusted_height as u16;
                    }

                    self.connection.configure_window(
                        *window,
                        &ConfigureWindowAux::new()
                            .x(adjusted_x)
                            .y(adjusted_y)
                            .width(adjusted_width)
                            .height(adjusted_height)
                            .border_width(border_width),
                    )?;

                    if let Some(c) = self.clients.get_mut(window) {
                        c.x_position = adjusted_x as i16;
                        c.y_position = adjusted_y as i16;
                        c.width = adjusted_width as u16;
                        c.height = adjusted_height as u16;
                        c.border_width = border_width as u16;
                    }
                }
            }
        }

        for monitor_index in 0..self.monitors.len() {
            let stack_head = self.monitors[monitor_index].stack_head;
            self.showhide(stack_head)?;
        }

        self.connection.flush()?;

        let is_tabbed = self.layout.name() == LayoutType::Tabbed.as_str();

        if is_tabbed {
            let outer_horizontal = if self.gaps_enabled {
                self.config.gap_outer_horizontal
            } else {
                0
            };
            let outer_vertical = if self.gaps_enabled {
                self.config.gap_outer_vertical
            } else {
                0
            };

            for monitor_index in 0..self.tab_bars.len() {
                if let Some(monitor) = self.monitors.get(monitor_index) {
                    let bar_height = if self.show_bar {
                        self.bars
                            .get(monitor_index)
                            .map(|bar| bar.height() as f32)
                            .unwrap_or(0.0)
                    } else {
                        0.0
                    };

                    let tab_bar_x = (monitor.screen_x + outer_horizontal as i32) as i16;
                    let tab_bar_y =
                        (monitor.screen_y as f32 + bar_height + outer_vertical as f32) as i16;
                    let tab_bar_width = monitor
                        .screen_width
                        .saturating_sub(2 * outer_horizontal as i32)
                        as u16;

                    if let Err(e) = self.tab_bars[monitor_index].reposition(
                        &self.connection,
                        tab_bar_x,
                        tab_bar_y,
                        tab_bar_width,
                    ) {
                        eprintln!("Failed to reposition tab bar: {:?}", e);
                    }
                }
            }
        }

        for monitor_index in 0..self.tab_bars.len() {
            let has_visible_windows = self.windows.iter().any(|&window| {
                if let Some(client) = self.clients.get(&window) {
                    if client.monitor_index != monitor_index
                        || self.floating_windows.contains(&window)
                        || self.fullscreen_windows.contains(&window)
                    {
                        return false;
                    }
                    if let Some(monitor) = self.monitors.get(monitor_index) {
                        return (client.tags & monitor.tagset[monitor.selected_tags_index]) != 0;
                    }
                }
                false
            });

            if is_tabbed && has_visible_windows {
                if let Err(e) = self.tab_bars[monitor_index].show(&self.connection) {
                    eprintln!("Failed to show tab bar: {:?}", e);
                }
            } else {
                if let Err(e) = self.tab_bars[monitor_index].hide(&self.connection) {
                    eprintln!("Failed to hide tab bar: {:?}", e);
                }
            }
        }

        if is_tabbed {
            self.update_tab_bars()?;
        }

        Ok(())
    }

    pub fn change_layout<L: Layout + 'static>(&mut self, new_layout: L) -> WmResult<()> {
        self.layout = Box::new(new_layout);
        self.apply_layout()?;
        Ok(())
    }

    fn send_configure_notify(&self, window: Window) -> WmResult<()> {
        let client = self.clients.get(&window);
        let (x, y, w, h, bw) = if let Some(c) = client {
            (
                c.x_position,
                c.y_position,
                c.width,
                c.height,
                c.border_width,
            )
        } else {
            let geom = self.connection.get_geometry(window)?.reply()?;
            (geom.x, geom.y, geom.width, geom.height, geom.border_width)
        };

        let event = ConfigureNotifyEvent {
            response_type: CONFIGURE_NOTIFY_EVENT,
            sequence: 0,
            event: window,
            window,
            above_sibling: x11rb::NONE,
            x,
            y,
            width: w,
            height: h,
            border_width: bw,
            override_redirect: false,
        };

        self.connection
            .send_event(false, window, EventMask::STRUCTURE_NOTIFY, event)?;

        Ok(())
    }

    fn update_size_hints(&mut self, window: Window) -> WmResult<()> {
        let size_hints = self
            .connection
            .get_property(
                false,
                window,
                x11rb::protocol::xproto::AtomEnum::WM_NORMAL_HINTS,
                x11rb::protocol::xproto::AtomEnum::WM_SIZE_HINTS,
                0,
                18,
            )?
            .reply()?;

        if size_hints.value.is_empty() {
            if let Some(client) = self.clients.get_mut(&window) {
                client.hints_valid = false;
            }
            return Ok(());
        }

        if size_hints.value.len() < 18 * 4 {
            if let Some(client) = self.clients.get_mut(&window) {
                client.hints_valid = false;
            }
            return Ok(());
        }

        use crate::size_hints::{flags::*, offset::*};

        let read_u32 = |offset: usize| -> u32 {
            let bytes = &size_hints.value[offset * 4..(offset + 1) * 4];
            u32::from_ne_bytes([bytes[0], bytes[1], bytes[2], bytes[3]])
        };

        let flags = read_u32(FLAGS);

        if let Some(client) = self.clients.get_mut(&window) {
            if flags & P_BASE_SIZE != 0 {
                client.base_width = read_u32(BASE_WIDTH) as i32;
                client.base_height = read_u32(BASE_HEIGHT) as i32;
            } else if flags & P_MIN_SIZE != 0 {
                client.base_width = read_u32(MIN_WIDTH) as i32;
                client.base_height = read_u32(MIN_HEIGHT) as i32;
            } else {
                client.base_width = 0;
                client.base_height = 0;
            }

            if flags & P_RESIZE_INC != 0 {
                client.increment_width = read_u32(WIDTH_INC) as i32;
                client.increment_height = read_u32(HEIGHT_INC) as i32;
            } else {
                client.increment_width = 0;
                client.increment_height = 0;
            }

            if flags & P_MAX_SIZE != 0 {
                client.max_width = read_u32(MAX_WIDTH) as i32;
                client.max_height = read_u32(MAX_HEIGHT) as i32;
            } else {
                client.max_width = 0;
                client.max_height = 0;
            }

            if flags & P_MIN_SIZE != 0 {
                client.min_width = read_u32(MIN_WIDTH) as i32;
                client.min_height = read_u32(MIN_HEIGHT) as i32;
            } else if flags & P_BASE_SIZE != 0 {
                client.min_width = read_u32(BASE_WIDTH) as i32;
                client.min_height = read_u32(BASE_HEIGHT) as i32;
            } else {
                client.min_width = 0;
                client.min_height = 0;
            }

            if flags & P_ASPECT != 0 {
                client.min_aspect =
                    (read_u32(MIN_ASPECT_Y) as f32) / (read_u32(MIN_ASPECT_X) as f32).max(1.0);
                client.max_aspect =
                    (read_u32(MAX_ASPECT_X) as f32) / (read_u32(MAX_ASPECT_Y) as f32).max(1.0);
            } else {
                client.min_aspect = 0.0;
                client.max_aspect = 0.0;
            }

            client.is_fixed = client.max_width > 0
                && client.max_height > 0
                && client.max_width == client.min_width
                && client.max_height == client.min_height;

            client.hints_valid = true;
        }
        Ok(())
    }

    fn update_window_title(&mut self, window: Window) -> WmResult<()> {
        let net_name = self
            .connection
            .get_property(
                false,
                window,
                self.atoms.net_wm_name,
                self.atoms.utf8_string,
                0,
                256,
            )
            .ok()
            .and_then(|cookie| cookie.reply().ok());

        if let Some(name) = net_name {
            if !name.value.is_empty() {
                if let Ok(title) = String::from_utf8(name.value.clone()) {
                    if let Some(client) = self.clients.get_mut(&window) {
                        client.name = title;
                        return Ok(());
                    }
                }
            }
        }

        let wm_name = self
            .connection
            .get_property(
                false,
                window,
                self.atoms.wm_name,
                x11rb::protocol::xproto::AtomEnum::STRING,
                0,
                256,
            )?
            .reply()?;

        if !wm_name.value.is_empty() {
            if let Ok(title) = String::from_utf8(wm_name.value.clone()) {
                if let Some(client) = self.clients.get_mut(&window) {
                    client.name = title;
                }
            }
        }

        Ok(())
    }

    fn update_window_hints(&mut self, window: Window) -> WmResult<()> {
        let hints_reply = self
            .connection
            .get_property(false, window, AtomEnum::WM_HINTS, AtomEnum::WM_HINTS, 0, 9)?
            .reply();

        if let Ok(hints) = hints_reply {
            if hints.value.len() >= 4 {
                let flags = u32::from_ne_bytes([
                    hints.value[0],
                    hints.value[1],
                    hints.value[2],
                    hints.value[3],
                ]);

                let selected_window = self
                    .monitors
                    .get(self.selected_monitor)
                    .and_then(|m| m.selected_client);

                if Some(window) == selected_window && (flags & 256) != 0 {
                    let new_flags = flags & !256;
                    let mut new_hints = hints.value.clone();
                    new_hints[0..4].copy_from_slice(&new_flags.to_ne_bytes());

                    self.connection.change_property(
                        x11rb::protocol::xproto::PropMode::REPLACE,
                        window,
                        AtomEnum::WM_HINTS,
                        AtomEnum::WM_HINTS,
                        32,
                        9,
                        &new_hints,
                    )?;
                } else {
                    if let Some(client) = self.clients.get_mut(&window) {
                        client.is_urgent = (flags & 256) != 0;
                    }
                }

                if hints.value.len() >= 8 && (flags & 1) != 0 {
                    let input = i32::from_ne_bytes([
                        hints.value[4],
                        hints.value[5],
                        hints.value[6],
                        hints.value[7],
                    ]);

                    if let Some(client) = self.clients.get_mut(&window) {
                        client.never_focus = input == 0;
                    }
                } else {
                    if let Some(client) = self.clients.get_mut(&window) {
                        client.never_focus = false;
                    }
                }
            }
        }

        Ok(())
    }

    fn update_window_type(&mut self, window: Window) -> WmResult<()> {
        if let Ok(Some(state_atom)) = self.get_window_atom_property(window, self.atoms.net_wm_state)
        {
            if state_atom == self.atoms.net_wm_state_fullscreen {
                self.set_window_fullscreen(window, true)?;
            }
        }

        if let Ok(Some(type_atom)) =
            self.get_window_atom_property(window, self.atoms.net_wm_window_type)
        {
            if type_atom == self.atoms.net_wm_window_type_dialog {
                if let Some(client) = self.clients.get_mut(&window) {
                    client.is_floating = true;
                }
                self.floating_windows.insert(window);
            }
        }

        Ok(())
    }

    fn apply_size_hints(
        &mut self,
        window: Window,
        mut x: i32,
        mut y: i32,
        mut w: i32,
        mut h: i32,
    ) -> (i32, i32, i32, i32, bool) {
        let bh = 20;

        let (
            client_x,
            client_y,
            client_w,
            client_h,
            bw,
            monitor_index,
            is_floating,
            mut hints_valid,
        ) = {
            let client = match self.clients.get(&window) {
                Some(c) => c,
                None => return (x, y, w, h, false),
            };
            (
                client.x_position as i32,
                client.y_position as i32,
                client.width as i32,
                client.height as i32,
                client.border_width as i32,
                client.monitor_index,
                client.is_floating,
                client.hints_valid,
            )
        };

        let monitor = &self.monitors[monitor_index];
        let client_width = client_w + 2 * bw;
        let client_height = client_h + 2 * bw;

        w = w.max(1);
        h = h.max(1);

        if x >= monitor.window_area_x + monitor.window_area_width {
            x = monitor.window_area_x + monitor.window_area_width - client_width;
        }
        if y >= monitor.window_area_y + monitor.window_area_height {
            y = monitor.window_area_y + monitor.window_area_height - client_height;
        }
        if x + w + 2 * bw <= monitor.window_area_x {
            x = monitor.window_area_x;
        }
        if y + h + 2 * bw <= monitor.window_area_y {
            y = monitor.window_area_y;
        }

        if h < bh {
            h = bh;
        }
        if w < bh {
            w = bh;
        }

        if is_floating || self.layout.name() == "normie" {
            if !hints_valid {
                let _ = self.update_size_hints(window);
                hints_valid = self
                    .clients
                    .get(&window)
                    .map(|c| c.hints_valid)
                    .unwrap_or(false);
            }

            if hints_valid {
                let (
                    base_width,
                    base_height,
                    min_width,
                    min_height,
                    max_width,
                    max_height,
                    inc_width,
                    inc_height,
                    min_aspect,
                    max_aspect,
                ) = {
                    let client = self.clients.get(&window).unwrap();
                    (
                        client.base_width,
                        client.base_height,
                        client.min_width,
                        client.min_height,
                        client.max_width,
                        client.max_height,
                        client.increment_width,
                        client.increment_height,
                        client.min_aspect,
                        client.max_aspect,
                    )
                };

                let base_is_min = base_width == min_width && base_height == min_height;

                if !base_is_min {
                    w -= base_width;
                    h -= base_height;
                }

                if min_aspect > 0.0 && max_aspect > 0.0 {
                    if max_aspect < (w as f32 / h as f32) {
                        w = (h as f32 * max_aspect + 0.5) as i32;
                    } else if min_aspect < (h as f32 / w as f32) {
                        h = (w as f32 * min_aspect + 0.5) as i32;
                    }
                }

                if base_is_min {
                    w -= base_width;
                    h -= base_height;
                }

                if inc_width > 0 {
                    w -= w % inc_width;
                }
                if inc_height > 0 {
                    h -= h % inc_height;
                }

                w = (w + base_width).max(min_width);
                h = (h + base_height).max(min_height);

                if max_width > 0 {
                    w = w.min(max_width);
                }
                if max_height > 0 {
                    h = h.min(max_height);
                }
            }
        }

        let changed = x != client_x || y != client_y || w != client_w || h != client_h;
        (x, y, w, h, changed)
    }

    fn next_tiled(&self, start: Option<Window>, monitor: &Monitor) -> Option<Window> {
        let mut current = start;
        while let Some(window) = current {
            if let Some(client) = self.clients.get(&window) {
                let visible_tags = client.tags & monitor.tagset[monitor.selected_tags_index];
                if visible_tags != 0 && !client.is_floating {
                    return Some(window);
                }
                current = client.next;
            } else {
                break;
            }
        }
        None
    }

    fn next_tagged(&self, start: Option<Window>, tags: u32) -> Option<Window> {
        let mut current = start;
        while let Some(window) = current {
            if let Some(client) = self.clients.get(&window) {
                let visible_on_tags = (client.tags & tags) != 0;
                if !client.is_floating && visible_on_tags {
                    return Some(window);
                }
                current = client.next;
            } else {
                break;
            }
        }
        None
    }

    fn attach(&mut self, window: Window, monitor_index: usize) {
        if let Some(monitor) = self.monitors.get_mut(monitor_index) {
            if let Some(client) = self.clients.get_mut(&window) {
                client.next = monitor.clients_head;
                monitor.clients_head = Some(window);
            }
        }
    }

    fn attach_aside(&mut self, window: Window, monitor_index: usize) {
        let monitor = match self.monitors.get(monitor_index) {
            Some(m) => m,
            None => return,
        };

        let new_window_tags = self.clients.get(&window).map(|c| c.tags).unwrap_or(0);
        let first_tagged = self.next_tagged(monitor.clients_head, new_window_tags);

        if first_tagged.is_none() {
            self.attach(window, monitor_index);
            return;
        }

        if let Some(insert_after_window) = first_tagged {
            if let Some(after_client) = self.clients.get(&insert_after_window) {
                let old_next = after_client.next;
                if let Some(new_client) = self.clients.get_mut(&window) {
                    new_client.next = old_next;
                }
                if let Some(after_client_mut) = self.clients.get_mut(&insert_after_window) {
                    after_client_mut.next = Some(window);
                }
            }
        }
    }

    fn detach(&mut self, window: Window) {
        let monitor_index = self.clients.get(&window).map(|c| c.monitor_index);
        if let Some(monitor_index) = monitor_index {
            if let Some(monitor) = self.monitors.get_mut(monitor_index) {
                if monitor.clients_head == Some(window) {
                    if let Some(client) = self.clients.get(&window) {
                        monitor.clients_head = client.next;
                    }
                } else {
                    let mut current = monitor.clients_head;
                    while let Some(current_window) = current {
                        if let Some(current_client) = self.clients.get(&current_window) {
                            if current_client.next == Some(window) {
                                let new_next = self.clients.get(&window).and_then(|c| c.next);
                                if let Some(current_client_mut) =
                                    self.clients.get_mut(&current_window)
                                {
                                    current_client_mut.next = new_next;
                                }
                                break;
                            }
                            current = current_client.next;
                        } else {
                            break;
                        }
                    }
                }
            }
        }
    }

    fn attach_stack(&mut self, window: Window, monitor_index: usize) {
        if let Some(monitor) = self.monitors.get_mut(monitor_index) {
            if let Some(client) = self.clients.get_mut(&window) {
                client.stack_next = monitor.stack_head;
                monitor.stack_head = Some(window);
            }
        }
    }

    fn detach_stack(&mut self, window: Window) {
        let monitor_index = self.clients.get(&window).map(|c| c.monitor_index);
        if let Some(monitor_index) = monitor_index {
            if let Some(monitor) = self.monitors.get_mut(monitor_index) {
                if monitor.stack_head == Some(window) {
                    if let Some(client) = self.clients.get(&window) {
                        monitor.stack_head = client.stack_next;
                    }
                    let should_update_selected = monitor.selected_client == Some(window);
                    let mut new_selected: Option<Window> = None;
                    if should_update_selected {
                        let mut stack_current = monitor.stack_head;
                        while let Some(stack_window) = stack_current {
                            if let Some(stack_client) = self.clients.get(&stack_window) {
                                if self.is_window_visible(stack_window) {
                                    new_selected = Some(stack_window);
                                    break;
                                }
                                stack_current = stack_client.stack_next;
                            } else {
                                break;
                            }
                        }
                    }
                    if should_update_selected {
                        if let Some(monitor) = self.monitors.get_mut(monitor_index) {
                            monitor.selected_client = new_selected;
                        }
                    }
                } else {
                    let mut current = monitor.stack_head;
                    while let Some(current_window) = current {
                        if let Some(current_client) = self.clients.get(&current_window) {
                            if current_client.stack_next == Some(window) {
                                let new_stack_next =
                                    self.clients.get(&window).and_then(|c| c.stack_next);
                                if let Some(current_client_mut) =
                                    self.clients.get_mut(&current_window)
                                {
                                    current_client_mut.stack_next = new_stack_next;
                                }
                                break;
                            }
                            current = current_client.stack_next;
                        } else {
                            break;
                        }
                    }
                }
            }
        }
    }

    fn remove_window(&mut self, window: Window) -> WmResult<()> {
        let initial_count = self.windows.len();

        let focused = self
            .monitors
            .get(self.selected_monitor)
            .and_then(|m| m.selected_client);

        if self.clients.contains_key(&window) {
            self.detach(window);
            self.detach_stack(window);
            self.clients.remove(&window);
        }

        self.windows.retain(|&w| w != window);
        self.floating_windows.remove(&window);

        if self.windows.len() < initial_count {
            if focused == Some(window) {
                let visible = self.visible_windows_on_monitor(self.selected_monitor);
                if let Some(&new_win) = visible.last() {
                    self.focus(Some(new_win))?;
                } else if let Some(monitor) = self.monitors.get_mut(self.selected_monitor) {
                    monitor.selected_client = None;
                }
            }

            self.apply_layout()?;
            self.update_bar()?;
        }
        Ok(())
    }

    fn get_selected_monitor(&self) -> &Monitor {
        &self.monitors[self.selected_monitor]
    }

    fn run_autostart_commands(&self) {
        for command in &self.config.autostart {
            crate::signal::spawn_detached(command);
            eprintln!("[autostart] Spawned: {}", command);
        }
    }
}
