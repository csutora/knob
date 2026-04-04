# knob

offers a system-wide 16 band parametric equalizer, per-app volume control, and automatic per-device preset switching. all controlled from your terminal with intuitive command completion!
works seamlessly through a virtual audio device that forwards to your real hardware, so no need to configure apps to use it.
oh, and it uses <1% of a single cpu core with most audio setups, and even when processing 384Khz 32bit stereo with 7 bands, it hovers around 3%.

## installation


### nix (flakes)

add knob to your flake inputs:

```nix
{
    inputs = {
          nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable"; # or whatever you prefer

          nix-darwin = {
              url = "github:nix-darwin/nix-darwin/master";
              inputs.nixpkgs.follows = "nixpkgs";
          };

          home-manager = {
              url = "github:nix-community/home-manager";
              inputs.nixpkgs.follows = "nixpkgs";
          };

          knob = {
              url = "github:csutora/knob";
              inputs.nixpkgs.follows = "nixpkgs";
          };
    };

    outputs = { self, nixpkgs, darwin, home-manager, knob, ... }: {
        darwinConfigurations.your-hostname = darwin.lib.darwinSystem {
            modules = [
                knob.darwinModules.default # coreaudiod HAL driver + IPC helper (system-level)
                home-manager.darwinModules.home-manager
                {
                    home-manager.users.your-username = {
                        imports = [ knob.homeModules.default ]; # daemon + CLI + launchd agent
                    };
                }
            ];
        };
    };
}
```

then in your nix-darwin configuration:

```nix
services.knob.enable = true;
```

and in your home-manager configuration:

```nix
services.knob = {
    enable = true;

    # shell completions, bash and zsh are enabled by default
    enableBashIntegration = true;
    enableZshIntegration = true;
    enableFishIntegration = true;
    enableNushellIntegration = true;
};
```


### homebrew

```
brew tap csutora/knob
brew install --cask knob
```

for completions, add the right snippet to your shell config:

```bash
# bash
eval "$(knob completions bash)"

# zsh
eval "$(knob completions zsh)"

# fish
knob completions fish | source

# nushell
mkdir ($nu.data-dir | path join "vendor/autoload")
knob completions nu | save -f ($nu.data-dir | path join "vendor/autoload/knob.nu")
```


### manual

```bash
git clone https://github.com/csutora/knob
cd knob
make install
```

knob needs to do secure ipc so actually building the thing requires a proper codesigning setup.
for this reason, all the install paths use pre-built binaries found in `/dist`.
if you want to contribute, feel free to send me an email and i'll help you set it up.


## usage

for full usage, see `knob help`, but here are a few examples to get a feel for it:
```bash
# checking status then starting the daemon
knob
knob start

# creating and updating bands with various parameters, peaking with q=1 by default
knob band preamp -2
knob band 300 -3
knob band 300 -2.5
knob band 4khz +2.1db
knob band 6200hz 3.2db 0.63q hs   # highshelf
knob band list

# manipulating presets
knob preset save testing
knob preset list
knob preset load flat

# setting preset to autoload on a device
knob device list
knob device assign AirPods testing

# manipulating app volumes
knob app list
knob app music 0.5
knob app com.apple.Music 0.6
knob app music mute
knob app music unmute

# bypass parts of the audio processing temporarily
knob bypass apps
knob bypass eq

# plot the frequency response curve of the current or a specific preset
knob plot
knob plot testing

# get machine-readable json for scripting, works with all list commands
knob band list -m
```


## known issues

- when switching audio devices, there's a moment when audio is playing directly to the selected device. during this, eq and app-specific volumes aren't applied, which can cause apps with lowered volumes to be normal volume (and therefore too loud) for a split second. i haven't yet found a nice way to fix this, but it shouldn't affect day-to-day usage in most cases

- when switching audio devices, the volume slider jumps around for a bit before settling. this is an artifact of macos restoring incorrect cached device volumes onto knob's audio device. this is purely visual and does not affect the actual audio volume, but it's a bit janky sadly. i haven't found a way to opt out of this macos behavior so i'm unsure if this is fixable at all
