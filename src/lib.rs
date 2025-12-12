pub mod bar;
pub mod client;
pub mod config;
pub mod errors;
pub mod keyboard;
pub mod layout;
pub mod monitor;
pub mod overlay;
pub mod signal;
pub mod size_hints;
pub mod tab_bar;
pub mod window_manager;

pub mod prelude {
    pub use crate::ColorScheme;
    pub use crate::LayoutSymbolOverride;
    pub use crate::WindowRule;
    pub use crate::bar::{BlockCommand, BlockConfig};
    pub use crate::keyboard::{Arg, KeyAction, handlers::KeyBinding, keysyms};
    pub use x11rb::protocol::xproto::KeyButMask;
}

#[derive(Clone)]
pub struct LayoutSymbolOverride {
    pub name: String,
    pub symbol: String,
}

#[derive(Clone)]
pub struct WindowRule {
    pub class: Option<String>,
    pub instance: Option<String>,
    pub title: Option<String>,
    pub tags: Option<u32>,
    pub is_floating: Option<bool>,
    pub monitor: Option<usize>,
}

impl WindowRule {
    pub fn matches(&self, class: &str, instance: &str, title: &str) -> bool {
        let class_matches = self.class.as_ref().map_or(true, |c| class.contains(c.as_str()));
        let instance_matches = self.instance.as_ref().map_or(true, |i| instance.contains(i.as_str()));
        let title_matches = self.title.as_ref().map_or(true, |t| title.contains(t.as_str()));
        class_matches && instance_matches && title_matches
    }
}

#[derive(Clone)]
pub struct Config {
    // Appearance
    pub border_width: u32,
    pub border_focused: u32,
    pub border_unfocused: u32,
    pub font: String,

    // Gaps
    pub gaps_enabled: bool,
    pub smartgaps_enabled: bool,
    pub gap_inner_horizontal: u32,
    pub gap_inner_vertical: u32,
    pub gap_outer_horizontal: u32,
    pub gap_outer_vertical: u32,

    // Basics
    pub terminal: String,
    pub modkey: x11rb::protocol::xproto::KeyButMask,

    // Tags
    pub tags: Vec<String>,

    // Layout symbol overrides
    pub layout_symbols: Vec<LayoutSymbolOverride>,

    // Keybindings
    pub keybindings: Vec<crate::keyboard::handlers::Key>,

    // Window rules
    pub window_rules: Vec<WindowRule>,

    // Status bar
    pub status_blocks: Vec<crate::bar::BlockConfig>,

    // Bar color schemes
    pub scheme_normal: ColorScheme,
    pub scheme_occupied: ColorScheme,
    pub scheme_selected: ColorScheme,

    // Autostart commands
    pub autostart: Vec<String>,
}

#[derive(Clone, Copy)]
pub struct ColorScheme {
    pub foreground: u32,
    pub background: u32,
    pub underline: u32,
}

impl Default for Config {
    fn default() -> Self {
        use crate::keyboard::handlers::KeyBinding;
        use crate::keyboard::{Arg, KeyAction, keysyms};
        use x11rb::protocol::xproto::KeyButMask;

        const MODKEY: KeyButMask = KeyButMask::MOD4;
        const SHIFT: KeyButMask = KeyButMask::SHIFT;

        const TERMINAL: &str = "st";

        Self {
            border_width: 2,
            border_focused: 0x6dade3,
            border_unfocused: 0xbbbbbb,
            font: "monospace:size=10".to_string(),
            gaps_enabled: false,
            smartgaps_enabled: true,
            gap_inner_horizontal: 0,
            gap_inner_vertical: 0,
            gap_outer_horizontal: 0,
            gap_outer_vertical: 0,
            terminal: TERMINAL.to_string(),
            modkey: MODKEY,
            tags: vec!["1", "2", "3", "4", "5", "6", "7", "8", "9"]
                .into_iter()
                .map(String::from)
                .collect(),
            layout_symbols: vec![],
            keybindings: vec![
                KeyBinding::single_key(
                    vec![MODKEY],
                    keysyms::XK_RETURN,
                    KeyAction::Spawn,
                    Arg::Str(TERMINAL.to_string()),
                ),
                KeyBinding::single_key(
                    vec![MODKEY],
                    keysyms::XK_D,
                    KeyAction::Spawn,
                    Arg::Array(vec![
                        "sh".to_string(),
                        "-c".to_string(),
                        "dmenu_run -l 10".to_string(),
                    ]),
                ),
                KeyBinding::single_key(vec![MODKEY], keysyms::XK_Q, KeyAction::KillClient, Arg::None),
                KeyBinding::single_key(vec![MODKEY], keysyms::XK_N, KeyAction::CycleLayout, Arg::None),
                KeyBinding::single_key(
                    vec![MODKEY, SHIFT],
                    keysyms::XK_F,
                    KeyAction::ToggleFullScreen,
                    Arg::None,
                ),
                KeyBinding::single_key(vec![MODKEY], keysyms::XK_A, KeyAction::ToggleGaps, Arg::None),
                KeyBinding::single_key(vec![MODKEY, SHIFT], keysyms::XK_Q, KeyAction::Quit, Arg::None),
                KeyBinding::single_key(
                    vec![MODKEY, SHIFT],
                    keysyms::XK_R,
                    KeyAction::Restart,
                    Arg::None,
                ),
                KeyBinding::single_key(
                    vec![MODKEY],
                    keysyms::XK_F,
                    KeyAction::ToggleFloating,
                    Arg::None,
                ),
                KeyBinding::single_key(
                    vec![MODKEY],
                    keysyms::XK_J,
                    KeyAction::FocusStack,
                    Arg::Int(-1),
                ),
                KeyBinding::single_key(
                    vec![MODKEY],
                    keysyms::XK_K,
                    KeyAction::FocusStack,
                    Arg::Int(1),
                ),
                KeyBinding::single_key(
                    vec![MODKEY],
                    keysyms::XK_1,
                    KeyAction::ViewTag,
                    Arg::Int(0),
                ),
                KeyBinding::single_key(
                    vec![MODKEY],
                    keysyms::XK_2,
                    KeyAction::ViewTag,
                    Arg::Int(1),
                ),
                KeyBinding::single_key(
                    vec![MODKEY],
                    keysyms::XK_3,
                    KeyAction::ViewTag,
                    Arg::Int(2),
                ),
                KeyBinding::single_key(
                    vec![MODKEY],
                    keysyms::XK_4,
                    KeyAction::ViewTag,
                    Arg::Int(3),
                ),
                KeyBinding::single_key(
                    vec![MODKEY],
                    keysyms::XK_5,
                    KeyAction::ViewTag,
                    Arg::Int(4),
                ),
                KeyBinding::single_key(
                    vec![MODKEY],
                    keysyms::XK_6,
                    KeyAction::ViewTag,
                    Arg::Int(5),
                ),
                KeyBinding::single_key(
                    vec![MODKEY],
                    keysyms::XK_7,
                    KeyAction::ViewTag,
                    Arg::Int(6),
                ),
                KeyBinding::single_key(
                    vec![MODKEY],
                    keysyms::XK_8,
                    KeyAction::ViewTag,
                    Arg::Int(7),
                ),
                KeyBinding::single_key(
                    vec![MODKEY],
                    keysyms::XK_9,
                    KeyAction::ViewTag,
                    Arg::Int(8),
                ),
                KeyBinding::single_key(
                    vec![MODKEY, SHIFT],
                    keysyms::XK_1,
                    KeyAction::MoveToTag,
                    Arg::Int(0),
                ),
                KeyBinding::single_key(
                    vec![MODKEY, SHIFT],
                    keysyms::XK_2,
                    KeyAction::MoveToTag,
                    Arg::Int(1),
                ),
                KeyBinding::single_key(
                    vec![MODKEY, SHIFT],
                    keysyms::XK_3,
                    KeyAction::MoveToTag,
                    Arg::Int(2),
                ),
                KeyBinding::single_key(
                    vec![MODKEY, SHIFT],
                    keysyms::XK_4,
                    KeyAction::MoveToTag,
                    Arg::Int(3),
                ),
                KeyBinding::single_key(
                    vec![MODKEY, SHIFT],
                    keysyms::XK_5,
                    KeyAction::MoveToTag,
                    Arg::Int(4),
                ),
                KeyBinding::single_key(
                    vec![MODKEY, SHIFT],
                    keysyms::XK_6,
                    KeyAction::MoveToTag,
                    Arg::Int(5),
                ),
                KeyBinding::single_key(
                    vec![MODKEY, SHIFT],
                    keysyms::XK_7,
                    KeyAction::MoveToTag,
                    Arg::Int(6),
                ),
                KeyBinding::single_key(
                    vec![MODKEY, SHIFT],
                    keysyms::XK_8,
                    KeyAction::MoveToTag,
                    Arg::Int(7),
                ),
                KeyBinding::single_key(
                    vec![MODKEY, SHIFT],
                    keysyms::XK_9,
                    KeyAction::MoveToTag,
                    Arg::Int(8),
                ),
            ],
            window_rules: vec![],
            status_blocks: vec![crate::bar::BlockConfig {
                format: "{}".to_string(),
                command: crate::bar::BlockCommand::DateTime("%a, %b %d - %-I:%M %P".to_string()),
                interval_secs: 1,
                color: 0x0db9d7,
                underline: true,
            }],
            scheme_normal: ColorScheme {
                foreground: 0xbbbbbb,
                background: 0x1a1b26,
                underline: 0x444444,
            },
            scheme_occupied: ColorScheme {
                foreground: 0x0db9d7,
                background: 0x1a1b26,
                underline: 0x0db9d7,
            },
            scheme_selected: ColorScheme {
                foreground: 0x0db9d7,
                background: 0x1a1b26,
                underline: 0xad8ee6,
            },
            autostart: vec![],
        }
    }
}
