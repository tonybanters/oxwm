use mlua::{Lua, Table, Value};
use std::cell::RefCell;
use std::rc::Rc;

use crate::ColorScheme;
use crate::bar::BlockConfig;
use crate::errors::ConfigError;
use crate::keyboard::handlers::{Arg, KeyAction, KeyBinding, KeyPress};
use crate::keyboard::keysyms::{self, Keysym};
use x11rb::protocol::xproto::KeyButMask;

#[derive(Clone)]
pub struct ConfigBuilder {
    pub border_width: u32,
    pub border_focused: u32,
    pub border_unfocused: u32,
    pub font: String,
    pub gaps_enabled: bool,
    pub smartgaps_enabled: bool,
    pub gap_inner_horizontal: u32,
    pub gap_inner_vertical: u32,
    pub gap_outer_horizontal: u32,
    pub gap_outer_vertical: u32,
    pub terminal: String,
    pub modkey: KeyButMask,
    pub tags: Vec<String>,
    pub layout_symbols: Vec<crate::LayoutSymbolOverride>,
    pub keybindings: Vec<KeyBinding>,
    pub window_rules: Vec<crate::WindowRule>,
    pub status_blocks: Vec<BlockConfig>,
    pub scheme_normal: ColorScheme,
    pub scheme_occupied: ColorScheme,
    pub scheme_selected: ColorScheme,
    pub autostart: Vec<String>,
    pub auto_tile: bool,
}

impl Default for ConfigBuilder {
    fn default() -> Self {
        Self {
            border_width: 2,
            border_focused: 0x6dade3,
            border_unfocused: 0xbbbbbb,
            font: "monospace:style=Bold:size=10".to_string(),
            gaps_enabled: true,
            smartgaps_enabled: true,
            gap_inner_horizontal: 5,
            gap_inner_vertical: 5,
            gap_outer_horizontal: 5,
            gap_outer_vertical: 5,
            terminal: "st".to_string(),
            modkey: KeyButMask::MOD4,
            tags: vec!["1".into(), "2".into(), "3".into()],
            layout_symbols: Vec::new(),
            keybindings: Vec::new(),
            window_rules: Vec::new(),
            status_blocks: Vec::new(),
            scheme_normal: ColorScheme {
                foreground: 0xffffff,
                background: 0x000000,
                underline: 0x444444,
            },
            scheme_occupied: ColorScheme {
                foreground: 0xffffff,
                background: 0x000000,
                underline: 0x444444,
            },
            scheme_selected: ColorScheme {
                foreground: 0xffffff,
                background: 0x000000,
                underline: 0x444444,
            },
            autostart: Vec::new(),
            auto_tile: false,
        }
    }
}

type SharedBuilder = Rc<RefCell<ConfigBuilder>>;

pub fn register_api(lua: &Lua) -> Result<SharedBuilder, ConfigError> {
    let builder = Rc::new(RefCell::new(ConfigBuilder::default()));

    let oxwm_table = lua.create_table()?;

    register_spawn(&lua, &oxwm_table, builder.clone())?;
    register_key_module(&lua, &oxwm_table, builder.clone())?;
    register_gaps_module(&lua, &oxwm_table, builder.clone())?;
    register_border_module(&lua, &oxwm_table, builder.clone())?;
    register_client_module(&lua, &oxwm_table)?;
    register_layout_module(&lua, &oxwm_table)?;
    register_tag_module(&lua, &oxwm_table)?;
    register_monitor_module(&lua, &oxwm_table)?;
    register_rule_module(&lua, &oxwm_table, builder.clone())?;
    register_bar_module(&lua, &oxwm_table, builder.clone())?;
    register_misc(&lua, &oxwm_table, builder.clone())?;

    lua.globals().set("oxwm", oxwm_table)?;

    Ok(builder)
}

fn register_spawn(lua: &Lua, parent: &Table, _builder: SharedBuilder) -> Result<(), ConfigError> {
    let spawn = lua.create_function(|lua, cmd: Value| create_action_table(lua, "Spawn", cmd))?;
    let spawn_terminal =
        lua.create_function(|lua, ()| create_action_table(lua, "SpawnTerminal", Value::Nil))?;
    parent.set("spawn", spawn)?;
    parent.set("spawn_terminal", spawn_terminal)?;
    Ok(())
}

fn register_key_module(
    lua: &Lua,
    parent: &Table,
    builder: SharedBuilder,
) -> Result<(), ConfigError> {
    let key_table = lua.create_table()?;

    let builder_clone = builder.clone();
    let bind = lua.create_function(move |lua, (mods, key, action): (Value, String, Value)| {
        let modifiers = parse_modifiers_value(lua, mods)?;
        let keysym = parse_keysym(&key)?;
        let (key_action, arg) = parse_action_value(lua, action)?;

        let binding = KeyBinding::single_key(modifiers, keysym, key_action, arg);
        builder_clone.borrow_mut().keybindings.push(binding);

        Ok(())
    })?;

    let builder_clone = builder.clone();
    let chord = lua.create_function(move |lua, (keys, action): (Table, Value)| {
        let mut key_presses = Vec::new();

        for i in 1..=keys.len()? {
            let key_spec: Table = keys.get(i)?;
            let mods: Value = key_spec.get(1)?;
            let key: String = key_spec.get(2)?;

            let modifiers = parse_modifiers_value(lua, mods)?;
            let keysym = parse_keysym(&key)?;

            key_presses.push(KeyPress { modifiers, keysym });
        }

        let (key_action, arg) = parse_action_value(lua, action)?;
        let binding = KeyBinding::new(key_presses, key_action, arg);
        builder_clone.borrow_mut().keybindings.push(binding);

        Ok(())
    })?;

    key_table.set("bind", bind)?;
    key_table.set("chord", chord)?;
    parent.set("key", key_table)?;
    Ok(())
}

fn register_gaps_module(
    lua: &Lua,
    parent: &Table,
    builder: SharedBuilder,
) -> Result<(), ConfigError> {
    let gaps_table = lua.create_table()?;

    let builder_clone = builder.clone();
    let set_enabled = lua.create_function(move |_, enabled: bool| {
        builder_clone.borrow_mut().gaps_enabled = enabled;
        Ok(())
    })?;

    let builder_clone = builder.clone();
    let enable = lua.create_function(move |_, ()| {
        builder_clone.borrow_mut().gaps_enabled = true;
        Ok(())
    })?;

    let builder_clone = builder.clone();
    let disable = lua.create_function(move |_, ()| {
        builder_clone.borrow_mut().gaps_enabled = false;
        Ok(())
    })?;

    let builder_clone = builder.clone();
    let set_inner = lua.create_function(move |_, (h, v): (u32, u32)| {
        let mut b = builder_clone.borrow_mut();
        b.gap_inner_horizontal = h;
        b.gap_inner_vertical = v;
        Ok(())
    })?;

    let builder_clone = builder.clone();
    let set_outer = lua.create_function(move |_, (h, v): (u32, u32)| {
        let mut b = builder_clone.borrow_mut();
        b.gap_outer_horizontal = h;
        b.gap_outer_vertical = v;
        Ok(())
    })?;

    let builder_clone = builder.clone();
    let set_smart = lua.create_function(move |_, enabled: bool| {
        builder_clone.borrow_mut().smartgaps_enabled = enabled;
        Ok(())
    })?;

    gaps_table.set("set_enabled", set_enabled)?;
    gaps_table.set("enable", enable)?;
    gaps_table.set("disable", disable)?;
    gaps_table.set("set_inner", set_inner)?;
    gaps_table.set("set_outer", set_outer)?;
    gaps_table.set("set_smart", set_smart)?;
    parent.set("gaps", gaps_table)?;
    Ok(())
}

fn register_border_module(
    lua: &Lua,
    parent: &Table,
    builder: SharedBuilder,
) -> Result<(), ConfigError> {
    let border_table = lua.create_table()?;

    let builder_clone = builder.clone();
    let set_width = lua.create_function(move |_, width: u32| {
        builder_clone.borrow_mut().border_width = width;
        Ok(())
    })?;

    let builder_clone = builder.clone();
    let set_focused_color = lua.create_function(move |_, color: Value| {
        let color_u32 = parse_color_value(color)?;
        builder_clone.borrow_mut().border_focused = color_u32;
        Ok(())
    })?;

    let builder_clone = builder.clone();
    let set_unfocused_color = lua.create_function(move |_, color: Value| {
        let color_u32 = parse_color_value(color)?;
        builder_clone.borrow_mut().border_unfocused = color_u32;
        Ok(())
    })?;

    border_table.set("set_width", set_width)?;
    border_table.set("set_focused_color", set_focused_color)?;
    border_table.set("set_unfocused_color", set_unfocused_color)?;
    parent.set("border", border_table)?;
    Ok(())
}

fn register_client_module(lua: &Lua, parent: &Table) -> Result<(), ConfigError> {
    let client_table = lua.create_table()?;

    let kill = lua.create_function(|lua, ()| create_action_table(lua, "KillClient", Value::Nil))?;

    let toggle_fullscreen =
        lua.create_function(|lua, ()| create_action_table(lua, "ToggleFullScreen", Value::Nil))?;

    let toggle_floating =
        lua.create_function(|lua, ()| create_action_table(lua, "ToggleFloating", Value::Nil))?;

    let focus_stack = lua.create_function(|lua, dir: i32| {
        create_action_table(lua, "FocusStack", Value::Integer(dir as i64))
    })?;

    let move_stack = lua.create_function(|lua, dir: i32| {
        create_action_table(lua, "MoveStack", Value::Integer(dir as i64))
    })?;

    client_table.set("kill", kill)?;
    client_table.set("toggle_fullscreen", toggle_fullscreen)?;
    client_table.set("toggle_floating", toggle_floating)?;
    client_table.set("focus_stack", focus_stack)?;
    client_table.set("move_stack", move_stack)?;

    parent.set("client", client_table)?;
    Ok(())
}

fn register_layout_module(lua: &Lua, parent: &Table) -> Result<(), ConfigError> {
    let layout_table = lua.create_table()?;

    let cycle =
        lua.create_function(|lua, ()| create_action_table(lua, "CycleLayout", Value::Nil))?;

    let set = lua.create_function(|lua, name: String| {
        create_action_table(
            lua,
            "ChangeLayout",
            Value::String(lua.create_string(&name)?),
        )
    })?;

    layout_table.set("cycle", cycle)?;
    layout_table.set("set", set)?;
    parent.set("layout", layout_table)?;
    Ok(())
}

fn register_tag_module(lua: &Lua, parent: &Table) -> Result<(), ConfigError> {
    let tag_table = lua.create_table()?;

    let view = lua.create_function(|lua, idx: i32| {
        create_action_table(lua, "ViewTag", Value::Integer(idx as i64))
    })?;

    let toggleview = lua.create_function(|lua, idx: i32| {
        create_action_table(lua, "ToggleView", Value::Integer(idx as i64))
    })?;

    let move_to = lua.create_function(|lua, idx: i32| {
        create_action_table(lua, "MoveToTag", Value::Integer(idx as i64))
    })?;

    let toggletag = lua.create_function(|lua, idx: i32| {
        create_action_table(lua, "ToggleTag", Value::Integer(idx as i64))
    })?;

    tag_table.set("view", view)?;
    tag_table.set("toggleview", toggleview)?;
    tag_table.set("move_to", move_to)?;
    tag_table.set("toggletag", toggletag)?;
    parent.set("tag", tag_table)?;
    Ok(())
}

fn register_monitor_module(lua: &Lua, parent: &Table) -> Result<(), ConfigError> {
    let monitor_table = lua.create_table()?;

    let focus = lua.create_function(|lua, direction: i64| {
        create_action_table(lua, "FocusMonitor", Value::Integer(direction))
    })?;

    let tag = lua.create_function(|lua, direction: i64| {
        create_action_table(lua, "TagMonitor", Value::Integer(direction))
    })?;

    monitor_table.set("focus", focus)?;
    monitor_table.set("tag", tag)?;
    parent.set("monitor", monitor_table)?;
    Ok(())
}

fn register_rule_module(
    lua: &Lua,
    parent: &Table,
    builder: SharedBuilder,
) -> Result<(), ConfigError> {
    let rule_table = lua.create_table()?;

    let builder_clone = builder.clone();
    let add = lua.create_function(move |_, config: Table| {
        let class: Option<String> = config.get("class").ok();
        let instance: Option<String> = config.get("instance").ok();
        let title: Option<String> = config.get("title").ok();
        let is_floating: Option<bool> = config.get("floating").ok();
        let monitor: Option<usize> = config.get("monitor").ok();

        let tags: Option<u32> = if let Ok(tag_index) = config.get::<i32>("tag") {
            if tag_index > 0 {
                Some(1 << (tag_index - 1))
            } else {
                None
            }
        } else {
            None
        };

        let rule = crate::WindowRule {
            class,
            instance,
            title,
            tags,
            is_floating,
            monitor,
        };

        builder_clone.borrow_mut().window_rules.push(rule);
        Ok(())
    })?;

    rule_table.set("add", add)?;
    parent.set("rule", rule_table)?;
    Ok(())
}

fn register_bar_module(
    lua: &Lua,
    parent: &Table,
    builder: SharedBuilder,
) -> Result<(), ConfigError> {
    let bar_table = lua.create_table()?;

    let builder_clone = builder.clone();
    let set_font = lua.create_function(move |_, font: String| {
        builder_clone.borrow_mut().font = font;
        Ok(())
    })?;

    let block_table = lua.create_table()?;

    let ram =
        lua.create_function(|lua, config: Table| create_block_config(lua, config, "Ram", None))?;

    let datetime = lua.create_function(|lua, config: Table| {
        let date_format: String = config.get("date_format").map_err(|_| {
            mlua::Error::RuntimeError(
                "oxwm.bar.block.datetime: 'date_format' field is required (e.g., '%H:%M')".into(),
            )
        })?;
        create_block_config(
            lua,
            config,
            "DateTime",
            Some(Value::String(lua.create_string(&date_format)?)),
        )
    })?;

    let shell = lua.create_function(|lua, config: Table| {
        let command: String = config.get("command").map_err(|_| {
            mlua::Error::RuntimeError("oxwm.bar.block.shell: 'command' field is required".into())
        })?;
        create_block_config(
            lua,
            config,
            "Shell",
            Some(Value::String(lua.create_string(&command)?)),
        )
    })?;

    let static_block = lua.create_function(|lua, config: Table| {
        let text: String = config.get("text").map_err(|_| {
            mlua::Error::RuntimeError("oxwm.bar.block.static: 'text' field is required".into())
        })?;
        create_block_config(
            lua,
            config,
            "Static",
            Some(Value::String(lua.create_string(&text)?)),
        )
    })?;

    let battery = lua.create_function(|lua, config: Table| {
        let charging: String = config.get("charging").map_err(|_| {
            mlua::Error::RuntimeError("oxwm.bar.block.battery: 'charging' field is required".into())
        })?;
        let discharging: String = config.get("discharging").map_err(|_| {
            mlua::Error::RuntimeError("oxwm.bar.block.battery: 'discharging' field is required".into())
        })?;
        let full: String = config.get("full").map_err(|_| {
            mlua::Error::RuntimeError("oxwm.bar.block.battery: 'full' field is required".into())
        })?;
        let battery_name: Option<String> = config.get("battery_name").ok();

        let formats_table = lua.create_table()?;
        formats_table.set("charging", charging)?;
        formats_table.set("discharging", discharging)?;
        formats_table.set("full", full)?;
        if let Some(battery_name) = battery_name {
            formats_table.set("battery_name", battery_name)?;
        }

        create_block_config(lua, config, "Battery", Some(Value::Table(formats_table)))
    })?;

    block_table.set("ram", ram)?;
    block_table.set("datetime", datetime)?;
    block_table.set("shell", shell)?;
    block_table.set("static", static_block)?;
    block_table.set("battery", battery)?;

    // Deprecated add_block() function for backwards compatibility
    // This allows old configs to still work, but users should migrate to set_blocks()
    let builder_clone = builder.clone();
    let add_block = lua.create_function(move |_, (format, block_type, arg, interval, color, underline): (String, String, Value, u64, Value, Option<bool>)| -> mlua::Result<()> {
        eprintln!("WARNING: oxwm.bar.add_block() is deprecated. Please migrate to oxwm.bar.set_blocks() with block constructors.");
        eprintln!("See the migration guide for details.");

        let cmd = match block_type.as_str() {
            "DateTime" => {
                let fmt = if let Value::String(s) = arg {
                    s.to_str()?.to_string()
                } else {
                    return Err(mlua::Error::RuntimeError("DateTime block requires format string as third argument".into()));
                };
                crate::bar::BlockCommand::DateTime(fmt)
            }
            "Shell" => {
                let cmd_str = if let Value::String(s) = arg {
                    s.to_str()?.to_string()
                } else {
                    return Err(mlua::Error::RuntimeError("Shell block requires command string as third argument".into()));
                };
                crate::bar::BlockCommand::Shell(cmd_str)
            }
            "Ram" => crate::bar::BlockCommand::Ram,
            "Static" => {
                let text = if let Value::String(s) = arg {
                    s.to_str()?.to_string()
                } else {
                    String::new()
                };
                crate::bar::BlockCommand::Static(text)
            }
            "Battery" => {
                return Err(mlua::Error::RuntimeError(
                    "Battery block is not supported with add_block(). Please use oxwm.bar.set_blocks() with oxwm.bar.block.battery()".into()
                ));
            }
            _ => return Err(mlua::Error::RuntimeError(format!("Unknown block type '{}'", block_type))),
        };

        let color_u32 = parse_color_value(color)?;

        let block = crate::bar::BlockConfig {
            format,
            command: cmd,
            interval_secs: interval,
            color: color_u32,
            underline: underline.unwrap_or(false),
        };

        builder_clone.borrow_mut().status_blocks.push(block);
        Ok(())
    })?;

    let builder_clone = builder.clone();
    let set_blocks = lua.create_function(move |_, blocks: Table| {
        use crate::bar::BlockCommand;

        let mut block_configs = Vec::new();

        for i in 1..=blocks.len()? {
            let block_table: Table = blocks.get(i)?;
            let block_type: String = block_table.get("__block_type")?;
            let format: String = block_table.get("format").unwrap_or_default();
            let interval: u64 = block_table.get("interval")?;
            let color_val: Value = block_table.get("color")?;
            let underline: bool = block_table.get("underline").unwrap_or(false);
            let arg: Option<Value> = block_table.get("__arg").ok();

            let cmd = match block_type.as_str() {
                "DateTime" => {
                    let fmt = arg
                        .and_then(|v| {
                            if let Value::String(s) = v {
                                s.to_str().ok().map(|s| s.to_string())
                            } else {
                                None
                            }
                        })
                        .ok_or_else(|| {
                            mlua::Error::RuntimeError("DateTime block missing format".into())
                        })?;
                    BlockCommand::DateTime(fmt)
                }
                "Shell" => {
                    let cmd_str = arg
                        .and_then(|v| {
                            if let Value::String(s) = v {
                                s.to_str().ok().map(|s| s.to_string())
                            } else {
                                None
                            }
                        })
                        .ok_or_else(|| {
                            mlua::Error::RuntimeError("Shell block missing command".into())
                        })?;
                    BlockCommand::Shell(cmd_str)
                }
                "Ram" => BlockCommand::Ram,
                "Static" => {
                    let text = arg
                        .and_then(|v| {
                            if let Value::String(s) = v {
                                s.to_str().ok().map(|s| s.to_string())
                            } else {
                                None
                            }
                        })
                        .unwrap_or_default();
                    BlockCommand::Static(text)
                }
                "Battery" => {
                    let formats = arg
                        .and_then(|v| {
                            if let Value::Table(t) = v {
                                Some(t)
                            } else {
                                None
                            }
                        })
                        .ok_or_else(|| {
                            mlua::Error::RuntimeError("Battery block missing formats".into())
                        })?;

                    let charging: String = formats.get("charging")?;
                    let discharging: String = formats.get("discharging")?;
                    let full: String = formats.get("full")?;
                    let battery_name: Option<String> = formats.get("battery_name").ok();

                    BlockCommand::Battery {
                        format_charging: charging,
                        format_discharging: discharging,
                        format_full: full,
                        battery_name: battery_name,
                    }
                }
                _ => {
                    return Err(mlua::Error::RuntimeError(format!(
                        "Unknown block type '{}'",
                        block_type
                    )));
                }
            };

            let color_u32 = parse_color_value(color_val)?;

            let block = crate::bar::BlockConfig {
                format,
                command: cmd,
                interval_secs: interval,
                color: color_u32,
                underline,
            };

            block_configs.push(block);
        }

        builder_clone.borrow_mut().status_blocks = block_configs;
        Ok(())
    })?;

    let builder_clone = builder.clone();
    let set_scheme_normal =
        lua.create_function(move |_, (fg, bg, ul): (Value, Value, Value)| {
            let foreground = parse_color_value(fg)?;
            let background = parse_color_value(bg)?;
            let underline = parse_color_value(ul)?;

            builder_clone.borrow_mut().scheme_normal = ColorScheme {
                foreground,
                background,
                underline,
            };
            Ok(())
        })?;

    let builder_clone = builder.clone();
    let set_scheme_occupied =
        lua.create_function(move |_, (fg, bg, ul): (Value, Value, Value)| {
            let foreground = parse_color_value(fg)?;
            let background = parse_color_value(bg)?;
            let underline = parse_color_value(ul)?;

            builder_clone.borrow_mut().scheme_occupied = ColorScheme {
                foreground,
                background,
                underline,
            };
            Ok(())
        })?;

    let builder_clone = builder.clone();
    let set_scheme_selected =
        lua.create_function(move |_, (fg, bg, ul): (Value, Value, Value)| {
            let foreground = parse_color_value(fg)?;
            let background = parse_color_value(bg)?;
            let underline = parse_color_value(ul)?;

            builder_clone.borrow_mut().scheme_selected = ColorScheme {
                foreground,
                background,
                underline,
            };
            Ok(())
        })?;

    bar_table.set("set_font", set_font)?;
    bar_table.set("block", block_table)?;
    bar_table.set("add_block", add_block)?; // Deprecated, for backwards compatibility
    bar_table.set("set_blocks", set_blocks)?;
    bar_table.set("set_scheme_normal", set_scheme_normal)?;
    bar_table.set("set_scheme_occupied", set_scheme_occupied)?;
    bar_table.set("set_scheme_selected", set_scheme_selected)?;
    parent.set("bar", bar_table)?;
    Ok(())
}

fn register_misc(lua: &Lua, parent: &Table, builder: SharedBuilder) -> Result<(), ConfigError> {
    let builder_clone = builder.clone();
    let set_terminal = lua.create_function(move |_, term: String| {
        builder_clone.borrow_mut().terminal = term;
        Ok(())
    })?;

    let builder_clone = builder.clone();
    let set_modkey = lua.create_function(move |_, modkey_str: String| {
        let modkey = parse_modkey_string(&modkey_str)
            .map_err(|e| mlua::Error::RuntimeError(format!("{}", e)))?;
        builder_clone.borrow_mut().modkey = modkey;
        Ok(())
    })?;

    let builder_clone = builder.clone();
    let set_tags = lua.create_function(move |_, tags: Vec<String>| {
        builder_clone.borrow_mut().tags = tags;
        Ok(())
    })?;

    let quit = lua.create_function(|lua, ()| create_action_table(lua, "Quit", Value::Nil))?;

    let restart = lua.create_function(|lua, ()| create_action_table(lua, "Restart", Value::Nil))?;

    let toggle_gaps =
        lua.create_function(|lua, ()| create_action_table(lua, "ToggleGaps", Value::Nil))?;

    let set_master_factor = lua.create_function(|lua, delta: i32| {
        create_action_table(lua, "SetMasterFactor", Value::Integer(delta as i64))
    })?;

    let inc_num_master = lua.create_function(|lua, delta: i32| {
        create_action_table(lua, "IncNumMaster", Value::Integer(delta as i64))
    })?;

    let show_keybinds =
        lua.create_function(|lua, ()| create_action_table(lua, "ShowKeybindOverlay", Value::Nil))?;

    let focus_monitor = lua.create_function(|lua, idx: i32| {
        create_action_table(lua, "FocusMonitor", Value::Integer(idx as i64))
    })?;

    let builder_clone = builder.clone();
    let set_layout_symbol = lua.create_function(move |_, (name, symbol): (String, String)| {
        builder_clone
            .borrow_mut()
            .layout_symbols
            .push(crate::LayoutSymbolOverride { name, symbol });
        Ok(())
    })?;

    let builder_clone = builder.clone();
    let autostart = lua.create_function(move |_, cmd: String| {
        builder_clone.borrow_mut().autostart.push(cmd);
        Ok(())
    })?;

    let builder_clone = builder.clone();
    let auto_tile = lua.create_function(move |_, enabled: bool| {
        builder_clone.borrow_mut().auto_tile = enabled;
        Ok(())
    })?;

    parent.set("set_terminal", set_terminal)?;
    parent.set("set_modkey", set_modkey)?;
    parent.set("set_tags", set_tags)?;
    parent.set("set_layout_symbol", set_layout_symbol)?;
    parent.set("autostart", autostart)?;
    parent.set("quit", quit)?;
    parent.set("restart", restart)?;
    parent.set("toggle_gaps", toggle_gaps)?;
    parent.set("set_master_factor", set_master_factor)?;
    parent.set("inc_num_master", inc_num_master)?;
    parent.set("show_keybinds", show_keybinds)?;
    parent.set("focus_monitor", focus_monitor)?;
    parent.set("auto_tile", auto_tile)?;
    Ok(())
}

fn parse_modifiers_value(_lua: &Lua, value: Value) -> mlua::Result<Vec<KeyButMask>> {
    match value {
        Value::Table(t) => {
            let mut mods = Vec::new();
            for i in 1..=t.len()? {
                let mod_str: String = t.get(i)?;
                let mask = parse_modkey_string(&mod_str)
                    .map_err(|e| mlua::Error::RuntimeError(format!("oxwm.key.bind: invalid modifier - {}", e)))?;
                mods.push(mask);
            }
            Ok(mods)
        }
        Value::String(s) => {
            let s_str = s.to_str()?;
            let mask = parse_modkey_string(&s_str)
                .map_err(|e| mlua::Error::RuntimeError(format!("oxwm.key.bind: invalid modifier - {}", e)))?;
            Ok(vec![mask])
        }
        _ => Err(mlua::Error::RuntimeError(
            "oxwm.key.bind: first argument must be a table of modifiers like {\"Mod4\"} or {\"Mod4\", \"Shift\"}".into(),
        )),
    }
}

fn parse_modkey_string(s: &str) -> Result<KeyButMask, ConfigError> {
    match s {
        "Mod1" => Ok(KeyButMask::MOD1),
        "Mod2" => Ok(KeyButMask::MOD2),
        "Mod3" => Ok(KeyButMask::MOD3),
        "Mod4" => Ok(KeyButMask::MOD4),
        "Mod5" => Ok(KeyButMask::MOD5),
        "Shift" => Ok(KeyButMask::SHIFT),
        "Control" => Ok(KeyButMask::CONTROL),
        _ => Err(ConfigError::InvalidModkey(format!(
            "'{}' is not a valid modifier. Use one of: Mod1, Mod4, Shift, Control",
            s
        ))),
    }
}

fn parse_keysym(key: &str) -> mlua::Result<Keysym> {
    keysyms::keysym_from_str(key)
        .ok_or_else(|| mlua::Error::RuntimeError(format!("unknown key '{}'. valid keys include: Return, Space, A-Z, 0-9, F1-F12, Left, Right, Up, Down, etc. check oxwm.lua type definitions for the complete list", key)))
}

fn parse_action_value(_lua: &Lua, value: Value) -> mlua::Result<(KeyAction, Arg)> {
    match value {
        Value::Function(_) => {
            Err(mlua::Error::RuntimeError(
                "action must be a function call, not a function reference. did you forget ()? example: oxwm.spawn('st') not oxwm.spawn".into()
            ))
        }
        Value::Table(t) => {
            if let Ok(action_name) = t.get::<String>("__action") {
                let action = string_to_action(&action_name)?;
                let arg = if let Ok(arg_val) = t.get::<Value>("__arg") {
                    value_to_arg(arg_val)?
                } else {
                    Arg::None
                };
                return Ok((action, arg));
            }

            Err(mlua::Error::RuntimeError(
                "action must be a table returned by oxwm functions like oxwm.spawn(), oxwm.client.kill(), oxwm.quit(), etc.".into(),
            ))
        }
        _ => Err(mlua::Error::RuntimeError(
            "action must be a table returned by oxwm functions like oxwm.spawn(), oxwm.client.kill(), oxwm.quit(), etc.".into(),
        )),
    }
}

fn string_to_action(s: &str) -> mlua::Result<KeyAction> {
    match s {
        "Spawn" => Ok(KeyAction::Spawn),
        "SpawnTerminal" => Ok(KeyAction::SpawnTerminal),
        "KillClient" => Ok(KeyAction::KillClient),
        "FocusStack" => Ok(KeyAction::FocusStack),
        "MoveStack" => Ok(KeyAction::MoveStack),
        "Quit" => Ok(KeyAction::Quit),
        "Restart" => Ok(KeyAction::Restart),
        "ViewTag" => Ok(KeyAction::ViewTag),
        "ToggleView" => Ok(KeyAction::ToggleView),
        "MoveToTag" => Ok(KeyAction::MoveToTag),
        "ToggleTag" => Ok(KeyAction::ToggleTag),
        "ToggleGaps" => Ok(KeyAction::ToggleGaps),
        "SetMasterFactor" => Ok(KeyAction::SetMasterFactor),
        "IncNumMaster" => Ok(KeyAction::IncNumMaster),
        "ToggleFullScreen" => Ok(KeyAction::ToggleFullScreen),
        "ToggleFloating" => Ok(KeyAction::ToggleFloating),
        "ChangeLayout" => Ok(KeyAction::ChangeLayout),
        "CycleLayout" => Ok(KeyAction::CycleLayout),
        "FocusMonitor" => Ok(KeyAction::FocusMonitor),
        "TagMonitor" => Ok(KeyAction::TagMonitor),
        "ShowKeybindOverlay" => Ok(KeyAction::ShowKeybindOverlay),
        _ => Err(mlua::Error::RuntimeError(format!(
            "unknown action '{}'. this is an internal error, please report it",
            s
        ))),
    }
}

fn value_to_arg(value: Value) -> mlua::Result<Arg> {
    match value {
        Value::Nil => Ok(Arg::None),
        Value::String(s) => Ok(Arg::Str(s.to_str()?.to_string())),
        Value::Integer(i) => Ok(Arg::Int(i as i32)),
        Value::Number(n) => Ok(Arg::Int(n as i32)),
        Value::Table(t) => {
            let mut arr = Vec::new();
            for i in 1..=t.len()? {
                let item: String = t.get(i)?;
                arr.push(item);
            }
            Ok(Arg::Array(arr))
        }
        _ => Ok(Arg::None),
    }
}

fn create_action_table(lua: &Lua, action_name: &str, arg: Value) -> mlua::Result<Table> {
    let table = lua.create_table()?;
    table.set("__action", action_name)?;
    table.set("__arg", arg)?;
    Ok(table)
}

fn parse_color_value(value: Value) -> mlua::Result<u32> {
    match value {
        Value::Integer(i) => Ok(i as u32),
        Value::Number(n) => Ok(n as u32),
        Value::String(s) => {
            let s = s.to_str()?;
            if s.starts_with('#') {
                u32::from_str_radix(&s[1..], 16).map_err(|e| {
                    mlua::Error::RuntimeError(format!(
                        "invalid hex color '{}': {}. use format like #ff0000 or 0xff0000",
                        s, e
                    ))
                })
            } else if s.starts_with("0x") {
                u32::from_str_radix(&s[2..], 16).map_err(|e| {
                    mlua::Error::RuntimeError(format!(
                        "invalid hex color '{}': {}. use format like 0xff0000 or #ff0000",
                        s, e
                    ))
                })
            } else {
                s.parse::<u32>().map_err(|e| {
                    mlua::Error::RuntimeError(format!(
                        "invalid color '{}': {}. use hex format like 0xff0000 or #ff0000",
                        s, e
                    ))
                })
            }
        }
        _ => Err(mlua::Error::RuntimeError(
            "color must be a number (0xff0000) or string ('#ff0000' or '0xff0000')".into(),
        )),
    }
}

fn create_block_config(
    lua: &Lua,
    config: Table,
    block_type: &str,
    arg: Option<Value>,
) -> mlua::Result<Table> {
    let table = lua.create_table()?;
    table.set("__block_type", block_type)?;

    let format: String = config.get("format").unwrap_or_default();
    let interval: u64 = config.get("interval")?;
    let color: Value = config.get("color")?;
    let underline: bool = config.get("underline").unwrap_or(false);

    table.set("format", format)?;
    table.set("interval", interval)?;
    table.set("color", color)?;
    table.set("underline", underline)?;

    if let Some(arg_val) = arg {
        table.set("__arg", arg_val)?;
    }

    Ok(table)
}
