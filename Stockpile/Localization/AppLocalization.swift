import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case japanese = "ja"
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case korean = "ko"
    case french = "fr"
    case german = "de"
    case spanish = "es"

    static let storageKey = "settings.appLanguage"

    var id: String { rawValue }

    var locale: Locale {
        switch self {
        case .system:
            return .autoupdatingCurrent
        default:
            return Locale(identifier: rawValue)
        }
    }

    var displayName: String {
        switch self {
        case .system:
            return L10n.string("システムの言語")
        case .japanese:
            return "日本語"
        case .english:
            return "English"
        case .simplifiedChinese:
            return "简体中文"
        case .traditionalChinese:
            return "繁體中文"
        case .korean:
            return "한국어"
        case .french:
            return "Français"
        case .german:
            return "Deutsch"
        case .spanish:
            return "Español"
        }
    }

    static var current: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .system
    }

    static var currentLocale: Locale {
        current.locale
    }

    static var currentLanguageCandidates: [String] {
        normalizedLanguageCandidates(
            from: current == .system
                ? Locale.preferredLanguages + [Locale.current.identifier]
                : [current.rawValue]
        )
    }

    static var currentPrimaryLanguageCode: String {
        let identifier = currentLanguageCandidates.first ?? "ja"
        return identifier.split(separator: "-").first.map(String.init) ?? "ja"
    }

    private static func normalizedLanguageCandidates(from identifiers: [String]) -> [String] {
        var candidates: [String] = []

        for identifier in identifiers {
            let normalized = identifier.replacingOccurrences(of: "_", with: "-")
            candidates.append(normalized)
            if let primary = normalized.split(separator: "-").first {
                candidates.append(String(primary))
            }
        }

        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }
}

enum AppLocalization {
    static func bundle(for language: AppLanguage = .current) -> Bundle {
        for identifier in languageCandidates(for: language) {
            if let bundle = bundle(forLocalizationIdentifier: identifier) {
                return bundle
            }
        }
        return .main
    }

    private static func languageCandidates(for language: AppLanguage) -> [String] {
        switch language {
        case .system:
            return AppLanguage.currentLanguageCandidates
        default:
            return [language.rawValue]
        }
    }

    private static func bundle(forLocalizationIdentifier identifier: String) -> Bundle? {
        if let path = Bundle.main.path(forResource: identifier, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle
        }

        if let primary = identifier.split(separator: "-").first {
            let fallback = String(primary)
            if let path = Bundle.main.path(forResource: fallback, ofType: "lproj"),
               let bundle = Bundle(path: path) {
                return bundle
            }
        }

        return nil
    }
}

enum L10n {
    static func string(_ key: String, table: String? = nil) -> String {
        AppLocalization.bundle().localizedString(forKey: key, value: key, table: table)
    }

    static func format(_ key: String, _ arguments: CVarArg..., table: String? = nil) -> String {
        format(key, arguments, table: table)
    }

    static func format(_ key: String, _ arguments: [CVarArg], table: String? = nil) -> String {
        let template = string(key, table: table)
        return String(format: template, locale: AppLanguage.currentLocale, arguments: arguments)
    }
}
