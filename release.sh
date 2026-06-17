#!/usr/bin/env bash
set -euo pipefail

# Выпускает новую версию Hopkey. Собирает ДВА артефакта:
#   • Hopkey-<ver>.zip — для автообновления Sparkle (на него ссылается appcast.xml);
#   • Hopkey-<ver>.dmg — для ручной первой установки (drag-to-Applications).
# Шаги:
#   0. предполётная проверка: чистое дерево (кроме VERSION) + swift test;
#   1. build.sh (.app, версия из файла VERSION);
#   2. zip → подпись EdDSA + генерация appcast.xml (generate_appcast);
#   3. коммит «release vX» (VERSION + appcast.xml) + тег + push — ДО создания
#      GitHub Release, чтобы тег всегда указывал на релизный коммит;
#   4. dmg (hdiutil, с ярлыком /Applications);
#   5. GitHub Release из уже запушенного тега (--verify-tag) с обоими файлами.
#
# Почему коммит/тег ДО релиза (шаг 3): appcast.xml рождается во время сборки, а
# `gh release create` без готового тега ставит тег на текущий HEAD remote-ветки —
# а он устаревший, пока appcast/VERSION не запушены. Именно из-за этого теги
# v1.4.0/v1.5.0 изначально вставали не на тот коммит. Сначала пушим релизный
# коммит и тег, затем создаём релиз с --verify-tag (тег уже на месте).
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

# 0. Предполётная проверка (контракт из RELEASING.md). Рабочее дерево должно быть
# чистым — единственное допустимое изменение это поднятый VERSION (appcast.xml
# перегенерится и закоммитится на шаге 3). Так коммит «release vX» не вберёт
# лишних правок. Тесты — зелёные, иначе не релизим.
DIRTY="$(git status --porcelain --untracked-files=no | grep -vE ' VERSION$' || true)"
if [ -n "${DIRTY}" ]; then
    echo "❌ Рабочее дерево не чистое (допускается только правка VERSION):" >&2
    echo "${DIRTY}" >&2
    echo "   Закоммитьте или уберите изменения и повторите." >&2
    exit 1
fi
echo "==> Тесты (swift test)…"
swift test

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

# 3. Коммит релиза + тег + push — ДО создания GitHub Release (см. шапку). Тег
# ставим на этот коммит и пушим, поэтому gh release create --verify-tag берёт
# готовый тег на правильном коммите.
echo "==> Коммит и push релизного коммита…"
if ! git diff --quiet -- VERSION appcast.xml || ! git diff --cached --quiet -- VERSION appcast.xml; then
    git add VERSION appcast.xml
    git commit -m "release ${TAG}"
fi
if ! git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
    git tag "${TAG}"
fi
git push origin HEAD
git push origin "${TAG}"

# 4. DMG для ручной установки. Создаём ПОСЛЕ appcast, чтобы образ не попал в фид.
echo "==> Сборка ${DMG_NAME}…"
STAGING="$(mktemp -d)"
cp -R "build/${APP_NAME}.app" "${STAGING}/"
ln -s /Applications "${STAGING}/Applications"     # drag-to-install
hdiutil create -volname "${APP_NAME} ${VERSION}" \
    -srcfolder "${STAGING}" -ov -format UDZO "${DIST_DIR}/${DMG_NAME}" >/dev/null
rm -rf "${STAGING}"

# 5. GitHub Release с обоими артефактами.

# Список изменений относительно предыдущей версии — ОБЯЗАТЕЛЬНАЯ часть release notes
# (см. RELEASING.md). По умолчанию собираем из git-истории: subject коммитов между
# прошлым тегом и HEAD, без merge и без служебных «release …» бампов. Курированный
# текст можно передать через переменную: CHANGELOG="- …\n- …" ./release.sh
PREV_TAG="$(git describe --tags --abbrev=0 --exclude="${TAG}" 2>/dev/null || echo "")"
if [ -n "${CHANGELOG:-}" ]; then
    CHANGES="${CHANGELOG}"
elif [ -n "${PREV_TAG}" ]; then
    CHANGES="$(git log --no-merges --pretty='- %s' "${PREV_TAG}..HEAD" \
        | grep -vE '^- release(:| v)' || true)"
fi
# Пустой changelog — это почти всегда ошибка (забыли поднять/закоммитить, или
# запуск из неверной точки). Не публикуем релиз без описания изменений.
if [ -z "${CHANGES:-}" ]; then
    echo "❌ Не удалось собрать список изменений${PREV_TAG:+ относительно ${PREV_TAG}}." >&2
    echo "   Укажите его явно: CHANGELOG=\$'- пункт\\\\n- пункт' ./release.sh" >&2
    exit 1
fi

NOTES="$(cat <<EOF
## ${APP_NAME} ${VERSION}

### Изменения${PREV_TAG:+ (с ${PREV_TAG})}
${CHANGES}

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
    # Релиз уже есть: перезаливаем ассеты И обновляем текст notes (иначе памятка
    # про xattr не попадёт в уже созданный релиз).
    gh release upload "${TAG}" "${DIST_DIR}/${ZIP_NAME}" "${DIST_DIR}/${DMG_NAME}" --repo "${REPO}" --clobber
    gh release edit "${TAG}" --repo "${REPO}" --title "${APP_NAME} ${VERSION}" --notes "${NOTES}"
else
    # Тег уже запушен на шаге 3 → --verify-tag заставляет gh взять его, а не
    # создавать новый на (возможно устаревшем) HEAD remote.
    gh release create "${TAG}" "${DIST_DIR}/${ZIP_NAME}" "${DIST_DIR}/${DMG_NAME}" --repo "${REPO}" \
        --title "${APP_NAME} ${VERSION}" --notes "${NOTES}" --verify-tag
fi

echo ""
echo "✅ Релиз ${TAG} опубликован (zip + dmg). Коммит «release ${TAG}», тег и appcast.xml уже в main."
