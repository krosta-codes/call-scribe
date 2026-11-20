#!/bin/zsh
# Builds CallScribe.app into ~/Applications and restarts it.
set -e
cd "$(dirname "$0")"
APP="$HOME/Applications/CallScribe.app"
VERSION="$(cat VERSION)"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Icon: phone handset + waveform into text lines, source in ~/Projects/apps/app-icons/glyphs/callscribe.swift
[[ -f AppIcon.icns ]] || ~/Projects/apps/app-icons/make.sh callscribe AppIcon.icns
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp process_call.sh "$APP/Contents/Resources/process_call.sh"
swiftc -O -swift-version 5 -target arm64-apple-macos14.2 main.swift -o "$APP/Contents/MacOS/CallScribe"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.jurekkrosta.callscribe</string>
<key>CFBundleName</key><string>CallScribe</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleExecutable</key><string>CallScribe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CSRepo</key><string>krosta-codes/call-scribe</string>
<key>CSSourceDir</key><string>$PWD</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>14.2</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSMicrophoneUsageDescription</key><string>CallScribe records your side of a call, only after you confirm.</string>
<key>NSAudioCaptureUsageDescription</key><string>CallScribe records the other side of a WhatsApp call, only after you confirm.</string>
</dict></plist>
PLIST
# Stable certificate identity keeps TCC grants (microphone, audio capture) across rebuilds.
# Any certificate whose name ends in "Local Code Signing" (README, Install), or set CALLSCRIBE_SIGN_IDENTITY.
SIGN_NAME="${CALLSCRIBE_SIGN_IDENTITY:-Local Code Signing}"
SIGN_ID="$(security find-identity -p codesigning 2>/dev/null | grep -F "$SIGN_NAME\"" | awk '{print $2; exit}')"
codesign --force --sign "${SIGN_ID:--}" "$APP"
[[ "${1:-}" == "--no-run" ]] && exit 0
pkill -x CallScribe || true
sleep 0.5
open "$APP"
