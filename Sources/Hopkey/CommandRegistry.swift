import AppKit
import HopkeyCore

/// Одна команда тулбокса — общий элемент для меню статус-бара, панели команд и прямого хоткея.
/// Собирается в `AppDelegate` (там живут зависимости — контроллеры и действия), поэтому это
/// лёгкий value-тип с замыканиями, а не иерархия классов. `isOn() != nil` → тумблер.
struct ToolboxCommand {
    let id: CommandID
    /// Нужен ли Accessibility (влияет на запрос доступа при включении хоткея).
    let needsAccessibility: Bool
    /// Локализованный заголовок; может зависеть от состояния (мьют «включить/выключить»).
    let title: () -> String
    /// SF Symbol; может зависеть от состояния (`mic` / `mic.slash`).
    let symbol: () -> String
    /// Текущее состояние тумблера; `nil` — разовое действие (не тумблер).
    let isOn: () -> Bool?
    /// Трейлинг-подсказка справа в строке (напр. прямой хоткей лончера); `nil` — нет.
    /// У тумблеров вместо неё строка сама рисует статус по `isOn()`.
    let trailing: () -> String?
    /// Выполнить команду.
    let run: () -> Void
}

/// Зоны панели: тумблеры / разовые действия / команды-с-вводом. Разводя команды по секциям,
/// убираем промежуточный «выбор из однородного списка» — глаз метит сразу в нужную зону.
enum CommandSection: Int, CaseIterable {
    case toggles
    case actions
    case launchers

    var titleKey: String {
        switch self {
        case .toggles: return "panel.section.toggles"
        case .actions: return "panel.section.actions"
        case .launchers: return "panel.section.launchers"
        }
    }
}

extension CommandID {
    /// Стабильный id для Carbon-регистрации хоткея (не пересекается между командами; 3/4 —
    /// исторические id окна ввода и пикера сниппетов, сохранены ради совместимости).
    var hotKeyID: UInt32 {
        switch self {
        case .quickInput: return 3
        case .snippets:   return 4
        case .micToggle:        return 5
        case .keepAwake:        return 6
        case .pastePlain:       return 7
        case .clipboardHistory: return 8
        case .textTransform:    return 9
        case .audioOutput:      return 10
        case .audioInput:       return 11
        case .ocr:              return 12
        case .notes:            return 13
        }
    }

    /// В какую зону панели попадает команда.
    var section: CommandSection {
        switch self {
        case .micToggle, .keepAwake:
            return .toggles
        case .pastePlain, .clipboardHistory, .textTransform, .audioOutput, .audioInput, .ocr:
            return .actions
        case .quickInput, .snippets, .notes:
            return .launchers
        }
    }

    /// Цветовой акцент чипа-иконки в палитре: кодирует смысл команды (поиск — синий, буфер —
    /// индиго, OCR — оранжевый…), даёт быстрый визуальный якорь по цвету. Тумблеры красятся по
    /// состоянию (см. `CommandTileView`), поэтому свой фиксированный тон им не нужен — тут нейтраль.
    var paletteTint: NSColor {
        switch self {
        case .quickInput:            return .systemBlue
        case .clipboardHistory:      return .systemIndigo
        case .textTransform:         return .systemPurple
        case .pastePlain:            return .systemTeal
        case .ocr:                   return .systemOrange
        case .audioOutput, .audioInput: return .systemBlue
        case .snippets, .notes:      return .systemBlue
        case .micToggle, .keepAwake: return .secondaryLabelColor
        }
    }
}
