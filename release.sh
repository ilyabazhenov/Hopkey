#!/usr/bin/env bash
set -euo pipefail

# Выпускает новую версию Hopkey. Собирает ДВА артефакта:
#   • Hopkey-<ver>.zip — для автообновления Sparkle (на него ссылается appcast.xml);
#   • Hopkey-<ver>.dmg — для ручной первой установки (drag-to-Applications).
# Шаги:
#   1. build.sh (.app, версия из файла VERSION);
#   2. zip → подпись EdDSA + генерация appcast.xml (generate_appcast);
#   3. dmg (hdiutil, с ярлыком /Applications);
#   4. GitHub Release с обоими файлами;
#   5. напоминание закоммитить appcast.xml + VERSION в main.
#
# Перед первым запуском: ./setup-signing.sh (серт «Hopkey Dev») и generate_keys
# (EdDSA-ключ; публичный уже в build.sh → SUPublicEDKey). Нужен авторизованный gh.
#
# Использование: поднимите номер в файле VERSION, затем ./release.sh

APP_NAME="Hopkey"
REPO="ilyabazhenov/Hopkey"
cd "$(dirname "$0")"

VERSION="$(cat VERSION)"
TAG="v${VERSION}"
ZIP_NAME="${APP_NAME}-${VERSION}.zip"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
DIST_DIR="dist"

SPARKLE_BIN="$(swift build -c release --product "${APP_NAME}" --show-bin-path)/../../artifacts/sparkle/Sparkle/bin"
GEN_APPCAST="${SPARKLE_BIN}/generate_appcast"

echo "==> Релиз ${TAG}"

# 1. Сборка .app.
./build.sh
rm -rf "${DIST_DIR}"
mkdir -p "${DIST_DIR}"

# 2. ZIP для Sparkle + appcast. На момент генерации в dist лежит ТОЛЬКО zip,
# поэтому в appcast.xml попадёт ровно одна (актуальная) запись на zip, а dmg
# в фид обновлений не утечёт.
ditto -c -k --keepParent "build/${APP_NAME}.app" "${DIST_DIR}/${ZIP_NAME}"
DOWNLOAD_PREFIX="https://github.com/${REPO}/releases/download/${TAG}/"
echo "==> Генерация appcast.xml…"
"${GEN_APPCAST}" --download-url-prefix "${DOWNLOAD_PREFIX}" "${DIST_DIR}"
cp "${DIST_DIR}/appcast.xml" appcast.xml

# 3. DMG для ручной установки. Создаём ПОСЛЕ appcast, чтобы образ не попал в фид.
echo "==> Сборка ${DMG_NAME}…"
STAGING="$(mktemp -d)"
cp -R "build/${APP_NAME}.app" "${STAGING}/"
ln -s /Applications "${STAGING}/Applications"     # drag-to-install
hdiutil create -volname "${APP_NAME} ${VERSION}" \
    -srcfolder "${STAGING}" -ov -format UDZO "${DIST_DIR}/${DMG_NAME}" >/dev/null
rm -rf "${STAGING}"

# 4. GitHub Release с обоими артефактами.
NOTES="$(cat <<EOF
## ${APP_NAME} ${VERSION}

### Установка (вручную)
1. Скачайте \`${DMG_NAME}\`, откройте и перетащите **Hopkey** в **Applications**.
2. Подпись self-signed (не нотаризовано Apple) — при первом запуске снимите карантин:
   \`\`\`bash
   xattr -dr com.apple.quarantine /Applications/Hopkey.app
   \`\`\`

### Обновление
Уже установленный Hopkey обновится сам через «Проверить обновления…» (Sparkle, \`${ZIP_NAME}\`).
EOF
)"

echo "==> Создание GitHub Release ${TAG}…"
if gh release view "${TAG}" --repo "${REPO}" >/dev/null 2>&1; then
    gh release upload "${TAG}" "${DIST_DIR}/${ZIP_NAME}" "${DIST_DIR}/${DMG_NAME}" --repo "${REPO}" --clobber
else
    gh release create "${TAG}" "${DIST_DIR}/${ZIP_NAME}" "${DIST_DIR}/${DMG_NAME}" --repo "${REPO}" \
        --title "${APP_NAME} ${VERSION}" --notes "${NOTES}"
fi

echo ""
echo "✅ Релиз ${TAG} опубликован (zip + dmg)."
echo "   Закоммитьте фид, чтобы SUFeedURL отдавал новую версию:"
echo "     git add appcast.xml VERSION && git commit -m \"release ${TAG}\" && git push"
