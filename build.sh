#!/usr/bin/env bash
set -euo pipefail

# Собирает release-бинарник через SwiftPM и упаковывает его в .app-бандл
# с нужным Info.plist (LSUIElement, bundle id), затем ad-hoc подписывает.

APP_NAME="Hopkey"
DISPLAY_NAME="Hopkey"
BUNDLE_ID="com.local.hopkey"
VERSION="1.0.0"

cd "$(dirname "$0")"

echo "==> Сборка release-бинарника…"
swift build -c release --product "${APP_NAME}"

BIN_DIR="$(swift build -c release --product "${APP_NAME}" --show-bin-path)"
BIN_PATH="${BIN_DIR}/${APP_NAME}"

APP_DIR="build/${APP_NAME}.app"
MACOS_DIR="${APP_DIR}/Contents/MacOS"
RES_DIR="${APP_DIR}/Contents/Resources"

echo "==> Сборка бандла ${APP_DIR}…"
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RES_DIR}"
cp "${BIN_PATH}" "${MACOS_DIR}/${APP_NAME}"

cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>${DISPLAY_NAME}</string>
    <key>CFBundleDisplayName</key>     <string>${DISPLAY_NAME}</string>
    <key>CFBundleExecutable</key>      <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>      <string>${BUNDLE_ID}</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>${VERSION}</string>
    <key>CFBundleVersion</key>         <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSPrincipalClass</key>        <string>NSApplication</string>
    <key>NSHumanReadableCopyright</key><string>Hopkey</string>
</dict>
</plist>
PLIST

# Ad-hoc подпись: стабильнее работают уведомления и запоминание прав Accessibility.
codesign --force --deep --sign - "${APP_DIR}" 2>/dev/null || \
    echo "(!) codesign пропущен — приложение всё равно запустится"

echo ""
echo "✅ Готово: ${APP_DIR}"
echo "   Запуск:    open \"${APP_DIR}\""
echo "   Установка: cp -R \"${APP_DIR}\" /Applications/"
