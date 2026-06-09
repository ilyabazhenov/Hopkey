#!/usr/bin/env bash
set -euo pipefail

# Собирает release-бинарник через SwiftPM и упаковывает его в .app-бандл
# с нужным Info.plist (LSUIElement, bundle id), затем ad-hoc подписывает.

APP_NAME="Hopkey"
DISPLAY_NAME="Hopkey"
BUNDLE_ID="com.local.hopkey"
VERSION="1.0.0"
APP_ICON="Assets/AppIcon.icns"

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
cp "${APP_ICON}" "${RES_DIR}/AppIcon.icns"

cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>${DISPLAY_NAME}</string>
    <key>CFBundleDisplayName</key>     <string>${DISPLAY_NAME}</string>
    <key>CFBundleExecutable</key>      <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>      <string>${BUNDLE_ID}</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
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

# Подпись. Если есть стабильный self-signed сертификат "Hopkey Dev" (см.
# setup-signing.sh), подписываем им — тогда разрешение Accessibility переживает
# пересборки. Иначе откатываемся на ad-hoc (доверие слетает при каждой сборке).
SIGN_ID="Hopkey Dev"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "${SIGN_ID}"; then
    echo "==> Подпись сертификатом «${SIGN_ID}»…"
    codesign --force --deep --sign "${SIGN_ID}" "${APP_DIR}"
else
    echo "==> Ad-hoc подпись (для постоянного Accessibility запустите ./setup-signing.sh)…"
    codesign --force --deep --sign - "${APP_DIR}" 2>/dev/null || \
        echo "(!) codesign пропущен — приложение всё равно запустится"
fi

echo ""
echo "✅ Готово: ${APP_DIR}"
echo "   Запуск:    open \"${APP_DIR}\""
echo "   Установка: cp -R \"${APP_DIR}\" /Applications/"
