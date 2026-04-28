#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Display Anchor"
EXECUTABLE_NAME="DisplayAnchor"
BUNDLE_ID="com.jeff.DisplayAnchor"
DEFAULT_RELEASE_CODESIGN_IDENTITY="Developer ID Application: Jeffrey Schumann (M2ABUL7722)"
CONFIGURATION="${CONFIGURATION:-release}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_ICONSET_DIR="$ROOT_DIR/Resources/AppIcon.iconset"
APP_ICON_BASENAME="DisplayAnchor"
BUILD_DIR="$ROOT_DIR/.build/$CONFIGURATION"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-}"

resolve_codesign_identity() {
    local requested_identity="$1"

    if [[ -n "$requested_identity" ]]; then
        echo "$requested_identity"
        return
    fi

    if [[ "$CONFIGURATION" == "release" ]]; then
        echo "$DEFAULT_RELEASE_CODESIGN_IDENTITY"
    fi
}

signing_identity_exists() {
    local identity="$1"

    [[ -n "$identity" ]] || return 1

    security find-identity -v -p codesigning 2>/dev/null | awk -F'"' -v identity="$identity" '$2 == identity { found = 1 } END { exit(found ? 0 : 1) }'
}

swift build -c "$CONFIGURATION" --package-path "$ROOT_DIR"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BUILD_DIR/$EXECUTABLE_NAME" "$MACOS_DIR/$EXECUTABLE_NAME"

if [[ ! -d "$APP_ICONSET_DIR" ]]; then
    echo "Missing app icon set at $APP_ICONSET_DIR" >&2
    exit 1
fi

iconutil -c icns "$APP_ICONSET_DIR" -o "$RESOURCES_DIR/$APP_ICON_BASENAME.icns"

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>
    <string>$EXECUTABLE_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleIconFile</key>
    <string>$APP_ICON_BASENAME</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 Jeff.</string>
</dict>
</plist>
PLIST

chmod +x "$MACOS_DIR/$EXECUTABLE_NAME"

RESOLVED_CODESIGN_IDENTITY="$(resolve_codesign_identity "$CODESIGN_IDENTITY")"

if [[ -n "$RESOLVED_CODESIGN_IDENTITY" ]]; then
    if signing_identity_exists "$RESOLVED_CODESIGN_IDENTITY"; then
        codesign --force --sign "$RESOLVED_CODESIGN_IDENTITY" --identifier "$BUNDLE_ID" "$APP_DIR"
        echo "Signed $APP_DIR with identity: $RESOLVED_CODESIGN_IDENTITY"
    else
        echo "Requested signing identity not found: $RESOLVED_CODESIGN_IDENTITY"
        echo "Set CODESIGN_IDENTITY to a valid local certificate to sign this build."
        echo "Continuing without bundle codesign so the project stays buildable on other machines."
    fi
else
    echo "No signing identity configured for CONFIGURATION=$CONFIGURATION."
    echo "Set CODESIGN_IDENTITY to sign this build."
fi

echo "Created $APP_DIR"
