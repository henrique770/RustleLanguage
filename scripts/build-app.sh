#!/usr/bin/env bash
# Build the Swift client and wrap it in RustleLanguage.app so macOS can grant it the Microphone
# and Speech Recognition permissions.
# Signs with "RustleLanguage Local Signing" (scripts/create-signing-cert.sh) when present, so the
# permissions survive rebuilds; falls back to an ad-hoc signature otherwise.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLIENT="$ROOT/client-macos"
APP="$ROOT/build/RustleLanguage.app"
# Assembled and signed outside the checkout: in an iCloud-synced folder (Documents, Desktop) the
# File Provider re-adds Finder info to the bundle, which codesign rejects ("detritus not allowed").
STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGE_DIR"' EXIT
STAGE="$STAGE_DIR/RustleLanguage.app"

swift build -c release --package-path "$CLIENT"
BIN="$(swift build -c release --package-path "$CLIENT" --show-bin-path)/RustleLanguage"

mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BIN" "$STAGE/Contents/MacOS/RustleLanguage"
# Figtree + EB Garamond (SIL OFL), registered through ATSApplicationFontsPath.
cp -R "$CLIENT/Resources/Fonts" "$STAGE/Contents/Resources/Fonts"
# Same mark as the sidebar logo (regenerate with scripts/make-icon.sh).
cp "$CLIENT/Resources/AppIcon.icns" "$STAGE/Contents/Resources/AppIcon.icns"
cat > "$STAGE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.rustlelanguage.client</string>
  <key>CFBundleName</key><string>RustleLanguage</string>
  <key>CFBundleDisplayName</key><string>Rustle Language</string>
  <key>CFBundleExecutable</key><string>RustleLanguage</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>ATSApplicationFontsPath</key><string>Fonts</string>
  <key>NSMicrophoneUsageDescription</key><string>O Rustle Language ouve você nas conversas com o tutor e nas leituras em voz alta.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>O reconhecimento de fala mostra legendas enquanto você fala e acompanha sua leitura, como num karaokê.</string>
</dict>
</plist>
PLIST

# The app starts the server from this checkout, so it keeps working when copied to /Applications.
/usr/libexec/PlistBuddy -c "Add :RustleLanguageServerScript string $ROOT/scripts/run-server.sh" "$STAGE/Contents/Info.plist"

xattr -cr "$STAGE"
IDENTITY="$(security find-identity -p codesigning 2>/dev/null | awk '/"RustleLanguage Local Signing"/ {print $2; exit}')"
if [ -n "$IDENTITY" ]; then
  codesign --force --sign "$IDENTITY" --identifier dev.rustlelanguage.client "$STAGE"
  echo "Signed with RustleLanguage Local Signing ($IDENTITY)"
else
  codesign --force --sign - "$STAGE"
  echo "Signed ad-hoc (run scripts/create-signing-cert.sh for stable permissions)"
fi
rm -rf "$APP"
mkdir -p "$(dirname "$APP")"
ditto "$STAGE" "$APP"
echo "Built $APP"
