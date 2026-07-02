import Foundation

/// Привязка команды к глобальной комбинации: включена ли, код клавиши и модификаторы
/// (в Carbon-формате — как их принимает `RegisterEventHotKey`). Хранится по одной записи
/// на команду в общем JSON-словаре `JiraConfig` (см. `binding(for:)`).
public struct HotKeyBinding: Codable, Equatable {
    public var enabled: Bool
    /// Код клавиши (`kVK_*`). 0 — комбинация не задана (живёт только в панели).
    public var keyCode: Int
    /// Модификаторы в Carbon-формате (cmdKey/shiftKey/optionKey/controlKey).
    public var modifiers: Int

    public init(enabled: Bool, keyCode: Int, modifiers: Int) {
        self.enabled = enabled
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Годна ли комбинация для регистрации: есть хотя бы один модификатор (иначе перехват
    /// голой клавиши ломал бы обычный ввод — та же проверка, что в `HotKeyRecorderView`).
    public var isValid: Bool { modifiers != 0 }

    /// Годится ли для регистрации прямого хоткея: включена и валидна.
    public var isRegisterable: Bool { enabled && isValid }
}

/// Carbon-биты модификаторов. Держим их здесь как литералы (HopkeyCore не тянет Carbon),
/// значения совпадают с `cmdKey`/`shiftKey`/`optionKey`/`controlKey` из HIToolbox.
public enum CarbonModifier {
    public static let command = 0x0100
    public static let shift = 0x0200
    public static let option = 0x0800
    public static let control = 0x1000
}
