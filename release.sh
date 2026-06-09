#!/usr/bin/env bash
set -euo pipefail

# Выпускает новую версию Hopkey с поддержкой автообновления Sparkle:
#   1. собирает .app (build.sh берёт версию из файла VERSION);
#   2. пакует его в zip;
#   3. через generate_appcast подписывает архив EdDSA-ключом (из Keychain) и
#      генерирует appcast.xml с ссылкой на ассет GitHub-релиза;
#   4. создаёт GitHub Release и заливает zip;
#   5. напоминает закоммитить обновлённый appcast.xml в main.
#
# Перед первым запуском: ./setup-signing.sh (серт «Hopkey Dev») и generate_keys
# (EdDSA-ключ; публичный ключ уже прописан в build.sh → SUPublicEDKey).
#
# Использование: отредактируйте VERSION (например, 1.0.1), затем ./release.sh

APP_NAME="Hopkey"
REPO="ilyabazhenov/Hopkey"
cd "$(dirname "$0")"

VERSION="$(cat VERSION)"
TAG="v${VERSION}"
ZIP_NAME="${APP_NAME}-${VERSION}.zip"
DIST_DIR="dist"

SPARKLE_BIN="$(swift build -c release --product "${APP_NAME}" --show-bin-path)/../../artifacts/sparkle/Sparkle/bin"
GEN_APPCAST="${SPARKLE_BIN}/generate_appcast"

echo "==> Релиз ${TAG}"

# 1–2. Сборка и упаковка.
./build.sh
rm -rf "${DIST_DIR}"
mkdir -p "${DIST_DIR}"
ditto -c -k --keepParent "build/${APP_NAME}.app" "${DIST_DIR}/${ZIP_NAME}"

# 3. Подпись архива и генерация appcast. В папке dist лежит только текущий zip,
# поэтому appcast.xml будет содержать одну (актуальную) запись — этого достаточно,
# чтобы любая старая версия обновилась до последней.
DOWNLOAD_PREFIX="https://github.com/${REPO}/releases/download/${TAG}/"
echo "==> Генерация appcast.xml…"
"${GEN_APPCAST}" --download-url-prefix "${DOWNLOAD_PREFIX}" "${DIST_DIR}"
cp "${DIST_DIR}/appcast.xml" appcast.xml

# 4. GitHub Release. Требует установленного и авторизованного gh.
echo "==> Создание GitHub Release ${TAG}…"
if gh release view "${TAG}" --repo "${REPO}" >/dev/null 2>&1; then
    gh release upload "${TAG}" "${DIST_DIR}/${ZIP_NAME}" --repo "${REPO}" --clobber
else
    gh release create "${TAG}" "${DIST_DIR}/${ZIP_NAME}" --repo "${REPO}" \
        --title "${APP_NAME} ${VERSION}" --notes "Hopkey ${VERSION}"
fi

echo ""
echo "✅ Релиз ${TAG} опубликован."
echo "   Осталось закоммитить фид, чтобы SUFeedURL отдавал новую версию:"
echo "     git add appcast.xml VERSION && git commit -m \"release ${TAG}\" && git push"
