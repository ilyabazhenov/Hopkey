#!/usr/bin/env bash
# Dev watch: следит за Sources/ и Package.swift, при изменении пересобирает
# .app и перезапускает его. Использует fswatch, если установлен, иначе опрос.
set -uo pipefail
cd "$(dirname "$0")"

# Dev-сборка ставит ОТДЕЛЬНЫЙ bundle id (не релизный com.local.hopkey): иначе dev и
# установленный релиз делят одну идентичность в LaunchServices/менюбаре, из-за чего
# иконка dev-сборки переставала появляться в строке меню. build.sh наследует переменную.
export HOPKEY_BUNDLE_ID="${HOPKEY_BUNDLE_ID:-com.local.hopkey.dev}"

APP_NAME="Hopkey"
APP_BUNDLE="build/${APP_NAME}.app"
WATCH_PATHS=("Sources" "Package.swift")

stop_app() {
    pkill -f "${APP_NAME}.app/Contents/MacOS/${APP_NAME}" 2>/dev/null || true
}

cleanup() {
    echo ""
    echo "==> Остановка watch, закрываю приложение"
    pkill -P $$ 2>/dev/null || true   # fswatch и дочерние подоболочки
    stop_app
    exit 0
}
trap cleanup INT TERM

rebuild_and_run() {
    echo ""
    echo "==> $(date +%H:%M:%S) пересборка…"
    stop_app
    if ./build.sh >/tmp/hopkey-build.log 2>&1; then
        open "${APP_BUNDLE}"
        echo "✅ Пересобрано и перезапущено"
    else
        echo "❌ Ошибка сборки (см. /tmp/hopkey-build.log) — жду изменений"
        tail -n 15 /tmp/hopkey-build.log
    fi
}

# Снимок mtime всех .swift для режима опроса.
snapshot() {
    find "${WATCH_PATHS[@]}" -type f -name '*.swift' -exec stat -f '%m %N' {} \; 2>/dev/null | sort | md5
}

echo "👀 Слежу за: ${WATCH_PATHS[*]}  (Ctrl+C — выход)"
rebuild_and_run

if command -v fswatch >/dev/null 2>&1; then
    # Пайп в фоне + wait: так trap (Ctrl+C) срабатывает сразу, а не после конца пайпа.
    fswatch -o -r "${WATCH_PATHS[@]}" | while read -r _; do
        rebuild_and_run
    done &
    wait $!
else
    echo "(fswatch не найден — опрос каждую секунду; быстрее: brew install fswatch)"
    last="$(snapshot)"
    while true; do
        sleep 1
        current="$(snapshot)"
        if [ "$current" != "$last" ]; then
            last="$current"
            rebuild_and_run
        fi
    done
fi
