import Carbon.HIToolbox
import Foundation

/// Идентификатор команды тулбокса. Один общий реестр команд обслуживает меню статус-бара,
/// прямые глобальные хоткеи и панель команд — добавление новой возможности сводится к новому
/// кейсу здесь + (опц.) контроллеру + строкам локализации, без копипасты по конфигу.
///
/// `allCases` перечисляет только реализованные команды: по нему строятся UI и регистрация
/// хоткеев, поэтому «зарезервированных» кейсов-заглушек тут быть не должно.
public enum CommandID: String, CaseIterable, Codable {
    /// Окно ручного ввода тикета (бывший `showInputHotKey`).
    case quickInput
    /// Пикер сниппетов (бывший `snippetsHotKey`).
    case snippets
    /// Тумблер мьюта микрофона (CoreAudio).
    case micToggle
    /// Тумблер «не давать засыпать» (IOKit power assertion).
    case keepAwake
    /// Вставить содержимое буфера без форматирования.
    case pastePlain
    /// Открыть отдельное окно истории буфера обмена.
    case clipboardHistory
    /// Преобразовать выделенный текст (регистр, JSON, URL, Base64, строки…).
    case textTransform
    /// Переключить аудиовыход (пикер устройств).
    case audioOutput
    /// Переключить аудиовход/микрофон (пикер устройств).
    case audioInput
    /// Распознать текст с области экрана (screencapture -i + Vision) и скопировать в буфер.
    case ocr
}

extension CommandID {
    /// Физический код клавиши (kVK_ANSI_*) быстрого выбора команды в панели. Инструменты сидят
    /// на буквах, а не на цифрах 1–9: цифры целиком отданы сниппетам (переменному списку), а
    /// фиксированный набор команд получает стабильные мнемоники, не «съезжающие» при добавлении
    /// сниппета. Матчим и рисуем именно по физическому коду (US-ANSI), а не по символу события:
    /// под кириллицей `charactersIgnoringModifiers` вернёт «ь» вместо «M» и матч по букве отвалится.
    /// Бейдж-буква выводится из этого же кода через `keyName(forKeyCode:)`.
    ///
    /// Коды уникальны по всем командам и не пересекаются со служебными клавишами панели
    /// (↩ 36/76, Esc 53, Tab 48, стрелки 123–126) — это проверяет `CommandBindingTests`.
    public var panelKeyCode: UInt16 {
        switch self {
        case .micToggle:        return UInt16(kVK_ANSI_M)  // Mic
        case .keepAwake:        return UInt16(kVK_ANSI_K)  // Keep-awake
        case .pastePlain:       return UInt16(kVK_ANSI_V)  // ⌘V-мнемоника вставки
        case .clipboardHistory: return UInt16(kVK_ANSI_C)  // Clipboard
        case .textTransform:    return UInt16(kVK_ANSI_T)  // Transform
        case .audioOutput:      return UInt16(kVK_ANSI_O)  // Output
        case .audioInput:       return UInt16(kVK_ANSI_I)  // Input
        case .ocr:              return UInt16(kVK_ANSI_R)  // Recognize
        case .quickInput:       return UInt16(kVK_ANSI_Q)  // Quick input
        case .snippets:         return UInt16(kVK_ANSI_S)  // Snippets
        }
    }
}
