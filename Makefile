.PHONY: build bundle install uninstall clean dist

# Force Xcode toolchain — nix sets SDKROOT/DEVELOPER_DIR to a nix SDK
# that's incompatible with the system Swift compiler.
export DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer
export SDKROOT := $(DEVELOPER_DIR)/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk

build:
	swift build

bundle: build
	./scripts/bundle.sh debug
	./scripts/bundle-driver.sh debug

release:
	swift build -c release
	./scripts/bundle.sh release
	./scripts/bundle-driver.sh release
	codesign --force --sign "$${CODESIGN_IDENTITY:--}" .build/release/knob-ipc

dist: release
	@if [ -z "$$CODESIGN_IDENTITY" ]; then \
		echo "error: CODESIGN_IDENTITY not set — production builds require signing"; \
		echo "hint: plug in YubiKey and enter the devShell (direnv allow)"; \
		exit 1; \
	fi
	rm -rf dist
	mkdir -p dist
	cp -R .build/release/knob.app dist/
	cp -R .build/release/knob-driver.driver dist/
	cp .build/release/knob-ipc dist/knob-ipc
	@echo "Built dist/ — commit this directory"

install: release
	mkdir -p /usr/local/bin ~/Applications ~/Library/LaunchAgents
	rm -rf ~/Applications/knob.app
	cp -R .build/release/knob.app ~/Applications/knob.app
	ln -sf ~/Applications/knob.app/Contents/MacOS/knob /usr/local/bin/knob
	cp Resources/com.csutora.knob.plist ~/Library/LaunchAgents/com.csutora.knob.plist
	sed -i '' 's|__HOME__|$(HOME)|' ~/Library/LaunchAgents/com.csutora.knob.plist
	sudo mkdir -p /Library/Audio/Plug-Ins/HAL
	sudo rm -rf /Library/Audio/Plug-Ins/HAL/knob-driver.driver
	sudo cp -R .build/release/knob-driver.driver /Library/Audio/Plug-Ins/HAL/knob-driver.driver
	sudo cp .build/release/knob-ipc /Library/Audio/Plug-Ins/HAL/knob-ipc
	sudo cp Resources/com.csutora.knob.ipc.plist /Library/LaunchDaemons/com.csutora.knob.ipc.plist
	sudo launchctl bootout system/com.csutora.knob.ipc 2>/dev/null || true
	sudo launchctl bootstrap system /Library/LaunchDaemons/com.csutora.knob.ipc.plist
	sudo launchctl kickstart -k system/com.apple.audio.coreaudiod
	@echo "Installed. Run: open ~/Applications/knob.app"
	@echo "Then: launchctl load ~/Library/LaunchAgents/com.csutora.knob.plist"

uninstall:
	-launchctl unload ~/Library/LaunchAgents/com.csutora.knob.plist 2>/dev/null
	rm -f /usr/local/bin/knob  # symlink
	rm -rf ~/Applications/knob.app
	rm -f ~/Library/LaunchAgents/com.csutora.knob.plist
	-sudo launchctl bootout system/com.csutora.knob.ipc 2>/dev/null
	-sudo rm -f /Library/LaunchDaemons/com.csutora.knob.ipc.plist
	-sudo rm -f /Library/Audio/Plug-Ins/HAL/knob-ipc
	-sudo rm -rf /Library/Audio/Plug-Ins/HAL/knob-driver.driver
	-sudo launchctl kickstart -k system/com.apple.audio.coreaudiod 2>/dev/null
	@echo "Uninstalled."

clean:
	swift package clean
	rm -rf .build/debug/knob.app .build/release/knob.app
	rm -rf .build/debug/knob-driver.driver .build/release/knob-driver.driver
