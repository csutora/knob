{
  description = "knob - parametric equalizer and per-app volume control for mac";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      darwinSystems = [ "aarch64-darwin" "x86_64-darwin" ];
      forDarwin = f: nixpkgs.lib.genAttrs darwinSystems (system: f nixpkgs.legacyPackages.${system});

      # Pure packaging of pre-built artifacts.
      # Rebuild with: make dist
      mkKnob = pkgs: pkgs.stdenv.mkDerivation {
        pname = "knob";
        version = "0.1.0";
        src = ./dist;

        dontBuild = true;
        dontConfigure = true;
        dontFixup = true;

        installPhase = ''
          mkdir -p $out/Applications $out/lib $out/bin $out/libexec
          cp -R knob.app $out/Applications/
          cp -R knob-driver.driver $out/lib/
          cp knob-ipc $out/libexec/knob-ipc
          ln -s $out/Applications/knob.app/Contents/MacOS/knob $out/bin/knob
        '';

        meta = {
          description = "System-wide parametric EQ daemon for macOS";
          platforms = darwinSystems;
          mainProgram = "knob";
        };
      };
    in
    {
      packages = forDarwin (pkgs: rec {
        knob = mkKnob pkgs;
        default = knob;
      });

      devShells = forDarwin (pkgs: {
        default = pkgs.mkShell {
          shellHook = ''
            # Check if YubiKey signing identity is available via CryptoTokenKit
            if security export-smartcard 2>/dev/null | grep -q "Developer Signing"; then
              export CODESIGN_IDENTITY="Developer Signing"
            fi
            # Put local release build on PATH for testing
            export PATH="$PWD/.build/release/knob.app/Contents/MacOS:$PATH"
          '';
        };
      });

      darwinModules.default = { config, lib, pkgs, ... }:
        let
          cfg = config.services.knob;
        in
        {
          options.services.knob = {
            enable = lib.mkEnableOption "knob system-wide parametric EQ";

            package = lib.mkOption {
              type = lib.types.package;
              default = self.packages.${pkgs.stdenv.hostPlatform.system}.knob;
              defaultText = lib.literalExpression "inputs.eq.packages.\${system}.knob";
              description = "The knob package to use.";
            };
          };

          config = lib.mkIf cfg.enable {
            system.activationScripts.postActivation.text = lib.mkAfter ''
              # knob: install IPC helper LaunchDaemon
              IPC_SRC="${cfg.package}/libexec/knob-ipc"
              IPC_DST="/Library/Audio/Plug-Ins/HAL/knob-ipc"
              IPC_PLIST="/Library/LaunchDaemons/com.csutora.knob.ipc.plist"
              if ! diff -q "$IPC_SRC" "$IPC_DST" &>/dev/null; then
                echo "installing knob IPC helper..."
                launchctl bootout system/com.csutora.knob.ipc 2>/dev/null || true
                mkdir -p /Library/Audio/Plug-Ins/HAL
                cp "$IPC_SRC" "$IPC_DST"
              fi
              cat > "$IPC_PLIST" << 'EOFPLIST'
              <?xml version="1.0" encoding="UTF-8"?>
              <!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
              <plist version="1.0">
              <dict>
                <key>Label</key>
                <string>com.csutora.knob.ipc</string>
                <key>ProgramArguments</key>
                <array>
                  <string>/Library/Audio/Plug-Ins/HAL/knob-ipc</string>
                </array>
                <key>MachServices</key>
                <dict>
                  <key>com.csutora.knob.ipc</key>
                  <true/>
                </dict>
                <key>RunAtLoad</key>
                <true/>
                <key>KeepAlive</key>
                <true/>
                <key>StandardErrorPath</key>
                <string>/tmp/knob-ipc.stderr.log</string>
                <key>StandardOutPath</key>
                <string>/tmp/knob-ipc.stdout.log</string>
              </dict>
              </plist>
              EOFPLIST
              # Always ensure IPC helper is running — coreaudiod restart (below) disrupts its Mach port
              launchctl bootout system/com.csutora.knob.ipc 2>/dev/null || true
              launchctl bootstrap system "$IPC_PLIST" 2>/dev/null || true

              # knob: always stop the daemon before any updates
              CONSOLE_UID=$(stat -f %u /dev/console 2>/dev/null || echo 501)
              launchctl bootout gui/"$CONSOLE_UID"/com.csutora.knob 2>/dev/null || true
              pkill -x knobd 2>/dev/null || true
              sleep 1

              # knob: install HAL driver (only restart coreaudiod when driver changes)
              mkdir -p /Library/Audio/Plug-Ins/HAL
              DRIVER_SRC="${cfg.package}/lib/knob-driver.driver"
              DRIVER_DST="/Library/Audio/Plug-Ins/HAL/knob-driver.driver"
              if ! diff -rq "$DRIVER_SRC" "$DRIVER_DST" &>/dev/null; then
                echo "installing knob HAL driver..."
                rm -rf "$DRIVER_DST"
                cp -RL "$DRIVER_SRC" "$DRIVER_DST"
                killall -9 coreaudiod 2>/dev/null || true
                sleep 2
              fi

              # knob: re-bootstrap the agent
              CONSOLE_USER=$(id -un "$CONSOLE_UID" 2>/dev/null)
              CONSOLE_HOME=$(dscl . -read "/Users/$CONSOLE_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
              PLIST="$CONSOLE_HOME/Library/LaunchAgents/com.csutora.knob.plist"
              if [ -f "$PLIST" ]; then
                launchctl bootstrap gui/"$CONSOLE_UID" "$PLIST" 2>/dev/null || true
              fi
            '';
          };
        };

      homeModules.default = { config, lib, pkgs, ... }:
        let
          cfg = config.services.knob;
        in
        {
          options.services.knob = {
            enable = lib.mkEnableOption "knob system-wide parametric EQ";

            package = lib.mkOption {
              type = lib.types.package;
              default = self.packages.${pkgs.stdenv.hostPlatform.system}.knob;
              defaultText = lib.literalExpression "inputs.eq.packages.\${system}.knob";
              description = "The knob package to use.";
            };

            enableBashIntegration = (lib.mkEnableOption "knob bash completions") // { default = true; };
            enableZshIntegration = (lib.mkEnableOption "knob zsh completions") // { default = true; };
            enableFishIntegration = lib.mkEnableOption "knob fish completions";
            enableNushellIntegration = lib.mkEnableOption "knob nushell completions";
          };

          config = lib.mkIf cfg.enable (lib.mkMerge [
            {
              home.packages = [ cfg.package ];

              home.file."Applications/knob.app".source =
                "${cfg.package}/Applications/knob.app";

              launchd.agents.knob = {
                enable = true;
                config = {
                  Label = "com.csutora.knob";
                  ProgramArguments = [
                    "${cfg.package}/Applications/knob.app/Contents/MacOS/knobd"
                  ];
                  RunAtLoad = true;
                  KeepAlive = true;
                  ProcessType = "Interactive";
                  StandardOutPath = "/tmp/knob.stdout.log";
                  StandardErrorPath = "/tmp/knob.stderr.log";
                };
              };
            }
            (lib.mkIf cfg.enableBashIntegration {
              programs.bash.initExtra = ''
                eval "$(${cfg.package}/bin/knob completions bash)"
              '';
            })
            (lib.mkIf cfg.enableZshIntegration {
              programs.zsh.initExtra = ''
                eval "$(${cfg.package}/bin/knob completions zsh)"
              '';
            })
            (lib.mkIf cfg.enableFishIntegration {
              programs.fish.interactiveShellInit = ''
                ${cfg.package}/bin/knob completions fish | source
              '';
            })
            (lib.mkIf cfg.enableNushellIntegration {
              programs.nushell.extraConfig = builtins.readFile (pkgs.runCommand "knob-nushell-completions" {} ''
                ${cfg.package}/bin/knob completions nu > $out
              '');
            })
          ]);
        };
    };
}
