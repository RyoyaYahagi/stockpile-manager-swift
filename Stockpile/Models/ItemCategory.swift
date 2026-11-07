import Foundation

/// 備蓄品のジャンル。
/// 保存値は `rawValue` を使い、表示名は端末の言語に合わせて `displayName` で解決する。
enum ItemCategory: String, CaseIterable, Identifiable, Codable {
    case waterDrink
    case stapleFood
    case sideDish
    case snackSupplement
    case hygiene
    case medicine
    case powerLight
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .waterDrink: return L10n.string("水・飲料")
        case .stapleFood: return L10n.string("主食")
        case .sideDish: return L10n.string("おかず・缶詰")
        case .snackSupplement: return L10n.string("お菓子・栄養補助")
        case .hygiene: return L10n.string("衛生用品")
        case .medicine: return L10n.string("医薬品")
        case .powerLight: return L10n.string("電池・電源・照明")
        case .other: return L10n.string("その他のジャンル")
        }
    }

    var systemImage: String {
        switch self {
        case .waterDrink: return "drop.fill"
        case .stapleFood: return "fork.knife"
        case .sideDish: return "takeoutbag.and.cup.and.straw.fill"
        case .snackSupplement: return "birthday.cake.fill"
        case .hygiene: return "sparkles"
        case .medicine: return "cross.case.fill"
        case .powerLight: return "bolt.fill"
        case .other: return "shippingbox.fill"
        }
    }
}

/// 品名や商品検索のジャンル文字列から、備蓄品のジャンルを推定する。
/// 保存値がない既存データの表示と、新規登録時の初期値にだけ使う。
enum ItemCategoryInference {
    private struct Rule {
        let category: ItemCategory
        let keywords: [String]
    }

    /// 上から順に評価し、最初に一致したジャンルを返す。
    /// 具体的な語を先に、汎用的な語を後に置く。
    private static let rules: [Rule] = [
        Rule(
            category: .medicine,
            keywords: [
                "医薬品", "薬", "救急", "絆創膏", "ばんそうこう", "包帯", "体温計",
                "解熱", "鎮痛", "胃薬", "風邪薬", "目薬", "湿布", "消毒液", "消毒",
                "medicine", "first aid", "bandage", "thermometer"
            ]
        ),
        Rule(
            category: .hygiene,
            keywords: [
                "衛生", "マスク", "ウェットティッシュ", "ウエットティッシュ", "ティッシュ",
                "トイレットペーパー", "トイレ", "おむつ", "オムツ", "生理", "ナプキン",
                "歯ブラシ", "歯磨き", "石けん", "石鹸", "シャンプー", "洗剤", "タオル",
                "綿棒", "ゴミ袋", "手袋", "hygiene", "mask", "sanitizer", "tissue",
                "toilet paper", "soap", "shampoo", "toothbrush", "diaper"
            ]
        ),
        Rule(
            category: .powerLight,
            keywords: [
                "電池", "乾電池", "充電池", "バッテリー", "モバイルバッテリー", "充電",
                "電源", "発電", "ソーラー", "ポータブル電源", "懐中電灯", "ライト",
                "ランタン", "ろうそく", "ロウソク", "マッチ", "ライター", "照明",
                "ボンベ", "ラジオ",
                "battery", "batteries", "charger", "flashlight", "lantern", "candle",
                "power", "light"
            ]
        ),
        Rule(
            category: .waterDrink,
            keywords: [
                "飲料", "飲料水", "ミネラルウォーター", "経口補水", "スポーツドリンク",
                "ジュース", "ドリンク", "お茶", "茶", "コーヒー", "コーラ", "水", "酒",
                "water", "drink", "beverage", "juice", "tea", "coffee", "soda"
            ]
        ),
        Rule(
            category: .stapleFood,
            keywords: [
                "主食", "アルファ米", "ご飯", "ごはん", "炊飯", "米", "パン", "麺",
                "うどん", "そば", "パスタ", "スパゲッティ", "ラーメン", "カップ麺",
                "即席", "インスタント", "オートミール", "シリアル", "グラノーラ",
                "小麦粉", "ホットケーキ", "餅", "保存食",
                "rice", "bread", "noodle", "pasta", "oatmeal", "cereal", "flour"
            ]
        ),
        Rule(
            category: .sideDish,
            keywords: [
                "おかず", "惣菜", "缶詰", "缶", "ツナ", "サバ", "いわし", "コーン",
                "トマト缶", "レトルト", "カレー", "シチュー", "丼", "ソーセージ",
                "ハム", "ベーコン", "焼鳥", "やきとり", "調味料",
                "canned", "can", "retort", "curry", "tuna", "sardine", "sausage"
            ]
        ),
        Rule(
            category: .snackSupplement,
            keywords: [
                "お菓子", "菓子", "チョコ", "ビスケット", "クッキー", "飴", "キャンディ",
                "グミ", "ナッツ", "ドライフルーツ", "羊羹", "ようかん", "栄養",
                "補助", "サプリ", "プロテイン", "ゼリー", "エネルギーバー",
                "カロリーメイト",
                "snack", "cookie", "chocolate", "candy", "supplement", "protein",
                "energy bar"
            ]
        )
    ]

    /// 品名を優先し、見つからなければ商品検索のジャンル文字列を使う。
    static func category(forName name: String?, productCategory: String? = nil) -> ItemCategory? {
        if let name, let category = category(in: name) {
            return category
        }
        if let productCategory, let category = category(in: productCategory) {
            return category
        }
        return nil
    }

    static func category(forName name: String) -> ItemCategory? {
        category(in: name)
    }

    static func category(forProductCategory productCategory: String) -> ItemCategory? {
        category(in: productCategory)
    }

    /// ルールごとの正規表現。キーワードをまとめた 1 本を起動時に 1 回だけ組み立てる。
    /// 日本語は部分一致、英語は単語境界で照合する（candy に can が当たる等を避ける）。
    private static let compiledRules: [(category: ItemCategory, pattern: NSRegularExpression)] = rules.map { rule in
        let alternatives = rule.keywords.map { keyword -> String in
            let escaped = NSRegularExpression.escapedPattern(for: keyword)
            if keyword.unicodeScalars.allSatisfy(\.isASCII) {
                return "\\b\(escaped)\\b"
            }
            return escaped
        }
        // エスケープ済みのリテラルだけを連結するため、パターンは必ず妥当
        let pattern = try! NSRegularExpression(
            pattern: alternatives.joined(separator: "|"),
            options: [.caseInsensitive]
        )
        return (rule.category, pattern)
    }

    /// 正規化した品名ごとの推定結果。
    /// 画面の再描画やジャンルごとの振り分けで、同じ品名を何度も推定しない。
    private static let cache = InferenceCache()

    private static func category(in text: String) -> ItemCategory? {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: .current
            )
        guard !normalized.isEmpty else { return nil }

        if let cached = cache.result(for: normalized) {
            return cached.category
        }

        let category = infer(in: normalized)
        cache.store(InferenceResult(category: category), for: normalized)
        return category
    }

    private static func infer(in normalized: String) -> ItemCategory? {
        let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        for rule in compiledRules {
            if rule.pattern.firstMatch(in: normalized, options: [], range: range) != nil {
                return rule.category
            }
        }
        return nil
    }

    private struct InferenceResult {
        let category: ItemCategory?
    }

    /// 推定結果のキャッシュ。画面更新とバックグラウンドの同期から同時に呼ばれるため、
    /// ロックで保護する。
    private final class InferenceCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: InferenceResult] = [:]
        /// 際限なく増やさないための上限。超えたらまとめて捨てる
        private let limit = 4096

        func result(for key: String) -> InferenceResult? {
            lock.lock()
            defer { lock.unlock() }
            return entries[key]
        }

        func store(_ result: InferenceResult, for key: String) {
            lock.lock()
            defer { lock.unlock() }
            if entries.count >= limit {
                entries.removeAll(keepingCapacity: true)
            }
            entries[key] = result
        }
    }
}

extension ItemCategoryInference {
    /// 保存値がないときの表示用ジャンル。推定できなければ「その他」。
    static func resolvedCategory(storedCategory: String?, name: String) -> ItemCategory {
        if let storedCategory,
           let category = ItemCategory(rawValue: storedCategory) {
            return category
        }
        return category(forName: name) ?? .other
    }
}
