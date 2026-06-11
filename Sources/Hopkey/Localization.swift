import Foundation

/// Локализованная строка из `Localizable.strings` (ресурс-бандл таргета, см. `Resources/*.lproj`).
///
/// Язык выбирается системой по списку предпочитаемых языков пользователя; есть
/// английская и русская локализации, фолбэк — английский (`defaultLocalization`).
/// Все видимые пользователю строки приложения проходят через `L(_:_:)` — литералов
/// в UI-коде быть не должно (исключение — технические/лог-сообщения и `fatalError`).
///
/// Плейсхолдеры в значениях — `%@`; аргументы подставляются через `String(format:)`.
/// Передавайте числа как строки: `L("notif.open.many", "\(count)")`.
func L(_ key: String, _ args: CVarArg...) -> String {
    let format = NSLocalizedString(key, bundle: .module, comment: "")
    return args.isEmpty ? format : String(format: format, arguments: args)
}

/// Выбор языка интерфейса из окна настроек поверх системного.
///
/// `.system` — без переопределения: язык берётся из системного списка предпочитаемых
/// языков (как по умолчанию). `.ru`/`.en` — жёстко фиксируют язык приложения, записывая
/// `AppleLanguages` в домен `UserDefaults` приложения. AppKit читает этот список **только
/// при старте**, поэтому смена применяется после перезапуска (см. `LanguageSettings.apply`).
enum AppLanguage: String, CaseIterable {
    case system, ru, en

    /// Свой флаг выбора: по самому `AppleLanguages` нельзя отличить «системный» от
    /// явно выбранного — без переопределения он всё равно возвращает системный список.
    private static let overrideKey = "HopkeyLanguageOverride"
    private static let appleLanguagesKey = "AppleLanguages"

    /// Текущий выбор (для предзаполнения попапа). По умолчанию — системный.
    static var current: AppLanguage {
        guard let raw = UserDefaults.standard.string(forKey: overrideKey) else { return .system }
        return AppLanguage(rawValue: raw) ?? .system
    }

    /// Применяет выбор к домену приложения. Вступит в силу при следующем запуске.
    func apply() {
        let defaults = UserDefaults.standard
        defaults.set(rawValue, forKey: Self.overrideKey)
        switch self {
        case .system:
            defaults.removeObject(forKey: Self.appleLanguagesKey)
        case .ru, .en:
            defaults.set([rawValue], forKey: Self.appleLanguagesKey)
        }
    }

    /// Подпись пункта попапа. Эндонимы (`Русский`, `English`) не переводим — их принято
    /// показывать на родном языке в любом интерфейсе; локализуется только «системный».
    var title: String {
        switch self {
        case .system: return L("language.system")
        case .ru: return "Русский"
        case .en: return "English"
        }
    }
}
