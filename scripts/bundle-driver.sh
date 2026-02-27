#!/bin/bash
# Create .driver bundle for the HAL Audio Server Plugin.
# Installed to /Library/Audio/Plug-Ins/HAL/ and loaded by coreaudiod.

set -e

CONFIGURATION="${1:-debug}"
BUILD_DIR=".build/${CONFIGURATION}"
STATIC_LIB="${BUILD_DIR}/libknob-driver.a"
DRIVER_DIR="${BUILD_DIR}/knob-driver.driver"

if [ ! -f "$STATIC_LIB" ]; then
    echo "Driver static lib not found at $STATIC_LIB"
    echo "Run 'swift build' first (or 'swift build -c release' for release)"
    exit 1
fi

rm -rf "$DRIVER_DIR"
mkdir -p "$DRIVER_DIR/Contents/MacOS"

# Link static library as MH_BUNDLE (required by coreaudiod/CFPlugIn).
# SPM builds a static .a; we re-link as a Mach-O bundle here.
xcrun clang -bundle -o "$DRIVER_DIR/Contents/MacOS/knob-driver" \
    -Wl,-all_load "$STATIC_LIB" \
    -framework CoreAudio -framework CoreFoundation -framework Foundation \
    -L /usr/lib/swift \
    -lswiftCore -lswiftCoreAudio -lswiftCoreFoundation \
    -lswiftDarwin -lswiftDispatch -lswiftIOKit -lswiftObjectiveC -lswiftXPC \
    -lobjc

# Factory UUID — unique to this plugin (referenced in CFPlugInFactories and CFPlugInTypes)
FACTORY_UUID="7B4C5E2A-1D3F-4A8B-9E6C-0F2D8B4A7C5E"
# kAudioServerPlugInTypeUUID — all Audio Server Plugins must support this type
TYPE_UUID="443ABAB8-E7B3-491A-B985-BEB9187030DB"

cat > "$DRIVER_DIR/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.csutora.knob.driver</string>
    <key>CFBundleName</key>
    <string>knob-driver</string>
    <key>CFBundleExecutable</key>
    <string>knob-driver</string>
    <key>CFBundlePackageType</key>
    <string>BNDL</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFPlugInFactories</key>
    <dict>
        <key>${FACTORY_UUID}</key>
        <string>knob_driver_create</string>
    </dict>
    <key>CFPlugInTypes</key>
    <dict>
        <key>${TYPE_UUID}</key>
        <array>
            <string>${FACTORY_UUID}</string>
        </array>
    </dict>
    <key>AudioServerPlugIn_MachServices</key>
    <array>
        <string>com.csutora.knob.ipc</string>
    </array>
</dict>
</plist>
EOF

codesign --force --sign "${CODESIGN_IDENTITY:--}" "$DRIVER_DIR"

echo "Created $DRIVER_DIR"
