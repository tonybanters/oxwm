{self}: {
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkEnableOption mkOption mkIf types concatMapStringsSep concatStringsSep concatMapStrings boolToString optional optionalString;
  inherit (lib.strings) escapeNixString;
  cfg = config.programs.oxwm.settings;
  pkg = config.programs.oxwm.package;

  # Converts a nix submodule into a single oxwm bar block
  blockToLua = block: let
    common = ''
      interval = ${toString block.interval},
      color = "#${block.color}",
      ${optionalString (block.bg != "") ''bg = "#${block.bg}",''}
      underline = ${boolToString block.underline},
    '';
  in
    "oxwm.bar.block.${block.kind}({\n"
    + (
      if block.kind == "static"
      then ''
        text = "${block.text}",
        ${common}
      ''
      else if block.kind == "shell"
      then ''
        format = "${block.format}",
        command = "${block.command}",
        ${common}
      ''
      else if block.kind == "datetime"
      then ''
        format = "${block.format}",
        date_format = "${block.date_format}",
        ${common}
      ''
      else if block.kind == "battery"
      then ''
        format = "${block.format}",
        charging = "${block.charging}",
        discharging = "${block.discharging}",
        full = "${block.full}",
        ${common}
      ''
      else ''
        format = "${block.format}",
        ${common}
      ''
    )
    + "})";

  # Converts a nix submodule into a single oxwm window rule
  ruleToLua = rule: let
    fields = concatStringsSep ", " (
      optional (rule.match.class != null) ''class = "${rule.match.class}"''
      ++ optional (rule.match.instance != null) ''instance = "${rule.match.instance}"''
      ++ optional (rule.match.title != null) ''title = "${rule.match.title}"''
      ++ optional (rule.match.role != null) ''role = "${rule.match.role}"''
      ++ optional (rule.floating != null) ''floating = ${boolToString rule.floating}''
      ++ optional (rule.tag != null) ''tag = ${toString rule.tag}''
      ++ optional (rule.fullscreen != null) ''fullscreen = ${boolToString rule.fullscreen}''
      ++ optional (rule.focus != null) ''focus = ${boolToString rule.focus}''
    );
  in "oxwm.rule.add({ ${fields} })";

  configText = ''
    -- @meta
    -- @module 'oxwm'

    oxwm.set_terminal("${cfg.terminal}")
    oxwm.set_modkey("${cfg.modkey}")
    oxwm.set_tags({${concatMapStringsSep ", " escapeNixString cfg.tags}})

    local blocks = {
      ${concatMapStringsSep ",\n" blockToLua cfg.bar.blocks}
    };
    oxwm.bar.set_blocks(blocks)
    oxwm.bar.set_font("${cfg.bar.font}")
    oxwm.bar.set_scheme_normal(${concatMapStringsSep ", " (c: ''"#${c}"'') cfg.bar.unoccupiedScheme})
    oxwm.bar.set_scheme_occupied(${concatMapStringsSep ", " (c: ''"#${c}"'') cfg.bar.occupiedScheme})
    oxwm.bar.set_scheme_selected(${concatMapStringsSep ", " (c: ''"#${c}"'') cfg.bar.selectedScheme})
    oxwm.bar.set_scheme_urgent(${concatMapStringsSep ", " (c: ''"#${c}"'') cfg.bar.urgentScheme})
    oxwm.bar.set_hide_vacant_tags(${boolToString cfg.bar.hideVacantTags})
    oxwm.bar.set_show_title(${boolToString cfg.bar.showTitle})
    oxwm.bar.set_max_title_length(${toString cfg.bar.maxTitleLength})

    oxwm.border.set_width(${toString cfg.border.width})
    oxwm.border.set_focused_color("#${cfg.border.focusedColor}")
    oxwm.border.set_unfocused_color("#${cfg.border.unfocusedColor}")

    oxwm.gaps.set_smart(${boolToString cfg.gaps.smart})
    oxwm.gaps.set_inner(${concatMapStringsSep ", " toString cfg.gaps.inner})
    oxwm.gaps.set_outer(${concatMapStringsSep ", " toString cfg.gaps.outer})

    oxwm.set_layout_symbol("tiling", "${cfg.layoutSymbol.tiling}")
    oxwm.set_layout_symbol("normie", "${cfg.layoutSymbol.normie}")
    oxwm.set_layout_symbol("tabbed", "${cfg.layoutSymbol.tabbed}")

    ${
      concatMapStrings (cmd: ''
        oxwm.autostart("${cmd}")
      '')
      cfg.autostart
    }
    ${
      concatMapStrings (bind: ''
        oxwm.key.bind({ ${concatMapStringsSep ", " escapeNixString bind.mods} }, "${bind.key}", ${bind.action})
      '')
      cfg.binds
    }
    ${
      concatMapStrings (chord: ''
        oxwm.key.chord({
          ${concatMapStringsSep ",\n  " (note: ''{ { ${concatMapStringsSep ", " escapeNixString note.mods} }, "${note.key}" }'') chord.notes}
        }, ${chord.action})
      '')
      cfg.chords
    }
    ${
      concatMapStrings (rule: ''
        ${ruleToLua rule}
      '')
      cfg.rules
    }

    ${cfg.extraConfig}
  '';

    validatedConfig = pkgs.runCommand "config.lua" {
      config = configText;
      passAsFile = [ "config" ];
      buildInputs = [ pkg ];
    } ''
      mkdir -p $TMPDIR/oxwm
      cp $configPath $TMPDIR/oxwm/config.lua
      XDG_CONFIG_HOME=$TMPDIR ${lib.getExe pkg} --validate
      cp $configPath $out
    '';
in {
  options.programs.oxwm = {
    enable = mkEnableOption "oxwm window manager";
    package = mkOption {
      type = types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
      description = "The oxwm package to use";
    };
    extraSessionCommands = mkOption {
      type = types.lines;
      default = "";
      description = "Shell commands executed just before oxwm is started";
    };
    settings = {
      terminal = mkOption {
        type = types.str;
        default = "alacritty";
        description = "Terminal used";
      };
      modkey = mkOption {
        type = types.str;
        default = "Mod4";
        description = "Modifier key. Used for mouse dragging";
      };
      tags = mkOption {
        type = types.listOf types.str;
        default = ["1" "2" "3" "4" "5" "6" "7" "8" "9"];
        description = "Workspace tags";
        example = ["" "󰊯" "" "" "󰙯" "󱇤" "" "󱘶" "󰧮"];
      };
      layoutSymbol = {
        tiling = mkOption {
          type = types.str;
          default = "[T]";
          description = "Symbol in tiling mode";
        };
        normie = mkOption {
          type = types.str;
          default = "[F]";
          description = "Symbol in normie mode";
        };
        tabbed = mkOption {
          type = types.str;
          default = "[=]";
          description = "Symbol in tabbed mode";
        };
      };
      autostart = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "A list of commands to run when oxwm starts";
      };
      binds = mkOption {
        type = types.listOf (types.submodule {
          options = {
            mods = mkOption {
              type = types.listOf types.str;
              default = ["${cfg.modkey}"];
              description = "The modifier keys to invoke the command";
            };
            key = mkOption {
              type = types.str;
              description = "The keystroke to invoke the command";
            };
            action = mkOption {
              type = types.str;
              description = "The command to invoke";
            };
          };
        });
        default = [];
        description = "The list of keybinds";
        example = ''
          [
            {
              mods = [ "Mod4" "Shift" ];
              key = "Slash";
              action = "oxwm.show_keybinds()";
            }
            {
              mods = [ "Mod4" ];
              key = "D";
              action = "oxwm.spawn({ "sh", "-c", "dmenu_run -l 10" })";
            }
          ];
        '';
      };
      chords = mkOption {
        type = types.listOf (types.submodule {
          options = {
            notes = mkOption {
              type = types.listOf (types.submodule {
                options = {
                  mods = mkOption {
                    type = types.listOf types.str;
                    default = [];
                  };
                  key = mkOption {type = types.str;};
                };
              });
            };
            action = mkOption {type = types.str;};
          };
        });
        default = [];
        description = "A list of key chords for OXWM to use";
        example = ''
          [
            {
              notes = [
                {
                  mods = [ "Mod4" ];
                  key = "Space";
                }
                {
                  mods = [];
                  key = "T";
                }
              ];
              action = "oxwm.spawn_terminal()";
            }
          ];
        '';
      };
      border = {
        width = mkOption {
          type = types.int;
          default = 2;
          description = "Width of the window borders";
        };
        focusedColor = mkOption {
          type = types.str;
          default = "6dade3";
          description = "Color of the focused window";
        };
        unfocusedColor = mkOption {
          type = types.str;
          default = "bbbbbb";
          description = "Color of the unfocused window";
        };
      };
      gaps = {
        smart = mkOption {
          type = types.bool;
          default = true;
          description = "If enabled, removes border if single window in tag";
        };
        inner = mkOption {
          type = types.listOf types.int;
          default = [5 5];
          description = "Inner gaps [ horizontal vertical ] in pixels";
        };
        outer = mkOption {
          type = types.listOf types.int;
          default = [5 5];
          description = "Outer gaps [ horizontal vertical ] in pixels";
        };
      };
      bar = {
        font = mkOption {
          type = types.str;
          default = "monospace 10";
          description = "The font displayed on the bar";
        };
        hideVacantTags = mkOption {
          type = types.bool;
          default = false;
          description = "Whether to hide tags with no windows from the bar";
        };
        showTitle = mkOption {
          type = types.bool;
          default = false;
          description = "Show the focused window title centered in the bar";
        };
        maxTitleLength = mkOption {
          type = types.int;
          default = 80;
          description = "Maximum title length in characters (0 = no truncation)";
        };
        unoccupiedScheme = mkOption {
          type = types.listOf types.str;
          default = ["bbbbbb" "1a1b26" "444444"];
          description = "The colorscheme to use for unoccupied tags as hex colors. Do not put a `#` before each color.";
        };
        occupiedScheme = mkOption {
          type = types.listOf types.str;
          default = ["0db9d7" "1a1b26" "0db9d7"];
          description = "The colorscheme to use for occupied tags as hex colors. Do not put a `#` before each color.";
        };
        selectedScheme = mkOption {
          type = types.listOf types.str;
          default = ["0db9d7" "1a1b26" "ad8ee6"];
          description = "The colorscheme to use for selected tags as hex colors. Do not put a `#` before each color.";
        };
        urgentScheme = mkOption {
          type = types.listOf types.str;
          default = ["f7768e" "1a1b26" "f7768e"];
          description = "The colorscheme to use for tags with a window requesting attention as hex colors. Do not put a `#` before each color.";
        };
        blocks = mkOption {
          type = types.listOf (types.submodule {
            options = {
              kind = mkOption {
                type = types.enum ["ram" "static" "shell" "datetime" "battery"];
                default = "static";
                description = "The kind of block to be used";
              };
              interval = mkOption {
                type = types.int;
                default = 5;
              };
              color = mkOption {
                type = types.str;
                default = "";
              };
              bg = mkOption {
                type = types.str;
                default = "";
                description = "Optional background color for the block (hex without #). Empty means no background.";
              };
              underline = mkOption {
                type = types.bool;
                default = true;
              };
              text = mkOption {
                type = types.str;
                default = "|";
              };
              format = mkOption {
                type = types.str;
                default = "{}";
              };
              command = mkOption {
                type = types.str;
                default = "uname -r";
              };
              date_format = mkOption {
                type = types.str;
                default = "%a, %b %d - %-I:%M %P";
              };
              charging = mkOption {
                type = types.str;
                default = "⚡ Bat: {}%";
              };
              discharging = mkOption {
                type = types.str;
                default = "- Bat: {}%";
              };
              full = mkOption {
                type = types.str;
                default = "✓ Bat: {}%";
              };
            };
          });
          description = "The modules to put on the bar";
          example = ''
            [
              {
                kind = "ram";
                interval = 5;
                format = "Ram: {used}/{total} GB";
                color = "9ece6a";
              }
              {
                kind = "static";
                text = "|";
                interval = 99999999;
                color = "6dade3";
              }
              {
                kind = "shell";
                format = "{}";
                command = "uname -r";
                interval = 9999999;
                color = "f7768e";
                underline = true;
              }
            ];
          '';
        };
      };
      rules = mkOption {
        type = types.listOf (types.submodule {
          options = {
            match = {
              class = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = "The class to match windows with";
              };
              instance = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = "The instance to match windows with";
              };
              title = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = "The title to match windows with";
              };
              role = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = "The role to match windows with";
              };
            };
            floating = mkOption {
              type = types.nullOr types.bool;
              default = null;
              description = "Whether to apply floating to the matched window";
            };
            tag = mkOption {
              type = types.nullOr types.int;
              default = null;
              description = "What tag the matched window should be opened on";
            };
            fullscreen = mkOption {
              type = types.nullOr types.bool;
              default = null;
              description = "Whether to apply fullscreen to the matched window";
            };
            focus = mkOption {
              type = types.nullOr types.bool;
              default = null;
              description = "Whether to apply focus to the matched window";
            };
          };
        });
        description = "A list of window rules for the window manager to follow";
        example = ''
          [
            {
              match.class = "gimp";
              floating = true;
            }
            {
              match.class = "firefox";
              match.title = "Library";
              tag = 9;
              focus = true;
            }
          ];
        '';
      };
      extraConfig = mkOption {
        type = types.lines;
        default = "";
        description = "Extra lua confguration that gets inserted at the bottom of the file";
      };
    };
  };

  config = mkIf config.programs.oxwm.enable {
      xdg.configFile."oxwm/config.lua".source = validatedConfig;
  };
}
