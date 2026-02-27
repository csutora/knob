#!/bin/bash
# Create .app bundle for knob.
# The .app bundle is the primary artifact. Both user-initiated launch (via `open`)
# and launchd run the binary from within this bundle to maintain a consistent CDHash.

set -e

CONFIGURATION="${1:-debug}"
BUILD_DIR=".build/${CONFIGURATION}"
APP_DIR="${BUILD_DIR}/knob.app"
DAEMON="${BUILD_DIR}/knobd"
CLI="${BUILD_DIR}/knob"

if [ ! -f "$DAEMON" ]; then
    echo "Daemon binary not found at $DAEMON"
    echo "Run 'swift build' first (or 'swift build -c release' for release)"
    exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"

cp "$DAEMON" "$APP_DIR/Contents/MacOS/knobd"

if [ -f "$CLI" ]; then
    cp "$CLI" "$APP_DIR/Contents/MacOS/knob"
    codesign --force --sign "${CODESIGN_IDENTITY:--}" "$APP_DIR/Contents/MacOS/knob"
fi

cat > "$APP_DIR/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.csutora.knob</string>
    <key>CFBundleName</key>
    <string>knob</string>
    <key>CFBundleExecutable</key>
    <string>knobd</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
EOF

codesign --force --sign "${CODESIGN_IDENTITY:--}" "$APP_DIR"

echo "Created $APP_DIR"
