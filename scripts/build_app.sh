#!/usr/bin/env bash
# Собирает Transcribator.app (ad-hoc подпись) в ./build
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP_NAME="Transcribator"
BUNDLE_ID="dev.transcribator.app"

echo "==> swift build (release)"
(cd macapp && swift build -c release)

BIN_DIR="$(cd macapp && swift build -c release --show-bin-path)"
BIN="$BIN_DIR/$APP_NAME"

APP="$ROOT/build/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

if [ ! -f assets/AppIcon.icns ]; then
    echo "==> icon (нет assets/AppIcon.icns — генерирую)"
    swift scripts/make_icon.swift assets/AppIcon.icns
fi
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>ru</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Transcribator записывает голос, чтобы превратить его в текст на устройстве.</string>
</dict>
</plist>
PLIST

echo "==> codesign"
# Порядок выбора: Apple Development (стабильная TCC-идентичность) → локальный
# сертификат «Transcribator Dev» → ad-hoc. При ad-hoc разрешения слетают после пересборки.
SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' | head -1)"
if [ -z "$SIGN_ID" ] && security find-identity -v -p codesigning 2>/dev/null | grep -q "Transcribator Dev"; then
    SIGN_ID="Transcribator Dev"
fi
if [ -n "$SIGN_ID" ]; then
    echo "    identity: $SIGN_ID"
    codesign --force --sign "$SIGN_ID" --timestamp=none "$APP" >/dev/null 2>&1 \
        || { echo "    подпись не удалась, откат на ad-hoc"; codesign --force --sign - "$APP"; }
else
    echo "    identity: ad-hoc (разрешения будут слетать после пересборки)"
    codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "    codesign пропущен"
fi

echo
echo "Готово: $APP"
echo "Запуск:  open \"$APP\""
echo "Логи:    \"$APP/Contents/MacOS/$APP_NAME\"  (в терминале)"
