# AGENTS.md — гайд для агента по Hopkey

Hopkey — macOS-приложение в строке меню: распознаёт ключи (`PROJ-123`, `#42`, `CVE-…`)
в буфере/выделении и открывает или копирует ссылку по шаблону regex→URL. Чистый
Swift Package Manager, без Xcode-проекта.

## Команды

```bash
make build      # debug-сборка (быстрая проверка компиляции)  = swift build
make test       # юнит-тесты ядра                              = swift test
make coverage   # отчёт покрытия HopkeyCore (llvm-cov)         = swift test --enable-code-coverage + llvm-cov
make app        # release .app в build/                        = ./build.sh
make run        # собрать .app и запустить
make watch      # авто-пересборка/перезапуск при правках Sources/
```

Релиз — отдельный процесс, см. [RELEASING.md](RELEASING.md) (там же «Контракт агента»).

## Архитектура

- `Sources/HopkeyCore/` — чистое ядро без UI: парсер (`TicketParser`), модель шаблона
  (`LinkTemplate` + пресеты), настройки (`JiraConfig`), ручной ввод (`QuickTicketInput`),
  сниппеты (`SnippetStore`, `SnippetQuickSelect`, `KeychainStore`). Покрыто тестами в
  `Tests/HopkeyCoreTests/`. **Логику меняем здесь и держим под тестами.**
- `Sources/Hopkey/` — GUI-таргет (AppKit, меню-бар). Окна, хоткеи, уведомления,
  `SnippetPickerWindow` / `SnippetEditorWindow`.
- `build.sh` собирает бинарник SwiftPM и вручную упаковывает его в `.app` (Info.plist,
  Sparkle.framework, `.lproj`-локализация в `Contents/Resources`, self-signed подпись).

## Тесты

Юнит-тесты — только `HopkeyCore` в `Tests/HopkeyCoreTests/`. Таргет `Hopkey` (AppKit,
Carbon-хоткеи, `NSSound`, реальный Keychain) **не покрываем** автотестами: GUI лишь
оркестрирует ядро.

**Правила:**
- новая бизнес-логика → `Sources/HopkeyCore/` + тест в том же изменении;
- настройки и персистентность — через изолированный `UserDefaults(suiteName:)` (см.
  `JiraConfigTests`);
- сниппеты — через injectable `SnippetSecretStore`, не настоящий Keychain (см.
  `SnippetStoreTests`);
- перед завершением задачи с правками ядра — `make test`; при сомнениях — `make coverage`.

**Не гонимся за:**
- покрытием всего репозитория (GUI заведомо 0%);
- UI-тестами AppKit «на всякий случай»;
- юнит-тестами `KeychainStore`, Carbon, Accessibility, звуков.

## Сниппеты

Вторая функция продукта — заранее заданные текстовые значения (пароли, ссылки, шаблонные
ответы), вставляемые в активное поле по хоткею `⌃⌥V`.

- **Хранение:** `SnippetStore` держит метаданные в памяти; значения — одним JSON-блобом
  в Keychain (`KeychainStore`, ключ `"all"`). Загрузка **ленивая** (`prepare()` / первое
  обращение) — до этого Keychain не трогаем.
- **Миграция:** старый формат (метаданные в UserDefaults + значение на сниппет в Keychain)
  переносится в единый блоб один раз (`snippetsBlobMigrated`).
- **GUI:** вкладка «Сниппеты» в `SettingsWindow`, редактор `SnippetEditorWindow`,
  пикер `SnippetPickerWindow`. Вставка в чужое поле синтезирует `Cmd+V` через
  `HotKeyManager` — **требует Accessibility**. Без доступа значение копируется в буфер.
- **Тесты:** `SnippetStoreTests`, `SnippetQuickSelectTests`; реальный Keychain в тестах
  не используется — injectable `SnippetSecretStore`.

**Правило:** логику сниппетов меняем в `HopkeyCore` под тестами; GUI только оркестрирует.

## Локализация (ru / en)

Приложение двуязычное; язык выбирает система по предпочитаемым языкам пользователя,
фолбэк — английский (`defaultLocalization: "en"` в `Package.swift`).

**Правило: ни одной видимой пользователю строки литералом в коде.** Любой текст в UI
идёт через хелпер `L(_:_:)` (см. `Sources/Hopkey/Localization.swift`):

```swift
button.title = L("quick.open")                 // простой ключ
label.stringValue = L("notif.open.many", "\(n)") // с подстановкой %@
```

Строки лежат в `Sources/Hopkey/Resources/{en,ru}.lproj/Localizable.strings`. Ключи —
семантические, с точками по областям (`settings.*`, `quick.*`, `notif.*`, `menu.*`…).

Ручной выбор языка — попап «Язык интерфейса» на вкладке «Общие» (`AppLanguage` в
`Localization.swift`). «Системный»/«Русский»/«English»: выбор пишет `AppleLanguages` в
домен приложения и предлагает перезапуск. Применяется **только при старте через
LaunchServices** — поэтому перезапуск идёт через `open -n <.app>`, а не прямым запуском
бинарника (при прямом запуске per-app язык игнорируется, берётся системный).

**Добавляя/меняя UI-строку:**
1. добавь ключ **в оба** файла `en.lproj` и `ru.lproj` (плейсхолдеры `%@` держи в синхроне);
2. вызывай её через `L("ключ")`, а не пиши текст в коде;
3. собери (`swift build`) — SwiftPM компилирует `.lproj` в `Hopkey_Hopkey.bundle`, из
   которого `build.sh` копирует сами `.lproj` в `.app/Contents/Resources`.

> ⚠️ **Не используй `Bundle.module` в таргете `Hopkey`.** Его аксессор ищет ресурс-бандл
> либо в корне `.app` (нельзя — codesign падает с `unsealed contents present in the bundle
> root`), либо по абсолютному пути сборки, захардкоженному под текущую машину. В итоге на
> чужом Mac `.app` молча крашится на старте (`could not load resource bundle`), а т.к.
> приложение — `LSUIElement`, не видно ни ошибки, ни иконки. Поэтому `L(_:)` грузит строки
> из `Bundle.main`, а `build.sh` раскладывает `.lproj` в `Contents/Resources` — штатное
> место локализации macOS, дружит с codesign и работает на любой машине. То же правило для
> любых ресурсов (иконки, pdf): клади в `Contents/Resources` и читай через `Bundle.main`.
>
> Проверка портируемости перед раздачей: `mv .build .build_hidden`, скопируй `.app` в
> `mktemp -d` и запусти бинарник напрямую — так пропадает захардкоженный fallback-путь и
> виден старт «как на чужой машине». Не забудь вернуть `.build`.

**Что НЕ локализуем:** технические/лог-строки (`print` в `HotKeyManager`), сообщения
`fatalError("init(coder:)…")`, имена пресетов (`Jira`, `GitHub issue`, `CVE`) и примеры-
плейсхолдеры в полях редактора (`PROJ-(\d+)`, `https://…`).

## Терминология UI

В видимых строках — нейтральные «ключ» и «ссылка», не «тикет/Jira» (Jira теперь лишь
один из пресетов шаблонов). Держи это в обоих языках: en — «key»/«link».
