import Foundation

/// Левый или правый вариант модификатора важно различать для двойного тапа: жест вешается на
/// конкретную физическую клавишу. Правые модификаторы «простаивают» (ими редко жмут шорткаты) —
/// меньше ложных срабатываний; левый ⌘ удобнее дотянуться, но участвует в ⌘C/⌘V и т.п. (детектор
/// срывает жест на любой другой клавише, так что настоящий ⌘C триггером не станет).
/// `keyCode` — код конкретной физической клавиши в событии `.flagsChanged` (левый/правый
/// различаются именно по keyCode, не по флагу).
public enum ModifierSide: String, CaseIterable {
    case leftCommand
    case rightCommand
    case leftOption
    case rightOption

    public var keyCode: Int {
        switch self {
        case .leftCommand:  return 55  // kVK_Command
        case .rightCommand: return 54  // kVK_RightCommand
        case .leftOption:   return 58  // kVK_Option
        case .rightOption:  return 61  // kVK_RightOption
        }
    }
}

/// Как вызывается панель команд. По умолчанию — двойной тап правого ⌘.
/// Хранится в `UserDefaults` строкой (`rawValue`), как `TicketAction`.
public enum PaletteTrigger: Equatable {
    case doubleTap(ModifierSide)
    case disabled

    public static let `default`: PaletteTrigger = .doubleTap(.rightCommand)
}

extension PaletteTrigger: RawRepresentable {
    public init?(rawValue: String) {
        if rawValue == "disabled" {
            self = .disabled
            return
        }
        let parts = rawValue.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0] == "doubleTap",
              let side = ModifierSide(rawValue: parts[1]) else { return nil }
        self = .doubleTap(side)
    }

    public var rawValue: String {
        switch self {
        case .disabled: return "disabled"
        case .doubleTap(let side): return "doubleTap:\(side.rawValue)"
        }
    }
}
