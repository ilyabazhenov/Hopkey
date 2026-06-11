#!/usr/bin/env bash
set -euo pipefail

# Собирает release-бинарник через SwiftPM и упаковывает его в .app-бандл
# с нужным Info.plist (LSUIElement, bundle id), затем ad-hoc подписывает.

APP_NAME="Hopkey"
DISPLAY_NAME="Hopkey"
BUNDLE_ID="com.local.hopkey"
# Версия берётся из файла VERSION в корне (единственный источник правды).
# Можно переопределить через env: VERSION=1.2.3 ./build.sh — удобно для проб.
VERSION="${VERSION:-$(cat "$(dirname "$0")/VERSION" 2>/dev/null || echo 0.0.0)}"
APP_ICON="Assets/AppIcon.icns"
MENU_BAR_ICON="Assets/MenuBarIcon.pdf"

cd "$(dirname "$0")"

echo "==> Сборка release-бинарника…"
swift build -c release --product "${APP_NAME}"

BIN_DIR="$(swift build -c release --product "${APP_NAME}" --show-bin-path)"
BIN_PATH="${BIN_DIR}/${APP_NAME}"

APP_DIR="build/${APP_NAME}.app"
MACOS_DIR="${APP_DIR}/Contents/MacOS"
RES_DIR="${APP_DIR}/Contents/Resources"
FRAMEWORKS_DIR="${APP_DIR}/Contents/Frameworks"

echo "==> Сборка бандла ${APP_DIR}…"
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RES_DIR}" "${FRAMEWORKS_DIR}"
cp "${BIN_PATH}" "${MACOS_DIR}/${APP_NAME}"
cp "${APP_ICON}" "${RES_DIR}/AppIcon.icns"
cp "${MENU_BAR_ICON}" "${RES_DIR}/MenuBarIcon.pdf"

# Локализация. SwiftPM компилирует строки (en/ru) в ресурс-бандл таргета
# Hopkey_Hopkey.bundle рядом с бинарником, как плоский набор .lproj. Кладём эти
# .lproj прямо в Contents/Resources — штатное место локализации macOS, откуда их
# находит Bundle.main (см. L(_:) в Localization.swift). Сам Hopkey_Hopkey.bundle
# в .app НЕ копируем: его аксессор Bundle.module ждёт бандл в корне .app, что
# ломает codesign ("unsealed contents present in the bundle root").
RES_BUNDLE="${BIN_DIR}/${APP_NAME}_${APP_NAME}.bundle"
if [ -d "${RES_BUNDLE}" ] && ls -d "${RES_BUNDLE}"/*.lproj >/dev/null 2>&1; then
    cp -R "${RES_BUNDLE}"/*.lproj "${RES_DIR}/"
else
    echo "(!) .lproj не найдены в ${RES_BUNDLE} — локализация в .app работать не будет"
fi

# Встраивание Sparkle. SwiftPM (в отличие от Xcode) не копирует Sparkle.framework
# в бандл — делаем это вручную: копируем фреймворк (ditto сохраняет симлинки
# Versions/) и добавляем rpath, чтобы бинарник нашёл его внутри .app на любой машине.
SPARKLE_FW="${BIN_DIR}/Sparkle.framework"
if [ -d "${SPARKLE_FW}" ]; then
    echo "==> Встраивание Sparkle.framework…"
    ditto "${SPARKLE_FW}" "${FRAMEWORKS_DIR}/Sparkle.framework"
    install_name_tool -add_rpath "@executable_path/../Frameworks" "${MACOS_DIR}/${APP_NAME}" 2>/dev/null || true
else
    echo "(!) Sparkle.framework не найден в ${BIN_DIR} — автообновление работать не будет"
fi

cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>${DISPLAY_NAME}</string>
    <key>CFBundleDisplayName</key>     <string>${DISPLAY_NAME}</string>
    <key>CFBundleDevelopmentRegion</key> <string>en</string>
    <!-- Доступные локализации: macOS выбирает язык приложения по списку
         предпочитаемых языков пользователя (en — фолбэк). -->
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>ru</string>
    </array>
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
    <!-- Sparkle: фид обновлений и публичный EdDSA-ключ для проверки подписи. -->
    <key>SUFeedURL</key>               <string>https://raw.githubusercontent.com/ilyabazhenov/Hopkey/main/appcast.xml</string>
    <key>SUPublicEDKey</key>           <string>WPYI42Z1jbfBdFNmyBey6tOcbWyU1x6GGVlmn/nNY/I=</string>
</dict>
</plist>
PLIST

# Подпись. Если есть стабильный self-signed сертификат "Hopkey Dev" (см.
# setup-signing.sh), подписываем им — тогда разрешение Accessibility переживает
# пересборки, а Sparkle принимает обновление (совпадение идентичности подписи).
# Иначе откатываемся на ad-hoc (доверие слетает при каждой сборке).
SIGN_ID="Hopkey Dev"
if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "${SIGN_ID}"; then
    echo "==> Сертификат «${SIGN_ID}» не найден — ad-hoc подпись (запустите ./setup-signing.sh)…"
    SIGN_ID="-"
fi

# Подписываем строго изнутри наружу: вложенные хелперы Sparkle, затем сам
# фреймворк, и только потом приложение (--deep некорректно пере-подписывает
# вложенные XPC-сервисы, поэтому каждый компонент подписываем явно).
sign() { codesign --force --timestamp=none --sign "${SIGN_ID}" "$1"; }

EMBEDDED_FW="${FRAMEWORKS_DIR}/Sparkle.framework"
if [ -d "${EMBEDDED_FW}" ]; then
    echo "==> Подпись компонентов Sparkle сертификатом «${SIGN_ID}»…"
    FW_V="${EMBEDDED_FW}/Versions/B"
    sign "${FW_V}/XPCServices/Downloader.xpc"
    sign "${FW_V}/XPCServices/Installer.xpc"
    sign "${FW_V}/Updater.app"
    sign "${FW_V}/Autoupdate"
    sign "${FW_V}"
fi

echo "==> Подпись приложения сертификатом «${SIGN_ID}»…"
sign "${APP_DIR}"

echo ""
echo "✅ Готово: ${APP_DIR}"
echo "   Запуск:    open \"${APP_DIR}\""
echo "   Установка: cp -R \"${APP_DIR}\" /Applications/"
echo "   Если macOS блокирует (скачанный/самоподписанный бандл) — снимите карантин:"
echo "     xattr -dr com.apple.quarantine /Applications/Hopkey.app"
