use std::io::Result;

use serde::Deserialize;
use x11rb::connection::Connection;
use x11rb::protocol::xproto::*;

use crate::errors::X11Error;
use crate::keyboard::keysyms::{self, Keysym};

#[derive(Debug, Copy, Clone, Deserialize, PartialEq)]
pub enum KeyAction {
    Spawn,
    SpawnTerminal,
    KillClient,
    FocusStack,
    MoveStack,
    Quit,
    Restart,
    ViewTag,
    ToggleView,
    MoveToTag,
    ToggleTag,
    ToggleGaps,
    ToggleFullScreen,
    ToggleFloating,
    ChangeLayout,
    CycleLayout,
    FocusMonitor,
    TagMonitor,
    ShowKeybindOverlay,
    SetMasterFactor,
    IncNumMaster,
    None,
}

#[derive(Debug, Clone)]
pub enum Arg {
    None,
    Int(i32),
    Str(String),
    Array(Vec<String>),
}

impl Arg {
    pub const fn none() -> Self {
        Arg::None
    }
}

#[derive(Clone, Debug)]
pub struct KeyPress {
    pub(crate) modifiers: Vec<KeyButMask>,
    pub(crate) keysym: Keysym,
}

#[derive(Clone)]
pub struct KeyBinding {
    pub(crate) keys: Vec<KeyPress>,
    pub(crate) func: KeyAction,
    pub(crate) arg: Arg,
}

impl KeyBinding {
    pub fn new(keys: Vec<KeyPress>, func: KeyAction, arg: Arg) -> Self {
        Self { keys, func, arg }
    }

    pub fn single_key(
        modifiers: Vec<KeyButMask>,
        keysym: Keysym,
        func: KeyAction,
        arg: Arg,
    ) -> Self {
        Self {
            keys: vec![KeyPress { modifiers, keysym }],
            func,
            arg,
        }
    }
}

pub type Key = KeyBinding;

#[derive(Debug, Clone)]
pub enum KeychordState {
    Idle,
    InProgress {
        candidates: Vec<usize>,
        keys_pressed: usize,
    },
}

pub enum KeychordResult {
    Completed(KeyAction, Arg),
    InProgress(Vec<usize>),
    None,
    Cancelled,
}

pub fn modifiers_to_mask(modifiers: &[KeyButMask]) -> u16 {
    modifiers
        .iter()
        .fold(0u16, |acc, &modifier| acc | u16::from(modifier))
}

pub struct KeyboardMapping {
    pub syms: Vec<Keysym>,
    pub keysyms_per_keycode: u8,
    pub min_keycode: Keycode,
}

impl KeyboardMapping {
    pub fn keycode_to_keysym(&self, keycode: Keycode) -> Keysym {
        if keycode < self.min_keycode {
            return 0;
        }
        let index = (keycode - self.min_keycode) as usize * self.keysyms_per_keycode as usize;
        self.syms.get(index).copied().unwrap_or(0)
    }

    pub fn find_keycode(&self, keysym: Keysym, min_keycode: Keycode, max_keycode: Keycode) -> Option<Keycode> {
        for keycode in min_keycode..=max_keycode {
            let index = (keycode - self.min_keycode) as usize * self.keysyms_per_keycode as usize;
            if let Some(&sym) = self.syms.get(index) {
                if sym == keysym {
                    return Some(keycode);
                }
            }
        }
        None
    }
}

pub fn get_keyboard_mapping(
    connection: &impl Connection,
) -> std::result::Result<KeyboardMapping, X11Error> {
    let setup = connection.setup();
    let min_keycode = setup.min_keycode;
    let max_keycode = setup.max_keycode;

    let mapping = connection
        .get_keyboard_mapping(min_keycode, max_keycode - min_keycode + 1)?
        .reply()?;

    Ok(KeyboardMapping {
        syms: mapping.keysyms,
        keysyms_per_keycode: mapping.keysyms_per_keycode,
        min_keycode,
    })
}

pub fn grab_keys(
    connection: &impl Connection,
    root: Window,
    keybindings: &[KeyBinding],
    current_key: usize,
) -> std::result::Result<KeyboardMapping, X11Error> {
    let setup = connection.setup();
    let min_keycode = setup.min_keycode;
    let max_keycode = setup.max_keycode;

    let mapping = get_keyboard_mapping(connection)?;

    connection.ungrab_key(x11rb::protocol::xproto::Grab::ANY, root, ModMask::ANY)?;

    let modifiers = [
        0u16,
        u16::from(ModMask::LOCK),
        u16::from(ModMask::M2),
        u16::from(ModMask::LOCK | ModMask::M2),
    ];

    for keycode in min_keycode..=max_keycode {
        for keybinding in keybindings {
            if current_key >= keybinding.keys.len() {
                continue;
            }

            let key = &keybinding.keys[current_key];
            if key.keysym == mapping.keycode_to_keysym(keycode) {
                let modifier_mask = modifiers_to_mask(&key.modifiers);
                for &ignore_mask in &modifiers {
                    connection.grab_key(
                        true,
                        root,
                        (modifier_mask | ignore_mask).into(),
                        keycode,
                        GrabMode::ASYNC,
                        GrabMode::ASYNC,
                    )?;
                }
            }
        }
    }

    if current_key > 0 {
        if let Some(escape_keycode) = mapping.find_keycode(keysyms::XK_ESCAPE, min_keycode, max_keycode) {
            connection.grab_key(
                true,
                root,
                ModMask::ANY,
                escape_keycode,
                GrabMode::ASYNC,
                GrabMode::ASYNC,
            )?;
        }
    }

    connection.flush()?;
    Ok(mapping)
}

pub fn handle_key_press(
    event: KeyPressEvent,
    keybindings: &[KeyBinding],
    keychord_state: &KeychordState,
    mapping: &KeyboardMapping,
) -> KeychordResult {
    let keysym = mapping.keycode_to_keysym(event.detail);

    if keysym == keysyms::XK_ESCAPE {
        return match keychord_state {
            KeychordState::InProgress { .. } => KeychordResult::Cancelled,
            KeychordState::Idle => KeychordResult::None,
        };
    }

    match keychord_state {
        KeychordState::Idle => handle_first_key(event, keysym, keybindings),
        KeychordState::InProgress {
            candidates,
            keys_pressed,
        } => handle_next_key(event, keysym, keybindings, candidates, *keys_pressed),
    }
}

fn handle_first_key(
    event: KeyPressEvent,
    event_keysym: Keysym,
    keybindings: &[KeyBinding],
) -> KeychordResult {
    let mut candidates = Vec::new();

    let clean_state = event.state & !(u16::from(ModMask::LOCK) | u16::from(ModMask::M2));

    for (keybinding_index, keybinding) in keybindings.iter().enumerate() {
        if keybinding.keys.is_empty() {
            continue;
        }

        let first_key = &keybinding.keys[0];
        let modifier_mask = modifiers_to_mask(&first_key.modifiers);

        if event_keysym == first_key.keysym && clean_state == modifier_mask.into() {
            if keybinding.keys.len() == 1 {
                return KeychordResult::Completed(keybinding.func, keybinding.arg.clone());
            } else {
                candidates.push(keybinding_index);
            }
        }
    }

    if candidates.is_empty() {
        KeychordResult::None
    } else {
        KeychordResult::InProgress(candidates)
    }
}

fn handle_next_key(
    event: KeyPressEvent,
    event_keysym: Keysym,
    keybindings: &[KeyBinding],
    candidates: &[usize],
    keys_pressed: usize,
) -> KeychordResult {
    let mut new_candidates = Vec::new();

    let clean_state = event.state & !(u16::from(ModMask::LOCK) | u16::from(ModMask::M2));

    for &candidate_index in candidates {
        let keybinding = &keybindings[candidate_index];

        if keys_pressed >= keybinding.keys.len() {
            continue;
        }

        let next_key = &keybinding.keys[keys_pressed];
        let required_mask = modifiers_to_mask(&next_key.modifiers);

        let modifiers_match = if next_key.modifiers.is_empty() {
            true
        } else {
            (clean_state & required_mask) == required_mask.into()
        };

        if event_keysym == next_key.keysym && modifiers_match {
            if keys_pressed + 1 == keybinding.keys.len() {
                return KeychordResult::Completed(keybinding.func, keybinding.arg.clone());
            } else {
                new_candidates.push(candidate_index);
            }
        }
    }

    if new_candidates.is_empty() {
        KeychordResult::Cancelled
    } else {
        KeychordResult::InProgress(new_candidates)
    }
}

pub fn handle_spawn_action(action: KeyAction, arg: &Arg, selected_monitor: usize) -> Result<()> {
    if let KeyAction::Spawn = action {
        match arg {
            Arg::Str(command) => {
                crate::signal::spawn_detached(command);
            }
            Arg::Array(command) => {
                let Some((cmd, args)) = command.split_first() else {
                    return Ok(());
                };

                let mut args_vec: Vec<String> = args.to_vec();

                let is_dmenu = cmd.contains("dmenu");
                let has_monitor_flag = args.iter().any(|arg| arg == "-m");

                if is_dmenu && !has_monitor_flag {
                    args_vec.insert(0, selected_monitor.to_string());
                    args_vec.insert(0, "-m".to_string());
                }

                let args_str: Vec<&str> = args_vec.iter().map(|s| s.as_str()).collect();
                crate::signal::spawn_detached_with_args(cmd, &args_str);
            }
            _ => {}
        }
    }

    Ok(())
}
