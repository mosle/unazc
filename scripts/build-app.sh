#!/bin/sh
# Builds build/Unazc.app, signs it with the fixed "Unazc Dev" identity, and links the models.
set -eu
cd "$(dirname "$0")/.."
swift build -c release
APP=build/Unazc.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Unazc "$APP/Contents/MacOS/Unazc"
# whisper.cpp is a dynamic framework; the binary finds it via @executable_path/../Frameworks.
mkdir -p "$APP/Contents/Frameworks"
cp -R .build/release/whisper.framework "$APP/Contents/Frameworks/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
mkdir -p "$APP/Contents/Resources/backchannel"
cp Resources/backchannel/*.wav "$APP/Contents/Resources/backchannel/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>io.github.mosle.unazc</string>
  <key>CFBundleName</key><string>Unazc</string>
  <key>CFBundleExecutable</key><string>Unazc</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>話した内容を文字にするためにマイクを使います。</string>
</dict>
</plist>
PLIST
if HASH=$(sh scripts/identity.sh); then
  SIGN=$HASH
else
  echo "warning: signing ad-hoc (permissions reset every build). Fix the identity above." >&2
  SIGN=-
fi
# Inside out: the embedded framework first, then the app that seals it.
codesign --force --sign "$SIGN" "$APP/Contents/Frameworks/whisper.framework"
codesign --force --sign "$SIGN" "$APP"
# The models live in Application Support, not in the checkout: a checkout under ~/Desktop or
# ~/Documents is privacy-protected, and the app may be denied reading it (it then cannot load any
# model). The checkout keeps models/ as a link so fetch-deps.sh and the CLI work unchanged.
SUPPORT="$HOME/Library/Application Support/Unazc"
mkdir -p "$SUPPORT"
if [ -L models ] && [ "$(readlink models)" != "$SUPPORT/models" ]; then
  echo "error: models/ links to $(readlink models), not $SUPPORT/models; fix it by hand" >&2
  exit 1
fi
# Older builds linked Application Support to the checkout; undo that before moving.
if [ -L "$SUPPORT/models" ]; then
  if [ "$(readlink "$SUPPORT/models")" != "$PWD/models" ]; then
    echo "error: $SUPPORT/models links to $(readlink "$SUPPORT/models"); fix it by hand" >&2
    exit 1
  fi
  rm "$SUPPORT/models"
fi
if [ -d models ] && [ ! -L models ]; then
  if [ -e "$SUPPORT/models" ]; then
    echo "error: both models/ and $SUPPORT/models exist; merge them into the latter and delete models/" >&2
    exit 1
  fi
  mv models "$SUPPORT/models"
fi
mkdir -p "$SUPPORT/models"
[ -L models ] || ln -s "$SUPPORT/models" models
echo "built $APP"
