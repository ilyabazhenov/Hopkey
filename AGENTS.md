# AGENTS.md — гайд для агента по Hopkey

Hopkey — macOS-приложение в строке меню: распознаёт ключи (`PROJ-123`, `#42`, `CVE-…`)
в буфере/выделении и открывает или копирует ссылку по шаблону regex→URL. Чистый
Swift Package Manager, без Xcode-проекта.

## Команды

```bash
make build      # debug-сборка (быстрая проверка компиляции)  = swift build
make test       # юнит-тесты ядра                              = swift test
make app        # release .app в build/                        = ./build.sh
make run        # собрать .app и запустить
make watch      # авто-пересборка/перезапуск при правках Sources/
```

Релиз — отдельный процесс, см. [RELEASING.md](RELEASING.md) (там же «Контракт агента»).

## Архитектура

- `Sources/HopkeyCore/` — чистое ядро без UI: парсер (`TicketParser`), модель шаблона
  (`LinkTemplate` + пресеты), настройки (`JiraConfig`), ручной ввод (`QuickTicketInput`).
  Покрыто тестами в `Tests/HopkeyCoreTests/`. **Логику меняем здесь и держим под тестами.**
- `Sources/Hopkey/` — GUI-таргет (AppKit, меню-бар). Окна, хоткеи, уведомления.
- `build.sh` собирает бинарник SwiftPM и вручную упаковывает его в `.app` (Info.plist,
  Sparkle.framework, ресурс-бандл локализации, self-signed подпись).

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
3. собери (`swift build`) — SwiftPM кладёт `.lproj` в `Hopkey_Hopkey.bundle`
   (`Bundle.module`), а `build.sh` копирует бандл в `.app/Contents/Resources`.

**Что НЕ локализуем:** технические/лог-строки (`print` в `HotKeyManager`), сообщения
`fatalError("init(coder:)…")`, имена пресетов (`Jira`, `GitHub issue`, `CVE`) и примеры-
плейсхолдеры в полях редактора (`PROJ-(\d+)`, `https://…`).

## Терминология UI

В видимых строках — нейтральные «ключ» и «ссылка», не «тикет/Jira» (Jira теперь лишь
один из пресетов шаблонов). Держи это в обоих языках: en — «key»/«link».
