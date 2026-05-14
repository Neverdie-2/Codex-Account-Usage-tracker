#!/bin/sh
set -eu

swift build -c release

APP_DIR=".build/Codex Account Tracker.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
mkdir -p "$CONTENTS_DIR/Resources"
cp ".build/release/CodexAccountTracker" "$MACOS_DIR/CodexAccountTracker"
if [ -f "Assets/AppIcon.icns" ]; then
    cp "Assets/AppIcon.icns" "$CONTENTS_DIR/Resources/AppIcon.icns"
fi

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>CodexAccountTracker</string>
    <key>CFBundleIdentifier</key>
    <string>private.codex-account-tracker</string>
    <key>CFBundleName</key>
    <string>Codex Account Tracker</string>
    <key>CFBundleDisplayName</key>
    <string>Codex Account Tracker</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>2</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

printf 'APPL????' > "$CONTENTS_DIR/PkgInfo"

DIST_DIR="dist"
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"
(
    cd .build
    ditto -c -k --keepParent "Codex Account Tracker.app" "../$DIST_DIR/Codex Account Tracker.app.zip"
)

echo "$APP_DIR"
echo "$DIST_DIR/Codex Account Tracker.app.zip"
