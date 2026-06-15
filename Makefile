# Hopkey — Makefile
# Обёртка над SwiftPM и build.sh для частых команд.

APP_NAME := Hopkey
APP_BUNDLE := build/$(APP_NAME).app
# Dev-сборки (run/watch) идут под отдельным bundle id, чтобы не делить идентичность
# с установленным релизом (com.local.hopkey). release.sh и `make app`/`install` — релизный id.
DEV_BUNDLE_ID := com.local.hopkey.dev

.DEFAULT_GOAL := help

.PHONY: help build test app run watch install uninstall clean setup-signing

help: ## Показать список команд
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

build: ## Собрать debug-бинарник (быстрая проверка компиляции)
	swift build

test: ## Прогнать юнит-тесты ядра (TicketParser)
	swift test

coverage: ## Отчёт покрытия HopkeyCore (llvm-cov)
	swift test --enable-code-coverage
	@xcrun llvm-cov report \
		.build/arm64-apple-macosx/debug/HopkeyPackageTests.xctest/Contents/MacOS/HopkeyPackageTests \
		-instr-profile=.build/arm64-apple-macosx/debug/codecov/default.profdata \
		-ignore-filename-regex='Tests/' \
		| tail -n +3

app: ## Собрать release .app-бандл в build/
	./build.sh

run: ## Собрать dev .app (отдельный bundle id) и запустить (иконка в строке меню)
	HOPKEY_BUNDLE_ID=$(DEV_BUNDLE_ID) UNIVERSAL=0 ./build.sh
	open "$(APP_BUNDLE)"

watch: ## Dev: следить за Sources/ и пересобирать+перезапускать при изменениях
	HOPKEY_BUNDLE_ID=$(DEV_BUNDLE_ID) ./dev-watch.sh

setup-signing: ## Создать self-signed сертификат, чтобы Accessibility не слетал при пересборках
	./setup-signing.sh

install: app ## Собрать .app и установить в /Applications
	@pkill -f "$(APP_NAME).app/Contents/MacOS/$(APP_NAME)" 2>/dev/null || true
	rm -rf "/Applications/$(APP_NAME).app"
	cp -R "$(APP_BUNDLE)" /Applications/
	@echo "✅ Установлено: /Applications/$(APP_NAME).app"
	@echo "   Если macOS блокирует запуск — снимите карантин:"
	@echo "     xattr -dr com.apple.quarantine /Applications/$(APP_NAME).app"

uninstall: ## Остановить и удалить приложение из /Applications
	@pkill -f "$(APP_NAME).app/Contents/MacOS/$(APP_NAME)" 2>/dev/null || true
	rm -rf "/Applications/$(APP_NAME).app"
	@echo "✅ Удалено из /Applications"

clean: ## Удалить артефакты сборки (.build и build/)
	swift package clean
	rm -rf .build build
	@echo "✅ Очищено"
