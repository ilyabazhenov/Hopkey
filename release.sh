#!/usr/bin/env bash
set -euo pipefail

# Выпускает новую версию Hopkey. Собирает ДВА артефакта:
#   • Hopkey-<ver>.zip — для автообновления Sparkle (на него ссылается appcast.xml);
#   • Hopkey-<ver>.dmg — для ручной первой установки (drag-to-Applications).
# Шаги:
#   0. предполётная проверка: чистое дерево (кроме VERSION), Developer ID и
#      профиль notarytool в связке ключей, swift test;
#   1. build.sh (.app с Developer ID + hardened runtime + secure timestamp) →
#      нотаризация и staple .app;
#   2. zip → подпись EdDSA + генерация appcast.xml (generate_appcast);
#   3. dmg (hdiutil, с ярлыком /Applications) → подпись, нотаризация и staple dmg;
#   4. версия на сайте (docs/, метка class="ver") → коммит «release vX» (VERSION +
#      appcast.xml + страницы сайта) + тег + push — ДО создания GitHub Release, чтобы
#      тег всегда указывал на релизный коммит; тот же push пересобирает GitHub Pages;
#   5. GitHub Release из уже запушенного тега (--verify-tag) с обоими файлами.
# Всё, что может упасть (сборка, нотаризация), идёт до push: неудачный релиз не
# оставляет за собой запушенного тега.
#
# Нотаризация — через профиль notarytool в связке ключей (по умолчанию
# «hopkey-notary», другой — NOTARY_PROFILE=…). Создаётся один раз на машину:
#   xcrun notarytool store-credentials hopkey-notary \
#     --key AuthKey_<KEYID>.p8 --key-id <KEYID> --issuer <ISSUER-UUID>
# Ненотаризованный релиз Gatekeeper отвергает при первом запуске, поэтому флага
# «пропустить нотаризацию» нет.
#
# Почему коммит/тег ДО релиза (шаг 3): appcast.xml рождается во время сборки, а
# `gh release create` без готового тега ставит тег на текущий HEAD remote-ветки —
# а он устаревший, пока appcast/VERSION не запушены. Именно из-за этого теги
# v1.4.0/v1.5.0 изначально вставали не на тот коммит. Сначала пушим релизный
# коммит и тег, затем создаём релиз с --verify-tag (тег уже на месте).
#
# Перед первым запуском: сертификат «Developer ID Application» в связке ключей,
# профиль notarytool (см. выше) и generate_keys (EdDSA-ключ; публичный уже в
# build.sh → SUPublicEDKey). Нужен авторизованный gh.
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
NOTARY_PROFILE="${NOTARY_PROFILE:-hopkey-notary}"

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
# Подпись и нотаризация проверяются до сборки: проверки дешёвые, сборка — нет.
SIGN_IDENTITY="$(security find-identity -v -p codesigning \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -n 1)"
if [ -z "${SIGN_IDENTITY}" ]; then
    echo "❌ В связке ключей нет сертификата «Developer ID Application» — релиз подписывается только им." >&2
    exit 1
fi
if ! xcrun notarytool history --keychain-profile "${NOTARY_PROFILE}" >/dev/null 2>&1; then
    echo "❌ Профиль notarytool «${NOTARY_PROFILE}» не найден или его ключ отвергнут." >&2
    echo "   Создайте один раз: xcrun notarytool store-credentials ${NOTARY_PROFILE} --key <AuthKey.p8> --key-id <KEYID> --issuer <ISSUER>" >&2
    echo "   (или укажите существующий: NOTARY_PROFILE=… ./release.sh)" >&2
    exit 1
fi
echo "==> Тесты (swift test)…"
swift test

# Отправляет файл (.zip с .app или .dmg) на нотаризацию и ждёт вердикта. При
# отказе печатает лог notarytool — там перечислены конкретные причины.
notarize() {
    local file="$1" result
    result="$(mktemp)"
    echo "==> Нотаризация $(basename "${file}") (профиль ${NOTARY_PROFILE}), обычно несколько минут…"
    xcrun notarytool submit "${file}" --keychain-profile "${NOTARY_PROFILE}" \
        --wait --output-format json > "${result}" || true
    local status id
    status="$(plutil -extract status raw -o - "${result}" 2>/dev/null || echo unknown)"
    id="$(plutil -extract id raw -o - "${result}" 2>/dev/null || true)"
    if [ "${status}" != "Accepted" ]; then
        echo "❌ Нотаризация не прошла: status=${status}" >&2
        cat "${result}" >&2 || true
        [ -n "${id}" ] && xcrun notarytool log "${id}" --keychain-profile "${NOTARY_PROFILE}" >&2 || true
        rm -f "${result}"
        exit 1
    fi
    rm -f "${result}"
    echo "   OK: принято (submission ${id})"
}

# 1. Сборка .app с Developer ID и защищённым timestamp (без него нотаризация
# отвергает подпись), затем нотаризация и staple: билет едет внутри .app, поэтому
# Gatekeeper принимает приложение и офлайн. Staple — до zip, иначе билет не попадёт
# в архив автообновления.
SIGN_IDENTITY="${SIGN_IDENTITY}" SIGN_TIMESTAMP=secure ./build.sh
rm -rf "${DIST_DIR}"
mkdir -p "${DIST_DIR}"

NOTARY_ZIP="$(mktemp -d)/${APP_NAME}-notarize.zip"
ditto -c -k --keepParent "build/${APP_NAME}.app" "${NOTARY_ZIP}"
notarize "${NOTARY_ZIP}"
rm -f "${NOTARY_ZIP}"
xcrun stapler staple "build/${APP_NAME}.app"
if ! spctl --assess --type execute -vv "build/${APP_NAME}.app" 2>&1 | grep -q 'source=Notarized Developer ID'; then
    echo "❌ Gatekeeper не принимает приложение после staple:" >&2
    spctl --assess --type execute -vv "build/${APP_NAME}.app" >&2 || true
    exit 1
fi
echo "   Gatekeeper: Notarized Developer ID"

# 2. ZIP для Sparkle + appcast. На момент генерации в dist лежит ТОЛЬКО zip,
# поэтому в appcast.xml попадёт ровно одна (актуальная) запись на zip, а dmg
# в фид обновлений не утечёт.
ditto -c -k --keepParent "build/${APP_NAME}.app" "${DIST_DIR}/${ZIP_NAME}"
DOWNLOAD_PREFIX="https://github.com/${REPO}/releases/download/${TAG}/"
echo "==> Генерация appcast.xml…"
"${GEN_APPCAST}" --download-url-prefix "${DOWNLOAD_PREFIX}" "${DIST_DIR}"
cp "${DIST_DIR}/appcast.xml" appcast.xml

# 3. DMG для ручной установки. Создаём ПОСЛЕ appcast, чтобы образ не попал в фид.
# Внутри уже нотаризованный .app; сам образ тоже подписываем и нотаризуем — тогда
# Gatekeeper не спотыкается и на открытии скачанного .dmg.
echo "==> Сборка ${DMG_NAME}…"
STAGING="$(mktemp -d)"
cp -R "build/${APP_NAME}.app" "${STAGING}/"
ln -s /Applications "${STAGING}/Applications"     # drag-to-install
hdiutil create -volname "${APP_NAME} ${VERSION}" \
    -srcfolder "${STAGING}" -ov -format UDZO "${DIST_DIR}/${DMG_NAME}" >/dev/null
rm -rf "${STAGING}"
codesign --force --timestamp --sign "${SIGN_IDENTITY}" "${DIST_DIR}/${DMG_NAME}"
notarize "${DIST_DIR}/${DMG_NAME}"
xcrun stapler staple "${DIST_DIR}/${DMG_NAME}"

# 4. Версия на сайте: GitHub Pages публикует docs/ из main, номер стоит в метке
# class="ver" строки требований. Правим здесь, после сборки и нотаризации: упавший
# релиз сайт не трогает, а удачный обновляет его тем же push, что и appcast.
SITE_PAGES=(docs/index.html docs/en/index.html)
echo "==> Версия ${TAG} на сайте…"
for page in "${SITE_PAGES[@]}"; do
    if grep -q 'class="ver">v' "${page}"; then
        sed -i '' -E "s#(class=\"ver\">v)[0-9][0-9.]*#\1${VERSION}#g" "${page}"
    else
        echo "⚠️  В ${page} нет метки версии (class=\"ver\") — номер на сайте не обновлён" >&2
    fi
done

# Коммит релиза + тег + push — ДО создания GitHub Release (см. шапку). Тег
# ставим на этот коммит и пушим, поэтому gh release create --verify-tag берёт
# готовый тег на правильном коммите.
echo "==> Коммит и push релизного коммита…"
RELEASE_FILES=(VERSION appcast.xml "${SITE_PAGES[@]}")
if ! git diff --quiet -- "${RELEASE_FILES[@]}" || ! git diff --cached --quiet -- "${RELEASE_FILES[@]}"; then
    git add "${RELEASE_FILES[@]}"
    git commit -m "release ${TAG}"
fi
if ! git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
    git tag "${TAG}"
fi
git push origin HEAD
git push origin "${TAG}"

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
Скачайте \`${DMG_NAME}\`, откройте и перетащите **Hopkey** в **Applications**.
Приложение подписано Developer ID и нотаризовано Apple — открывается обычным двойным кликом.

### Обновление
Уже установленный Hopkey обновится сам через «Проверить обновления…» (Sparkle, \`${ZIP_NAME}\`).
EOF
)"

echo "==> Создание GitHub Release ${TAG}…"
if gh release view "${TAG}" --repo "${REPO}" >/dev/null 2>&1; then
    # Релиз уже есть: перезаливаем ассеты И обновляем текст notes (иначе свежие
    # notes не попадут в уже созданный релиз).
    gh release upload "${TAG}" "${DIST_DIR}/${ZIP_NAME}" "${DIST_DIR}/${DMG_NAME}" --repo "${REPO}" --clobber
    gh release edit "${TAG}" --repo "${REPO}" --title "${APP_NAME} ${VERSION}" --notes "${NOTES}"
else
    # Тег уже запушен на шаге 4 → --verify-tag заставляет gh взять его, а не
    # создавать новый на (возможно устаревшем) HEAD remote.
    gh release create "${TAG}" "${DIST_DIR}/${ZIP_NAME}" "${DIST_DIR}/${DMG_NAME}" --repo "${REPO}" \
        --title "${APP_NAME} ${VERSION}" --notes "${NOTES}" --verify-tag
fi

echo ""
echo "✅ Релиз ${TAG} опубликован (zip + dmg). Коммит «release ${TAG}», тег и appcast.xml уже в main."
