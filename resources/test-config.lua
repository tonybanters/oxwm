---@meta
---OXWM Test Configuration File (Lua)
---Using the new functional API
---Edit this file and reload with Mod+Alt+R

---Load type definitions for LSP (lua-language-server)
---Option 1: Copy templates/oxwm.lua to the same directory as your config
---Option 2: Add to your LSP settings (e.g., .luarc.json):
---  {
---    "workspace.library": [
---      "/path/to/oxwm/templates"
---    ]
---  }
---Option 3: Symlink templates/oxwm.lua to your config directory
---@module 'oxwm'


local colors = {
    lavender = 0xa9b1d6,
    light_blue = 0x7aa2f7,
    grey = 0xbbbbbb,
    purple = 0xad8ee6,
    cyan = 0x0db9d7,
    bg = 0x1a1b26,
    green = 0x9ece6a,
    red = 0xf7768e,
    fg = 0xbbbbbb,
    blue = 0x6dade3,
}

local modkey = "Mod1"

oxwm.set_terminal("st")
oxwm.set_modkey(modkey)
oxwm.set_tags({ "1", "2", "3", "4", "5", "6", "7", "8", "9" })
oxwm.auto_tile(true);

oxwm.set_layout_symbol("tiling", "[T]")
oxwm.set_layout_symbol("normie", "[F]")

oxwm.border.set_width(2)
oxwm.border.set_focused_color(colors.blue)
oxwm.border.set_unfocused_color(colors.grey)

oxwm.gaps.set_enabled(true)
oxwm.gaps.set_smart(true) -- Disable outer gaps when only 1 window (dwm smartgaps)
oxwm.gaps.set_inner(5, 5)
oxwm.gaps.set_outer(5, 5)

oxwm.rule.add({ class = "firefox", title = "Library", floating = true })
oxwm.rule.add({ instance = "gimp", tag = 5 })
oxwm.rule.add({ instance = "mpv", floating = true })

oxwm.bar.set_font("JetBrainsMono Nerd Font:style=Bold:size=12")

oxwm.bar.set_scheme_normal(colors.fg, colors.bg, 0x444444)
oxwm.bar.set_scheme_occupied(colors.cyan, colors.bg, colors.cyan)
oxwm.bar.set_scheme_selected(colors.cyan, colors.bg, colors.purple)

oxwm.key.chord({
    { { modkey }, "Space" },
    { {},         "T" }
}, oxwm.spawn("st"))

oxwm.key.bind({ modkey }, "Return", oxwm.spawn("st"))
oxwm.key.bind({ modkey }, "D", oxwm.spawn({ "sh", "-c", "dmenu_run -l 10" }))
oxwm.key.bind({ modkey }, "S", oxwm.spawn({ "sh", "-c", "maim -s | xclip -selection clipboard -t image/png" }))
oxwm.key.bind({ modkey }, "Q", oxwm.client.kill())

oxwm.key.bind({ modkey, "Shift" }, "Slash", oxwm.show_keybinds())

oxwm.key.bind({ modkey, "Shift" }, "F", oxwm.client.toggle_fullscreen())
oxwm.key.bind({ modkey, "Shift" }, "Space", oxwm.client.toggle_floating())

oxwm.key.bind({ modkey }, "F", oxwm.layout.set("normie"))
oxwm.key.bind({ modkey }, "C", oxwm.layout.set("tiling"))
oxwm.key.bind({ modkey }, "N", oxwm.layout.cycle())

oxwm.key.bind({ modkey }, "A", oxwm.toggle_gaps())

-- Master area controls
oxwm.key.bind({ modkey }, "BracketLeft", oxwm.set_master_factor(-5)) -- Decrease master area
oxwm.key.bind({ modkey }, "BracketRight", oxwm.set_master_factor(5)) -- Increase master area
oxwm.key.bind({ modkey }, "I", oxwm.inc_num_master(1))               -- More master windows
oxwm.key.bind({ modkey }, "P", oxwm.inc_num_master(-1))              -- Fewer master windows

-- Multi-monitor controls (dwm-style)
oxwm.key.bind({ modkey }, "Comma", oxwm.monitor.focus(-1))        -- Focus previous monitor
oxwm.key.bind({ modkey }, "Period", oxwm.monitor.focus(1))        -- Focus next monitor
oxwm.key.bind({ modkey, "Shift" }, "Comma", oxwm.monitor.tag(-1)) -- Send window to previous monitor
oxwm.key.bind({ modkey, "Shift" }, "Period", oxwm.monitor.tag(1)) -- Send window to next monitor

oxwm.key.bind({ modkey, "Shift" }, "Q", oxwm.quit())
oxwm.key.bind({ modkey, "Shift" }, "R", oxwm.restart())

oxwm.key.bind({ modkey }, "J", oxwm.client.focus_stack(1))
oxwm.key.bind({ modkey }, "K", oxwm.client.focus_stack(-1))

oxwm.key.bind({ modkey, "Shift" }, "J", oxwm.client.move_stack(1))
oxwm.key.bind({ modkey, "Shift" }, "K", oxwm.client.move_stack(-1))

-- View tag (switch workspace)
oxwm.key.bind({ modkey }, "1", oxwm.tag.view(0))
oxwm.key.bind({ modkey }, "2", oxwm.tag.view(1))
oxwm.key.bind({ modkey }, "3", oxwm.tag.view(2))
oxwm.key.bind({ modkey }, "4", oxwm.tag.view(3))
oxwm.key.bind({ modkey }, "5", oxwm.tag.view(4))
oxwm.key.bind({ modkey }, "6", oxwm.tag.view(5))
oxwm.key.bind({ modkey }, "7", oxwm.tag.view(6))
oxwm.key.bind({ modkey }, "8", oxwm.tag.view(7))
oxwm.key.bind({ modkey }, "9", oxwm.tag.view(8))

-- Move window to tag
oxwm.key.bind({ modkey, "Shift" }, "1", oxwm.tag.move_to(0))
oxwm.key.bind({ modkey, "Shift" }, "2", oxwm.tag.move_to(1))
oxwm.key.bind({ modkey, "Shift" }, "3", oxwm.tag.move_to(2))
oxwm.key.bind({ modkey, "Shift" }, "4", oxwm.tag.move_to(3))
oxwm.key.bind({ modkey, "Shift" }, "5", oxwm.tag.move_to(4))
oxwm.key.bind({ modkey, "Shift" }, "6", oxwm.tag.move_to(5))
oxwm.key.bind({ modkey, "Shift" }, "7", oxwm.tag.move_to(6))
oxwm.key.bind({ modkey, "Shift" }, "8", oxwm.tag.move_to(7))
oxwm.key.bind({ modkey, "Shift" }, "9", oxwm.tag.move_to(8))

-- Toggle view (view multiple tags at once) - dwm-style multi-tag viewing
-- Example: Mod+Ctrl+2 while on tag 1 will show BOTH tags 1 and 2
oxwm.key.bind({ modkey, "Control" }, "1", oxwm.tag.toggleview(0))
oxwm.key.bind({ modkey, "Control" }, "2", oxwm.tag.toggleview(1))
oxwm.key.bind({ modkey, "Control" }, "3", oxwm.tag.toggleview(2))
oxwm.key.bind({ modkey, "Control" }, "4", oxwm.tag.toggleview(3))
oxwm.key.bind({ modkey, "Control" }, "5", oxwm.tag.toggleview(4))
oxwm.key.bind({ modkey, "Control" }, "6", oxwm.tag.toggleview(5))
oxwm.key.bind({ modkey, "Control" }, "7", oxwm.tag.toggleview(6))
oxwm.key.bind({ modkey, "Control" }, "8", oxwm.tag.toggleview(7))
oxwm.key.bind({ modkey, "Control" }, "9", oxwm.tag.toggleview(8))

-- Toggle tag (window on multiple tags) - dwm-style sticky windows
-- Example: Mod+Ctrl+Shift+2 puts focused window on BOTH current tag and tag 2
oxwm.key.bind({ modkey, "Control", "Shift" }, "1", oxwm.tag.toggletag(0))
oxwm.key.bind({ modkey, "Control", "Shift" }, "2", oxwm.tag.toggletag(1))
oxwm.key.bind({ modkey, "Control", "Shift" }, "3", oxwm.tag.toggletag(2))
oxwm.key.bind({ modkey, "Control", "Shift" }, "4", oxwm.tag.toggletag(3))
oxwm.key.bind({ modkey, "Control", "Shift" }, "5", oxwm.tag.toggletag(4))
oxwm.key.bind({ modkey, "Control", "Shift" }, "6", oxwm.tag.toggletag(5))
oxwm.key.bind({ modkey, "Control", "Shift" }, "7", oxwm.tag.toggletag(6))
oxwm.key.bind({ modkey, "Control", "Shift" }, "8", oxwm.tag.toggletag(7))
oxwm.key.bind({ modkey, "Control", "Shift" }, "9", oxwm.tag.toggletag(8))

oxwm.bar.set_blocks({
    oxwm.bar.block.battery({
        format = "Bat: {}%",
        charging = "⚡ Bat: {}%",
        discharging = "🔋 Bat: {}%",
        full = "✓ Bat: {}%",
        interval = 30,
        color = colors.green,
        underline = true,
    }),
    -- oxwm.bar.block.battery({
    --     charging = "󰂄 Bat: {}%",
    --     discharging = "󰁹 Bat: {}%",
    --     full = "󰁹 Bat: {}%",
    --     format = "",
    --     interval = 30,
    --     color = colors.green,
    --     underline = true
    -- }),
    oxwm.bar.block.static({
        text = " │  ",
        format = "",
        interval = 999999999,
        color = colors.lavender,
        underline = false
    }),
    oxwm.bar.block.ram({
        format = "󰍛 {used}/{total} GB",
        interval = 5,
        color = colors.light_blue,
        underline = true
    }),
    oxwm.bar.block.static({
        text = " │  ",
        format = "",
        interval = 999999999,
        color = colors.lavender,
        underline = false
    }),
    oxwm.bar.block.shell({
        command = "uname -r",
        format = " {}",
        interval = 999999999,
        color = colors.red,
        underline = true
    }),
    oxwm.bar.block.static({
        text = " │  ",
        format = "",
        interval = 999999999,
        color = colors.lavender,
        underline = false
    }),
    oxwm.bar.block.datetime({
        format = "󰸘 {}",
        interval = 1,
        color = colors.cyan,
        underline = true,
        date_format = "%a, %b %d - %-I:%M %P"
    })
})
