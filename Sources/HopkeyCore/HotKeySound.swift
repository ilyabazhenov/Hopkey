import Foundation

/// Пресет системного звука для обратной связи при срабатывании глобальных хоткеев.
///
/// `rawValue` стабилен — он используется как значение в `UserDefaults`.
public enum HotKeySound: String, CaseIterable {
    case pop
    case tink
    case purr
    case glass
    case ping
    case bottle
    case blow
    case submarine

    /// Имя звука в `/System/Library/Sounds/` (без расширения).
    public var systemName: String {
        switch self {
        case .pop: "Pop"
        case .tink: "Tink"
        case .purr: "Purr"
        case .glass: "Glass"
        case .ping: "Ping"
        case .bottle: "Bottle"
        case .blow: "Blow"
        case .submarine: "Submarine"
        }
    }

    /// Ключ локализации для названия в настройках (`settings.hotkey.sound.*`).
    public var localizationKey: String { "settings.hotkey.sound.\(rawValue)" }

    public static let `default`: HotKeySound = .bottle
}
