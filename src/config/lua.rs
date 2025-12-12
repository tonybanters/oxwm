use crate::errors::ConfigError;
use mlua::Lua;

use super::lua_api;

pub fn parse_lua_config(
    input: &str,
    config_dir: Option<&std::path::Path>,
) -> Result<crate::Config, ConfigError> {
    let lua = Lua::new();

    if let Some(dir) = config_dir {
        if let Some(dir_str) = dir.to_str() {
            let setup_code = format!("package.path = '{}/?.lua;' .. package.path", dir_str);
            lua.load(&setup_code)
                .exec()
                .map_err(|e| ConfigError::LuaError(format!("Failed to set package.path: {}", e)))?;
        }
    }

    let builder = lua_api::register_api(&lua)?;

    lua.load(input)
        .exec()
        .map_err(|e| ConfigError::LuaError(format!("{}", e)))?;

    let builder_data = builder.borrow().clone();

    return Ok(crate::Config {
        border_width: builder_data.border_width,
        border_focused: builder_data.border_focused,
        border_unfocused: builder_data.border_unfocused,
        font: builder_data.font,
        gaps_enabled: builder_data.gaps_enabled,
        smartgaps_enabled: builder_data.smartgaps_enabled,
        gap_inner_horizontal: builder_data.gap_inner_horizontal,
        gap_inner_vertical: builder_data.gap_inner_vertical,
        gap_outer_horizontal: builder_data.gap_outer_horizontal,
        gap_outer_vertical: builder_data.gap_outer_vertical,
        terminal: builder_data.terminal,
        modkey: builder_data.modkey,
        tags: builder_data.tags,
        layout_symbols: builder_data.layout_symbols,
        keybindings: builder_data.keybindings,
        window_rules: builder_data.window_rules,
        status_blocks: builder_data.status_blocks,
        scheme_normal: builder_data.scheme_normal,
        scheme_occupied: builder_data.scheme_occupied,
        scheme_selected: builder_data.scheme_selected,
        autostart: builder_data.autostart,
    });
}
