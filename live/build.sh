#!/bin/zsh
# Build JustType.app, signed with the "JustType Local Signing" keychain identity when present.
set -e
cd "$(dirname $0)"
APP=build/JustType.app
  swift build -c release 2>&1 | grep -E "error|warning: unre|Compiling|Build" | grep -v "^$" || true
  mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
  cp .build/release/JustType $APP/Contents/MacOS/JustType
  cat > $APP/Contents/Info.plist <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.justtype</string>
<key>CFBundleName</key><string>JustType</string>
<key>CFBundleExecutable</key><string>JustType</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PL
  # stable self-signed identity keeps macOS permissions across rebuilds; falls back to ad-hoc
  SIGN=$(security find-identity -p codesigning 2>/dev/null | awk '/JustType Local Signing/ {print $2; exit}')
  codesign --force --sign "${SIGN:--}" --identifier local.justtype $APP
