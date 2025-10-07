use crate::bar::{BlockCommand, BlockConfig};
use crate::keyboard::handlers::Key;
use crate::keyboard::{Arg, KeyAction, keycodes};
use x11rb::protocol::xproto::KeyButMask;

// ========================================
// APPEARANCE
// ========================================
pub const BORDER_WIDTH: u32 = 0;
pub const BORDER_FOCUSED: u32 = 0x6dade3;
pub const BORDER_UNFOCUSED: u32 = 0xbbbbbb;
pub const FONT: &str = "JetBrainsMono Nerd Font:style=Bold:size=14";

// ========================================
// GAPS (Vanity Gaps)
// ========================================
pub const GAPS_ENABLED: bool = true;
pub const GAP_INNER_HORIZONTAL: u32 = 3;
pub const GAP_INNER_VERTICAL: u32 = 3;
pub const GAP_OUTER_HORIZONTAL: u32 = 3;
pub const GAP_OUTER_VERTICAL: u32 = 3;
//
// ========================================
// DEFAULTS
// ========================================
pub const TERMINAL: &str = "alacritty";
pub const XCLOCK: &str = "xclock";
pub const MODKEY: KeyButMask = KeyButMask::MOD4;

// ========================================
// BAR COLORS
// ========================================

// Base colors
const GRAY_DARK: &str = "#222222";
const GRAY_MID: &str = "#444444";
const GRAY_LIGHT: &str = "#bbbbbb";
const CYAN: &str = "#0db9d7";
const MAGENTA: &str = "#ad8ee6";
const RED: &str = "#f7768e";
const GREEN: &str = "#9ece6a";
const BLUE: &str = "#7aa2f7";
const YELLOW: &str = "#e0af68";

pub struct ColorScheme {
    pub foreground: &'static str,
    pub background: &'static str,
    pub underline: &'static str,
}

pub const SCHEME_NORMAL: ColorScheme = ColorScheme {
    foreground: GRAY_LIGHT,
    background: GRAY_DARK,
    underline: GRAY_MID,
};

pub const SCHEME_OCCUPIED: ColorScheme = ColorScheme {
    foreground: CYAN,
    background: GRAY_DARK,
    underline: CYAN,
};

pub const SCHEME_SELECTED: ColorScheme = ColorScheme {
    foreground: CYAN,
    background: GRAY_DARK,
    underline: MAGENTA,
};

// ========================================
// Commands
// ========================================
const SCREENSHOT_CMD: &[&str] = &[
    "sh",
    "-c",
    "maim -s | xclip -selection clipboard -t image/png",
];

const DMENU_CMD: &[&str] = &["sh", "-c", "dmenu_run -l 10"];

// ========================================
// TAGS
// ========================================
pub const TAG_COUNT: usize = 9;
pub const TAGS: [&str; TAG_COUNT] = ["1", "2", "3", "4", "5", "6", "7", "8", "9"];
// pub const TAGS: [&str; TAG_COUNT] = ["", "󰊯", "", "", "󰙯", "󱇤", "", "󱘶", "󰧮"];
// pub const TAGS: [&str; TAG_COUNT] = [
//     "DEV", "WWW", "SYS", "DOC", "VBOX", "CHAT", "MUS", "VID", "MISC",
// ];

// ========================================
// KEYBINDINGS
// ========================================
#[rustfmt::skip]
pub const KEYBINDINGS: &[Key] = &[
    Key::new(&[MODKEY],        keycodes::RETURN, KeyAction::Spawn,      Arg::Str(TERMINAL)),
    Key::new(&[MODKEY],        keycodes::F,      KeyAction::Spawn,      Arg::Str(XCLOCK)),

    Key::new(&[MODKEY],        keycodes::S,      KeyAction::Spawn,      Arg::Array(SCREENSHOT_CMD)),
    Key::new(&[MODKEY],        keycodes::D,      KeyAction::Spawn,      Arg::Array(DMENU_CMD)),
    Key::new(&[MODKEY],        keycodes::Q,      KeyAction::KillClient, Arg::None),
    Key::new(&[MODKEY],        keycodes::A,      KeyAction::ToggleGaps, Arg::None),
    Key::new(&[MODKEY, SHIFT], keycodes::Q,      KeyAction::Quit,       Arg::None),
    Key::new(&[MODKEY, SHIFT], keycodes::R,      KeyAction::Restart,    Arg::None),
    Key::new(&[MODKEY],        keycodes::J,      KeyAction::FocusStack, Arg::Int(-1)),
    Key::new(&[MODKEY],        keycodes::K,      KeyAction::FocusStack, Arg::Int(1)),
    
    Key::new(&[MODKEY], keycodes::KEY_1, KeyAction::ViewTag, Arg::Int(0)),
    Key::new(&[MODKEY], keycodes::KEY_2, KeyAction::ViewTag, Arg::Int(1)),
    Key::new(&[MODKEY], keycodes::KEY_3, KeyAction::ViewTag, Arg::Int(2)),
    Key::new(&[MODKEY], keycodes::KEY_4, KeyAction::ViewTag, Arg::Int(3)),
    Key::new(&[MODKEY], keycodes::KEY_5, KeyAction::ViewTag, Arg::Int(4)),
    Key::new(&[MODKEY], keycodes::KEY_6, KeyAction::ViewTag, Arg::Int(5)),
    Key::new(&[MODKEY], keycodes::KEY_7, KeyAction::ViewTag, Arg::Int(6)),
    Key::new(&[MODKEY], keycodes::KEY_8, KeyAction::ViewTag, Arg::Int(7)),
    Key::new(&[MODKEY], keycodes::KEY_9, KeyAction::ViewTag, Arg::Int(8)),
    
    Key::new(&[MODKEY, SHIFT], keycodes::KEY_1, KeyAction::MoveToTag, Arg::Int(0)),
    Key::new(&[MODKEY, SHIFT], keycodes::KEY_2, KeyAction::MoveToTag, Arg::Int(1)),
    Key::new(&[MODKEY, SHIFT], keycodes::KEY_3, KeyAction::MoveToTag, Arg::Int(2)),
    Key::new(&[MODKEY, SHIFT], keycodes::KEY_4, KeyAction::MoveToTag, Arg::Int(3)),
    Key::new(&[MODKEY, SHIFT], keycodes::KEY_5, KeyAction::MoveToTag, Arg::Int(4)),
    Key::new(&[MODKEY, SHIFT], keycodes::KEY_6, KeyAction::MoveToTag, Arg::Int(5)),
    Key::new(&[MODKEY, SHIFT], keycodes::KEY_7, KeyAction::MoveToTag, Arg::Int(6)),
    Key::new(&[MODKEY, SHIFT], keycodes::KEY_8, KeyAction::MoveToTag, Arg::Int(7)),
    Key::new(&[MODKEY, SHIFT], keycodes::KEY_9, KeyAction::MoveToTag, Arg::Int(8)),
];

// ========================================
// STATUS BAR BLOCKS
// ========================================
pub const STATUS_BLOCKS: &[BlockConfig] = &[
    BlockConfig {
        format: "",
        command: BlockCommand::Battery {
            format_charging: "󰂄 Bat: {}%",
            format_discharging: "󰁹 Bat:{}%",
            format_full: "󰁹 Bat: {}%",
        },
        interval_secs: 30,
        color: BLUE,
        underline: true,
    },
    BlockConfig {
        format: " |  ",
        command: BlockCommand::Static(""),
        interval_secs: u64::MAX,
        color: GRAY_LIGHT,
        underline: false,
    },
    BlockConfig {
        format: " {}",
        command: BlockCommand::Shell("uname -r"),
        interval_secs: u64::MAX,
        color: RED,
        underline: true,
    },
    BlockConfig {
        format: " |  ",
        command: BlockCommand::Static(""),
        interval_secs: u64::MAX,
        color: GRAY_LIGHT,
        underline: false,
    },
    BlockConfig {
        format: "󰸘 {}",
        command: BlockCommand::DateTime("%a, %b %d - %-I:%M %P"),
        interval_secs: 1,
        color: CYAN,
        underline: true,
    },
];

const SHIFT: KeyButMask = KeyButMask::SHIFT;
pub const WM_BINARY: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/target/release/oxwm");
