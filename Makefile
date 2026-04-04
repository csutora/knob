.PHONY: build bundle install uninstall clean dist test test-stop

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
	@VERSION=$$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' Sources/knob/main.swift | head -1); \
	tar -czf "knob-$$VERSION.tar.gz" -C dist knob.app knob-driver.driver knob-ipc -C ../Resources com.csutora.knob.plist com.csutora.knob.ipc.plist; \
	echo "Built dist/ and knob-$$VERSION.tar.gz"; \
	shasum -a 256 "knob-$$VERSION.tar.gz"

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

test: release
	@# Stop nix-managed knob
	-launchctl bootout gui/$$(id -u)/com.csutora.knob 2>/dev/null
	-sudo launchctl bootout system/com.csutora.knob.ipc 2>/dev/null
	@# Install everything (driver, IPC helper, app, CLI)
	sudo mkdir -p /Library/Audio/Plug-Ins/HAL
	sudo rm -rf /Library/Audio/Plug-Ins/HAL/knob-driver.driver
	sudo cp -R .build/release/knob-driver.driver /Library/Audio/Plug-Ins/HAL/knob-driver.driver
	sudo cp .build/release/knob-ipc /Library/Audio/Plug-Ins/HAL/knob-ipc
	sudo cp Resources/com.csutora.knob.ipc.plist /Library/LaunchDaemons/com.csutora.knob.ipc.plist
	sudo launchctl bootstrap system /Library/LaunchDaemons/com.csutora.knob.ipc.plist
	sudo killall -9 coreaudiod 2>/dev/null || true
	@sleep 2
	@# Launch daemon in foreground so logs go to terminal
	.build/release/knob.app/Contents/MacOS/knobd

test-stop:
	@# Stop local test daemon and restore nix-managed version
	-pkill -x knobd 2>/dev/null
	@echo "Run darwin-rebuild switch to restore nix-managed knob."

clean:
	swift package clean
	rm -rf .build/debug/knob.app .build/release/knob.app
	rm -rf .build/debug/knob-driver.driver .build/release/knob-driver.driver
