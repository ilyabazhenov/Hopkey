# Дизайн: шифрованная история буфера (текст + картинки)

Статус: **реализовано** (ядро+крипта под тестами, UI собран; ждёт ручной проверки вставки
картинки под Accessibility) · Ветка: `feature/command-toolbox`

> Отклонение от черновика: миниатюры **нигде не хранятся** (ни в манифесте, ни в памяти).
> Список истории транзиентный — UI при построении строки расшифровывает файл картинки по
> запросу (`imageData(for:)`) и делает `NSImage`. Это убрало необходимость декодировать
> картинки в core (там нет AppKit) и упростило формат. Открытый вопрос §12.1 закрыт этим.

## 1. Задача

Сейчас история буфера ([`ClipboardHistory`](../Sources/HopkeyCore/ClipboardHistory.swift)) —
кольцо из 15 **текстов только в памяти**. Нужно:

1. Хранить в истории и **картинки** (скопированные в буфер изображения).
2. **Персистить историю на диск** между запусками, но **зашифрованно** (ключ в Keychain),
   потому что история может содержать секреты (пароли, токены, скриншоты).

## 2. Принятые решения (зафиксированы с владельцем)

| Решение | Значение |
|---|---|
| Тумблер «хранить на диске» | **Нет.** Персистентность всегда включена. |
| Лимит истории | **100 записей** (общее кольцо: текст + картинки вперемешку). |
| Лимит на картинку | **16 МБ** на изображение (крупнее — не кладём). |
| Валидация | Сначала этот дизайн-док, потом код. |
| Порядок реализации | Ядро + крипта под тестами → затем UI. |

## 3. Threat-model (честно, что покупаем)

Шифрование данных-at-rest с ключом в Keychain **защищает** от:

- утечки файлов истории (Time Machine / бэкап, образ диска, снятый диск, папка, случайно
  попавшая в iCloud Drive / Dropbox);
- чтения истории другим пользователем машины.

**Не защищает** от malware, уже выполняющегося под тем же пользователем: он дотянется и до
Keychain (после разблокировки login-цепочки), и до самого `NSPasteboard` напрямую. Это
defense-in-depth «данные на диске», а не броня от активного зловреда. Для истории буфера
такой уровень оправдан, но переоценивать его не следует.

**Ограничение self-signed сборки** (см. память `keychain-dataprotection-unusable-selfsigned`):
data-protection keychain для self-signed недоступен. Поэтому ключ ложится **обычной
generic-password записью со строгим ACL** — ровно как блоб сниппетов
([`SnippetStore`](../Sources/HopkeyCore/SnippetStore.swift)). Читаем ключ **один раз за
запуск** → диалог доступа к связке максимум один раз (а после «Always Allow» — ни разу).

## 4. Обзор архитектуры

Переиспользуем два готовых паттерна проекта:

- **ключ → Keychain одной записью, читаем раз за старт** — как в `SnippetStore`
  (тот же протокол `SnippetSecretStore` + класс `KeychainStore`);
- **файлы в Application Support** — как в [`NotesStore`](../Sources/HopkeyCore/NotesStore.swift).

Крипта — `CryptoKit.AES.GCM` (таргет macOS 13, доступно; в проекте ещё не используется).

### 4.1 Раскладка на диске

```
~/Library/Application Support/Hopkey/clipboard/
├── manifest.enc          # зашифрованный JSON: список записей + метаданные картинок
├── img-<uuid>.enc        # каждая картинка — отдельный зашифрованный файл (PNG внутри)
├── img-<uuid>.enc
└── …
```

**Почему манифест + отдельные файлы, а не один общий блоб:** копирование в буфер
происходит часто, картинки многомегабайтные. Один блоб пришлось бы целиком пере-шифровывать
и переписывать на **каждый** копипаст (даже текстовый) — десятки МБ I/O на ровном месте.
Манифест мал (текст + метаданные) → переписываем его на каждое изменение дёшево; файл
картинки пишется **однократно** при её появлении и удаляется при вытеснении из кольца.

### 4.2 Ключ шифрования

- 256-битный `SymmetricKey`, генерируется один раз при первом запуске.
- Сырые 32 байта → base64 → строка в Keychain: `service = "Hopkey Clipboard"`,
  `account = "key"`, строгий ACL (дефолт `KeychainStore`).
- Читается один раз при `prepare()` в память, дальше — из кэша.
- Если записи ключа нет (первый запуск) — генерируем, пишем, используем.

## 5. Модель данных

Живёт в `HopkeyCore`, **без AppKit** (только Foundation) — как и весь core.

```swift
public enum ClipboardKind: String, Codable { case text, image }

/// Метаданные картинки. Сами байты (PNG) лежат отдельным файлом img-<id>.enc.
public struct ClipboardImageRef: Codable, Equatable {
    public let file: String       // "img-<uuid>.enc"
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let byteSize: Int       // размер расшифрованного PNG (для UI/лимитов)
}

public enum ClipboardEntry: Equatable {
    case text(String)
    case image(ClipboardImageRef, thumbnail: Data?)   // thumbnail — маленький PNG для строки списка
}
```

На диске (в `manifest.enc`) сериализуется промежуточная `StoredEntry`
(id + kind + text? + imageRef?), по образцу `StoredSnippet`. Публичный `ClipboardEntry` —
то, что отдаётся UI. Миниатюра (thumbnail) держится **в памяти**, на диск не пишется:
дешевле пере-генерировать из PNG при загрузке, чем усложнять формат (решение ниже, §11).

## 6. Компоненты

### 6.1 Новый файл: `Sources/HopkeyCore/ClipboardCrypto.swift`

Тонкая обёртка над `AES.GCM`. Тестируется round-trip'ом, без Keychain/диска.

```swift
public struct ClipboardCrypto {
    private let key: SymmetricKey
    public init(key: SymmetricKey)
    public static func generateKey() -> SymmetricKey                    // 256 бит
    public static func key(fromBase64: String) -> SymmetricKey?         // из Keychain
    public func base64(of key: SymmetricKey) -> String
    public func seal(_ plaintext: Data) throws -> Data                  // .combined
    public func open(_ ciphertext: Data) throws -> Data
}
```

### 6.2 Переписанный `Sources/HopkeyCore/ClipboardHistory.swift`

Из чистого in-memory кольца становится персистентным хранилищем. Публичный API,
насколько возможно, обратносовместим (`record(_:)` для текста, `clear()`, `entries`).

```swift
public final class ClipboardHistory {
    public init(
        capacity: Int = 100,
        maxImageBytes: Int = 16 * 1024 * 1024,
        directory: URL? = nil,                 // nil → App Support/Hopkey/clipboard (инъекция для тестов)
        keyStore: SnippetSecretStore = KeychainStore(service: "Hopkey Clipboard"),
        clock: () -> Date = Date.init          // инъекция для детерминизма тестов
    )

    public private(set) var entries: [ClipboardEntry]

    public func prepare()                                   // чтение ключа + манифеста + GC (лениво/идемпотентно)
    public func record(_ text: String)                     // текст
    public func record(imagePNG: Data, pixelWidth: Int, pixelHeight: Int)  // картинка
    public func clear()                                    // манифест + все img-файлы + кэш
}
```

- Замок `NSLock` вокруг кэша (как в `SnippetStore`): доступ идёт и с UI-потока, и с
  фонового опроса буфера.
- `id` картинок — UUID-строка (без `Date.now`/`Math.random`-проблем; `UUID()` доступен).
- Dedup: текст — по строке; картинка — по контенту PNG (сравнение байт), при повторе
  «всплывает» без дубля и **без** повторной записи файла.
- Вытеснение сверх `capacity`: хвост отбрасывается, а для картинок — соответствующие
  `img-*.enc` удаляются с диска.

### 6.3 `Sources/Hopkey/ClipboardWatcher.swift` (правка)

Сейчас читает только `.string`. Добавляем детекцию картинки:

```swift
var onChange: ((String) -> Void)?
var onImage: ((Data, NSPasteboard.PasteboardType) -> Void)?   // новое

private func poll() {
    // changeCount-guard как сейчас
    if let text = pasteboard.string(forType: .string), !text.isEmpty {
        onChange?(text); return                              // текст в приоритете — тикеты не ломаем
    }
    if let type = pasteboard.availableType(from: [.png, .tiff]),
       let data = pasteboard.data(forType: type), !data.isEmpty {
        onImage?(data, type)
    }
}
```

Приоритет текста сохраняет текущее поведение авто-детекта тикетов: у копий с текстом
изображение игнорируется (напр. rich-фрагмент), картинку берём только когда строки нет
(скрин, копирование из Preview/графики).

### 6.4 `Sources/Hopkey/AppDelegate.swift` (правка)

- `clipboard.onImage = { [weak self] data, type in self?.handleImage(data, type) }` рядом с
  `clipboard.onChange`.
- Новый `handleImage`:
  ```swift
  private func handleImage(_ data: Data, _ type: NSPasteboard.PasteboardType) {
      guard !clipboardIsConcealed() else { return }             // пароль-менеджеры — мимо
      guard let rep = NSBitmapImageRep(data: data),
            let png = rep.representation(using: .png, properties: [:]) else { return }
      clipboardHistory.record(imagePNG: png,
                              pixelWidth: rep.pixelsWide, pixelHeight: rep.pixelsHigh)
  }
  ```
  TIFF из буфера нормализуем в PNG здесь (AppKit-зона), в core уходит уже PNG.
- `clipboardHistory.prepare()` — вызвать при старте (лениво, до первого показа истории).
- `presentClipboardHistory` / `historyItems` — работают с `[ClipboardEntry]` (см. §6.5).
- `pasteHistory` разветвляется:
  ```swift
  private func pasteHistory(_ entry: ClipboardEntry) {
      switch entry {
      case .text(let t): /* текущий путь: hotKey.paste(t) */
      case .image(let ref, _):
          guard let png = clipboardHistory.imageData(for: ref) else { NSSound.beep(); return }
          // ensureAccessibility как сейчас
          hotKey.paste(pngData: png) { [weak self] in self?.clipboard.syncChangeCount() }
      }
  }
  ```
  Нужен геттер `ClipboardHistory.imageData(for ref:) -> Data?` (расшифровывает файл по
  запросу — картинки в память целиком не поднимаем, только миниатюры).

### 6.5 `Sources/Hopkey/HotKeyManager.swift` (правка)

Аналог `paste(_ text:)` для картинки — та же механика (сохранить буфер → положить своё →
синтез ⌘V → восстановить):

```swift
func paste(pngData: Data, completion: (() -> Void)? = nil) {
    whenModifiersCleared {
        let pb = NSPasteboard.general
        let saved = self.savedItems(of: pb)
        pb.clearContents()
        pb.setData(pngData, forType: .png)
        self.synthesizePaste()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            if AXIsProcessTrusted() { pb.clearContents(); if let saved, !saved.isEmpty { pb.writeObjects(saved) } }
            completion?()
        }
    }
}
```

### 6.6 `Sources/Hopkey/CommandPanelWindow.swift` (правка UI)

- `GlassListWindowController.historyItems` принимает `[ClipboardEntry]` и `onPaste: (ClipboardEntry) -> Void`.
  - `.text` → как сейчас (`HistoryRowView` с `historyPreview`).
  - `.image` → строка с миниатюрой + подпись `«Изображение · 320×240»`.
- `HistoryRowView` расширяется: опциональная `NSImageView`-миниатюра (24×24, скруглённая)
  между кейпадом и текстом; два альтернативных leading-констрейнта у текста (к кейпаду или
  к миниатюре), переключаются в `configure`.
- Цифры-хоткеи 1–9 работают одинаково для текста и картинок (уже по индексу).

### 6.7 Локализация

Новые ключи в обоих `Localizable.strings`:

| Ключ | ru | en |
|---|---|---|
| `clipboard.image` | «Изображение» | «Image» |

Подпись строки-картинки: `L("clipboard.image") + " · \(w)×\(h)"`.

## 7. Ключевые потоки

**Старт:** `prepare()` → прочитать ключ из Keychain (или сгенерировать+записать) → расшифровать
`manifest.enc` → собрать кэш `entries` → **GC**: удалить `img-*.enc`, на которые манифест не
ссылается (осиротевшие после сбоя между записью файла и манифеста), + прогреть миниатюры.

**Копирование текста:** `poll → onChange → handle(text)` — как сейчас: `record(text)` пишет в
кэш и пере-шифрует `manifest.enc`. Тикет-детект не тронут.

**Копирование картинки:** `poll → onImage → handleImage` → нормализация в PNG → `record(imagePNG:)`:
dedup по контенту; если новая — зашифровать в `img-<uuid>.enc` (однократно), добавить запись,
пере-шифровать манифест, сгенерировать миниатюру; вытеснить хвост (удалить его img-файлы).

**Вставка картинки:** выбор строки → `pasteHistory(.image)` → расшифровать файл по запросу →
`hotKey.paste(pngData:)`.

**Очистка:** `clear()` — удалить `manifest.enc`, все `img-*.enc`, обнулить кэш.

## 8. Лимиты и вытеснение

- Общее кольцо: `capacity = 100` (текст + картинки).
- Картинка > `maxImageBytes` (16 МБ, размер PNG) — **не** кладётся (тихо пропускается).
- Отдельного дискового потолка нет: 100 × 16 МБ = теоретический максимум ~1.6 ГБ, но на
  практике картинок в 100 слотах немного. При желании добавим общий дисковый бюджет позже
  (не в этой итерации — решение владельца: только per-image кап).

## 9. Обработка ошибок

- Нет ключа в Keychain → генерируем и пишем (первый запуск, не ошибка).
- `manifest.enc` не расшифровался (битый / ключ сменился) → лог `NSLog`, стартуем с пустой
  истории (как `SnippetStore.load` при битом блобе) — не падаем, не теряем работу приложения.
- `img-*.enc` не расшифровался при вставке → `NSSound.beep()`, запись остаётся в списке
  (или помечаем битой — см. открытый вопрос §12).
- Запись на диск не удалась → лог, кэш в памяти остаётся консистентным (история просто не
  переживёт рестарт — не критично).
- Все файловые/крипто-ошибки логируем, наружу не бросаем (UI не должен падать из-за истории).

## 10. Совместимость / миграция

На диске истории сейчас нет → миграции не требуется. Первый запуск новой версии: ключа и
файлов нет → генерируем ключ, история пустая, дальше наполняется.

## 11. Тест-план (`Tests/HopkeyCoreTests/`)

Существующие `ClipboardHistoryTests` **сломаются** (сейчас сравнивают `entries` с `[String]`).
Их надо переписать под `[ClipboardEntry]` (напр. хелпер `texts(of:)`), сохранив смысл кейсов.

Новые/обновлённые тесты (все с инъекцией temp-директории и in-memory `MemorySecretStore`,
как в `SnippetStoreTests`):

- `ClipboardCryptoTests`: seal→open round-trip; open чужого ciphertext бросает; ключ
  из/в base64.
- `ClipboardHistoryTests` (обновлённый):
  - текст: добавление в начало, dedup-всплытие, `capacity`, пусто/пробелы игнор, `clear`;
  - картинка: `record(imagePNG:)` добавляет запись + создаёт `img-*.enc`; dedup по контенту
    без второго файла; вытеснение удаляет img-файл с диска; `> maxImageBytes` не кладётся;
  - **персистентность**: новый экземпляр на той же директории+ключе читает те же записи и
    отдаёт `imageData(for:)`;
  - на диске лежит **ciphertext**, не плейнтекст (assert: файл не содержит исходной строки);
  - GC: подложить осиротевший `img-*.enc` → после `prepare()` он удалён;
  - битый `manifest.enc` → пустая история, без краха.

UI (`HistoryRowView`, вставка картинки) проверяется вручную в приложении — как и остальной
UI палитры (юнит-тестов на AppKit-слой в проекте нет).

## 12. Открытые вопросы

1. **Миниатюры на диск или регенерация?** Черновик: держать миниатюры в памяти,
   регенерировать из PNG при `prepare()` (проще формат). Альтернатива — писать миниатюру в
   манифест (быстрее старт при многих картинках, но манифест толстеет). Предлагаю
   регенерацию, порог пересмотра — если старт заметно тормозит.
2. **Битая картинка при вставке** — оставлять в списке или авто-удалять запись? Черновик:
   оставить + beep (не удаляем данные молча).
3. **Общий дисковый бюджет** — сейчас только per-image кап (по решению владельца). Оставляем
   задел, но не реализуем.
```
