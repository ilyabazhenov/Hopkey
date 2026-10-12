#!/usr/bin/env bash
set -euo pipefail

# Собирает release-бинарник через SwiftPM и упаковывает его в .app-бандл
# с нужным Info.plist (LSUIElement, bundle id), затем подписывает (Developer ID,
# если он есть в связке ключей; нотаризацию делает release.sh).

APP_NAME="Hopkey"
DISPLAY_NAME="Hopkey"
BUNDLE_ID="${HOPKEY_BUNDLE_ID:-com.local.hopkey}"
# Версия берётся из файла VERSION в корне (единственный источник правды).
# Можно переопределить через env: VERSION=1.2.3 ./build.sh — удобно для проб.
VERSION="${VERSION:-$(cat "$(dirname "$0")/VERSION" 2>/dev/null || echo 0.0.0)}"
APP_ICON="Assets/AppIcon.icns"
MENU_BAR_ICON="Assets/MenuBarIcon.pdf"

cd "$(dirname "$0")"

# Архитектуры. По умолчанию собираем universal-бинарник (arm64 + x86_64), чтобы
# .app запускался и на Apple Silicon, и на Intel. Sparkle.framework уже universal,
# ресурсы архитектурно-независимы — остаётся слить сам бинарник из двух арок (lipo
# делает SwiftPM сам). Для быстрых dev-итераций можно собрать только под текущую
# арку: UNIVERSAL=0 ./build.sh (см. make run/watch).
UNIVERSAL="${UNIVERSAL:-1}"
if [ "${UNIVERSAL}" = "1" ]; then
    ARCH_FLAGS="--arch arm64 --arch x86_64"
    echo "==> Сборка release-бинарника (universal: arm64 + x86_64)…"
else
    ARCH_FLAGS=""
    echo "==> Сборка release-бинарника (только текущая арка)…"
fi

# ARCH_FLAGS намеренно без кавычек — нужно словоделение на отдельные флаги
# (пустая строка раскрывается в ничего).
swift build -c release ${ARCH_FLAGS} --product "${APP_NAME}"

BIN_DIR="$(swift build -c release ${ARCH_FLAGS} --product "${APP_NAME}" --show-bin-path)"
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
# Hopkey_Hopkey.bundle рядом с бинарником. Кладём .lproj прямо в Contents/Resources —
# штатное место локализации macOS, откуда их находит Bundle.main (см. L(_:) в
# Localization.swift). Сам Hopkey_Hopkey.bundle в .app НЕ копируем: его аксессор
# Bundle.module ждёт бандл в корне .app, что ломает codesign ("unsealed contents").
#
# Layout бандла зависит от арки: single-arch кладёт .lproj плоско в корень бандла,
# а universal (--arch …) — в Contents/Resources/ (полноценный бандл macOS). Ищем
# в обоих местах, иначе локализация молча выпадает из universal-сборки.
RES_BUNDLE="${BIN_DIR}/${APP_NAME}_${APP_NAME}.bundle"
LPROJ_SRC=""
if ls -d "${RES_BUNDLE}"/*.lproj >/dev/null 2>&1; then
    LPROJ_SRC="${RES_BUNDLE}"
elif ls -d "${RES_BUNDLE}"/Contents/Resources/*.lproj >/dev/null 2>&1; then
    LPROJ_SRC="${RES_BUNDLE}/Contents/Resources"
fi
if [ -n "${LPROJ_SRC}" ]; then
    cp -R "${LPROJ_SRC}"/*.lproj "${RES_DIR}/"
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

# Подпись. Идентичность (можно задать явно: SIGN_IDENTITY="…" ./build.sh):
#   1. «Developer ID Application: …» — основной путь, им же подписан релиз (его
#      нотаризует release.sh). Team ID стабилен, поэтому Accessibility и доступ к
#      Keychain переживают пересборки и обновления;
#   2. self-signed «Hopkey Dev» (см. setup-signing.sh) — фолбэк для машины без
#      Developer ID; такая сборка не нотаризуется;
#   3. ad-hoc — доверие слетает при каждой сборке.
if [ -z "${SIGN_IDENTITY:-}" ]; then
    IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    SIGN_IDENTITY="$(printf '%s\n' "${IDENTITIES}" \
        | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -n 1)"
    if [ -z "${SIGN_IDENTITY}" ]; then
        if printf '%s\n' "${IDENTITIES}" | grep -q '"Hopkey Dev"'; then
            SIGN_IDENTITY="Hopkey Dev"
        else
            echo "==> Ни Developer ID, ни «Hopkey Dev» не найдены — ad-hoc подпись (см. ./setup-signing.sh)…"
            SIGN_IDENTITY="-"
        fi
    fi
fi

# Hardened runtime включён всегда — он обязателен для нотаризации, и dev-сборка
# так проверяет то же окружение, что получит пользователь. Entitlements не нужны
# только Developer ID: Sparkle переподписан тем же Team ID и грузится под library
# validation. У self-signed/ad-hoc Team ID нет — им отключаем library validation
# (см. Signing/Hopkey-dev.entitlements).
case "${SIGN_IDENTITY}" in
    "Developer ID Application:"*) APP_ENTITLEMENTS=() ;;
    *) APP_ENTITLEMENTS=(--entitlements "Signing/Hopkey-dev.entitlements") ;;
esac

# Защищённый timestamp (SIGN_TIMESTAMP=secure) требует нотаризация — его ставит
# release.sh. Это сетевой запрос на каждый подписываемый компонент, поэтому
# dev-сборки по умолчанию обходятся без него. У ad-hoc timestamp невозможен.
if [ "${SIGN_TIMESTAMP:-none}" = "secure" ] && [ "${SIGN_IDENTITY}" != "-" ]; then
    TIMESTAMP_FLAG="--timestamp"
else
    TIMESTAMP_FLAG="--timestamp=none"
fi

# Подписываем строго изнутри наружу: вложенные хелперы Sparkle, затем сам
# фреймворк, и только потом приложение (порядок из документации Sparkle). --deep
# не используем: он проставил бы entitlements приложения на вложенный код, поэтому
# каждый компонент подписываем явно и без entitlements.
sign() { codesign --force --options runtime "${TIMESTAMP_FLAG}" --sign "${SIGN_IDENTITY}" "$@"; }

EMBEDDED_FW="${FRAMEWORKS_DIR}/Sparkle.framework"
if [ -d "${EMBEDDED_FW}" ]; then
    echo "==> Подпись компонентов Sparkle («${SIGN_IDENTITY}»)…"
    FW_V="${EMBEDDED_FW}/Versions/B"
    sign "${FW_V}/XPCServices/Downloader.xpc"
    sign "${FW_V}/XPCServices/Installer.xpc"
    sign "${FW_V}/Autoupdate"
    sign "${FW_V}/Updater.app"
    sign "${EMBEDDED_FW}"
fi

echo "==> Подпись приложения («${SIGN_IDENTITY}», hardened runtime)…"
# ${arr[@]+…} — пустой массив под `set -u` в bash 3.2 (системный на macOS) иначе падает.
sign ${APP_ENTITLEMENTS[@]+"${APP_ENTITLEMENTS[@]}"} "${APP_DIR}"
codesign --verify --strict --deep "${APP_DIR}"

# Проверка арки. При universal-сборке бинарник обязан содержать оба слайса —
# иначе .app молча не запустится на Intel (или на Apple Silicon). Падаем сразу,
# чтобы битый релиз не уехал в дистрибуцию.
if [ "${UNIVERSAL}" = "1" ]; then
    echo "==> Проверка universal-арки…"
    ARCHS="$(lipo -archs "${MACOS_DIR}/${APP_NAME}" 2>/dev/null || echo "")"
    for need in arm64 x86_64; do
        case " ${ARCHS} " in
            *" ${need} "*) ;;
            *)
                echo "❌ Бинарник не universal: ожидались arm64 + x86_64, есть «${ARCHS}»" >&2
                exit 1
                ;;
        esac
    done
    echo "   OK: ${ARCHS}"
fi

echo ""
echo "✅ Готово: ${APP_DIR}"
echo "   Запуск:    open \"${APP_DIR}\""
echo "   Установка: cp -R \"${APP_DIR}\" /Applications/"
echo "   Подпись:   ${SIGN_IDENTITY}"
