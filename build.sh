#!/bin/sh
# Builds TopNotes.app and installs it to ~/Applications.
set -e
cd "$(dirname "$0")"

APP=build/TopNotes.app
rm -rf build
mkdir -p "$APP/Contents/MacOS"

swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macosx14.0 \
  *.swift -o "$APP/Contents/MacOS/TopNotes"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Top Notes</string>
  <key>CFBundleIdentifier</key><string>dev.barq.topnotes</string>
  <key>CFBundleExecutable</key><string>TopNotes</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
EOF

codesign --force -s - "$APP"

mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/TopNotes.app"
cp -R "$APP" "$HOME/Applications/"
echo "Installed to ~/Applications/TopNotes.app"
