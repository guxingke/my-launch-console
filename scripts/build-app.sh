#!/bin/zsh
# Builds the SwiftPM executable and wraps it in a minimal, signed .app bundle
# (Apple Development identity if one is in the keychain, otherwise ad-hoc).
#   scripts/build-app.sh            # debug build
#   CONFIG=release scripts/build-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=${CONFIG:-debug}
swift build -c "$CONFIG"
BIN_DIR=$(swift build -c "$CONFIG" --show-bin-path)

APP=build/LaunchConsole.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/LaunchConsole" "$APP/Contents/MacOS/LaunchConsole"
# Regenerate with scripts/make-icon.sh after changing scripts/make-icon.swift.
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>LaunchConsole</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>local.prototype.launchconsole</string>
	<key>CFBundleName</key>
	<string>launchd Console</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST

# Signing identity: $SIGN_IDENTITY, else the first "Apple Development" cert in the
# keychain (a free Personal Team works), else ad-hoc. SIGN_IDENTITY=- forces ad-hoc.
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  SIGN_IDENTITY=$(security find-identity -v -p codesigning \
    | awk -F'"' '/Apple Development/ {print $2; exit}')
fi
SIGN_IDENTITY=${SIGN_IDENTITY:--}
codesign --force --timestamp=none --sign "$SIGN_IDENTITY" "$APP" >/dev/null
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  echo "signed ad-hoc (no Apple Development identity, or SIGN_IDENTITY=-)" >&2
else
  echo "signed with: $SIGN_IDENTITY" >&2
fi
echo "$PWD/$APP"
