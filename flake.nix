{
  description = "oxwm - A dynamic window manager.";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };
  outputs = {
    self,
    nixpkgs,
  }: let
    systems = ["x86_64-linux" "aarch64-linux"];

    forAllSystems = fn: nixpkgs.lib.genAttrs systems (system: fn nixpkgs.legacyPackages.${system});
  in {
    packages = forAllSystems (pkgs: rec {
      default = pkgs.callPackage ./default.nix {
        # use git rev for non tagged releases
        gitRev = self.rev or self.dirtyRev or null;
      };
      oxwm = default;
    });

    devShells = forAllSystems (pkgs: {
      default = pkgs.mkShell {
        inputsFrom = [self.packages.${pkgs.stdenv.hostPlatform.system}.oxwm];
        packages = [
          pkgs.zls
          pkgs.zon2nix
          pkgs.alacritty
          pkgs.xorg-server
        ];
        shellHook = ''
          export PS1="(oxwm-dev) $PS1"
        '';
      };
    });

    formatter = forAllSystems (pkgs: pkgs.alejandra);

    nixosModules.default = {
      config,
      lib,
      pkgs,
      ...
    }: let
      inherit (lib) mkEnableOption mkOption mkIf types;
      cfg = config.services.xserver.windowManager.oxwm;
    in {
      options.services.xserver.windowManager.oxwm = {
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
      };

      config = mkIf cfg.enable {
        services.xserver.windowManager.session = lib.singleton {
          name = "oxwm";
          start = ''
            ${cfg.extraSessionCommands}
            export _JAVA_AWT_WM_NONREPARENTING=1
            ${cfg.package}/bin/oxwm &
            waitPID=$!
          '';
        };

        environment.systemPackages = [
          cfg.package
        ];

        environment.pathsToLink = [
          "/share/oxwm"
          "/share/xsessions"
        ];
      };
    };

    homeManagerModules.default = import ./hm.nix {inherit self;};
  };
}
