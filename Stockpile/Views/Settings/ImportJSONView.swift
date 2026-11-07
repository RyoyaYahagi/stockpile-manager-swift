import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct BackupImportPayload: Decodable {
    let name: String
    let janCode: String?
    let quantity: Int?
    let expiryDate: String?
    let bagName: String?
    let locationNote: String?
    let category: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        janCode =
            try container.decodeIfPresent(String.self, forKey: .janCode)
            ?? container.decodeIfPresent(String.self, forKey: .jan)
            ?? container.decodeIfPresent(String.self, forKey: .barcode)
        quantity = try container.decodeIfPresent(Int.self, forKey: .quantity)
        expiryDate = try container.decodeIfPresent(String.self, forKey: .expiryDate)
        locationNote = try container.decodeIfPresent(String.self, forKey: .locationNote)
        category = try container.decodeIfPresent(String.self, forKey: .category)
        bagName =
            try container.decodeIfPresent(String.self, forKey: .bagName)
            ?? container.decodeIfPresent(String.self, forKey: .bagname)
            ?? container.decodeIfPresent(String.self, forKey: .bag_name)
            ?? container.decodeIfPresent(String.self, forKey: .storageName)
    }

    /// 既知のジャンルだけを保存値として採用する。未知の値は未設定として扱う。
    var resolvedCategory: String? {
        guard let category else { return nil }
        let trimmed = category.trimmingCharacters(in: .whitespacesAndNewlines)
        return ItemCategory(rawValue: trimmed)?.rawValue
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case janCode
        case jan
        case barcode
        case quantity
        case expiryDate
        case locationNote
        case category
        case bagName
        case bagname
        case bag_name
        case storageName
    }
}

/// バックアップ書き出しの1件分。読み込み側の `BackupImportPayload` と対になる。
struct BackupExportItem: Encodable {
    let name: String
    let janCode: String?
    let quantity: Int
    let expiryDate: String?
    let bagName: String?
    let locationNote: String?
    let category: String?

    init(item: Item, dateFormatter: DateFormatter) {
        name = item.name
        janCode = item.janCode
        quantity = item.quantity
        expiryDate = item.expiryDate.map { dateFormatter.string(from: $0) }
        bagName = item.bag?.name
        locationNote = item.locationNote
        category = item.category
    }
}

enum BackupJSONCodec {
    static func makeExportData(from items: [Item]) throws -> Data {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let payload = items.map { BackupExportItem(item: $0, dateFormatter: formatter) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(payload)
    }
}

enum BackupImportValidator {
    static let maximumFileSize = 5 * 1_024 * 1_024
    static let maximumItemCount = 5_000
    static let maximumNameLength = 200
    static let maximumJANLength = 32
    static let maximumBagNameLength = 200
    static let maximumLocationNoteLength = 2_000
    static let validQuantityRange = 1...999_999

    enum ValidationError: LocalizedError {
        case fileTooLarge
        case tooManyItems
        case emptyName(index: Int)
        case fieldTooLong(field: String, index: Int)
        case invalidQuantity(index: Int)
        case invalidExpiryDate(index: Int)

        var errorDescription: String? {
            switch self {
            case .fileTooLarge:
                return "バックアップファイルは5MB以下にしてください"
            case .tooManyItems:
                return "一度に復元できるアイテムは5,000件までです"
            case .emptyName(let index):
                return "\(index + 1)件目のアイテム名が空です"
            case .fieldTooLong(let field, let index):
                return "\(index + 1)件目の\(field)が長すぎます"
            case .invalidQuantity(let index):
                return "\(index + 1)件目の数量は1から999,999の範囲で指定してください"
            case .invalidExpiryDate(let index):
                return "\(index + 1)件目の期限はyyyy-MM-dd形式で指定してください"
            }
        }
    }

    static func decodeAndValidate(_ data: Data) throws -> [BackupImportPayload] {
        guard data.count <= maximumFileSize else {
            throw ValidationError.fileTooLarge
        }

        let payloads = try JSONDecoder().decode([BackupImportPayload].self, from: data)
        guard payloads.count <= maximumItemCount else {
            throw ValidationError.tooManyItems
        }

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.isLenient = false

        for (index, payload) in payloads.enumerated() {
            let name = payload.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw ValidationError.emptyName(index: index) }
            guard name.count <= maximumNameLength else {
                throw ValidationError.fieldTooLong(field: "アイテム名", index: index)
            }
            if let janCode = payload.janCode, janCode.count > maximumJANLength {
                throw ValidationError.fieldTooLong(field: "JANコード", index: index)
            }
            if let bagName = payload.bagName, bagName.count > maximumBagNameLength {
                throw ValidationError.fieldTooLong(field: "収納場所名", index: index)
            }
            if let locationNote = payload.locationNote,
               locationNote.count > maximumLocationNoteLength {
                throw ValidationError.fieldTooLong(field: "位置メモ", index: index)
            }
            if let quantity = payload.quantity, !validQuantityRange.contains(quantity) {
                throw ValidationError.invalidQuantity(index: index)
            }
            if let expiryDate = payload.expiryDate,
               dateFormatter.date(from: expiryDate) == nil {
                throw ValidationError.invalidExpiryDate(index: index)
            }
        }

        return payloads
    }
}

/// バックアップ復元ビュー
struct ImportJSONView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(PremiumAccessManager.self) private var premiumAccessManager
    @Query(sort: \Family.createdAt, order: .reverse) private var families: [Family]
    
    @State private var isImporting = false
    @State private var importResult: ImportResult?
    @State private var pendingImportPayloads: [BackupImportPayload] = []
    @State private var showSharedRestoreOptions = false
    
    enum ImportResult {
        case success(String)
        case error(String)
    }

    private var currentFamily: Family? {
        CurrentFamilyResolver.currentFamily(from: families)
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    BackupHeaderCard(
                        icon: "square.and.arrow.down",
                        title: "バックアップから復元",
                        subtitle: "バックアップファイルから備蓄品データをまとめて復元します"
                    )
                    .riseIn(index: 0)

                    if let result = importResult {
                        resultView(result)
                    }

                    BackupSampleCard(text: formatExample)
                        .riseIn(index: 1)

                    warningCard(
                        title: "信頼できるバックアップだけを復元してください",
                        message: "JSON の内容はそのまま端末内データとして保存されます。受け取り元が不明なファイルは取り込まないでください。"
                    )
                    .riseIn(index: 2)

                    Button {
                        isImporting = true
                    } label: {
                        Label("ファイルを選択", systemImage: "folder")
                            .font(.headline)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(PrimaryActionButtonStyle())
                    .riseIn(index: 3)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .appScreenBackground()
            .tint(AppTheme.accent)
            .navigationTitle("バックアップから復元")
            .navigationBarTitleDisplayMode(.inline)
            .localizedRefresh()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") {
                        dismiss()
                    }
                }
            }
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [.json],
                onCompletion: handleFileImport
            )
            .sheet(
                isPresented: $showSharedRestoreOptions,
                onDismiss: clearPendingRestoreChoice
            ) {
                sharedRestoreOptionsSheet
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
                    .presentationCornerRadius(28)
            }
        }
        .premiumPaywallSheet()
    }
    
    private var formatExample: String {
        """
        [
          {
            "name": "Canned Food",
            "quantity": 3,
            "expiryDate": "2025-12-31",
            "bagName": "Emergency Bag",
            "locationNote": "Top shelf",
            "category": "waterDrink"
          }
        ]
        """
    }
    
    @ViewBuilder
    private func resultView(_ result: ImportResult) -> some View {
        switch result {
        case .success(let message):
            BackupResultBanner(isSuccess: true, message: message)

        case .error(let message):
            BackupResultBanner(isSuccess: false, message: message)
        }
    }
    
    private func handleFileImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            do {
                guard url.startAccessingSecurityScopedResource() else {
                    importResult = .error(L10n.string("ファイルにアクセスできません"))
                    return
                }
                defer { url.stopAccessingSecurityScopedResource() }
                
                let data = try Data(contentsOf: url)
                let payloads = try decodeImportPayloads(from: data)

                if let family = currentFamily, family.isCloudKitSharedFamily {
                    pendingImportPayloads = payloads
                    showSharedRestoreOptions = true
                    return
                }

                Task {
                    await restoreImportPayloads(
                        payloads,
                        into: currentFamily,
                        syncToCloudKit: false,
                        successMessage: { count in
                            L10n.format("%@件のアイテムを復元しました", String(count))
                        }
                    )
                }
                
            } catch {
                importResult = .error(L10n.format("復元に失敗しました: %@", error.localizedDescription))
            }
            
        case .failure(let error):
            importResult = .error(L10n.format("バックアップファイルの選択に失敗しました: %@", error.localizedDescription))
        }
    }
    
    private var sharedRestoreDialogMessage: String {
        let familyName = currentFamily?.name ?? L10n.string("現在の家族")
        return L10n.format(
            "現在は「%@」が iCloud共有中です。%@件の復元データを、この端末だけに戻すか、iCloud共有データとして反映するかを選んでください。",
            familyName,
            String(pendingImportPayloads.count)
        )
    }

    private var sharedRestoreOptionsSheet: some View {
        VStack(alignment: .leading, spacing: 20) {
            Capsule()
                .fill(AppTheme.ink.opacity(0.18))
                .frame(width: 36, height: 5)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)

            VStack(alignment: .leading, spacing: 10) {
                Label("復元先を選択", systemImage: "arrow.triangle.branch")
                    .font(.title3.bold())
                    .foregroundStyle(AppTheme.ink)

                Text(sharedRestoreDialogMessage)
                    .font(.body)
                    .foregroundStyle(AppTheme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 12) {
                sharedRestoreOptionButton(
                    title: "この端末だけに復元",
                    subtitle: "新しいローカル家族を作って、共有データとは切り離して戻します。",
                    badge: "推奨",
                    tint: AppTheme.accent
                ) {
                    Task {
                        await restorePendingPayloadsLocally()
                    }
                }

                sharedRestoreOptionButton(
                    title: "iCloud共有データとして復元",
                    subtitle: "この復元内容を共有データへ反映し、ほかの参加端末にも同期します。",
                    tint: AppTheme.color(for: .imminent)
                ) {
                    Task {
                        await restorePendingPayloadsToCurrentSharedFamily()
                    }
                }
            }

            Button("キャンセル") {
                clearPendingRestoreChoice()
            }
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.vertical, 4)
            .foregroundStyle(AppTheme.inkSecondary)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .background { AppBackground() }
    }

    private func restorePendingPayloadsLocally() async {
        let payloads = pendingImportPayloads
        clearPendingRestoreChoice()

        guard projectedBagCount(
            for: payloads,
            targetFamily: nil,
            includeExistingData: false
        ) <= PremiumAccessManager.freeBagLimit
            || premiumAccessManager.hasPremiumAccess else {
            premiumAccessManager.presentPaywall(for: .bagLimit) {
                Task {
                    await self.restorePendingPayloadsLocally(with: payloads)
                }
            }
            return
        }

        await restorePendingPayloadsLocally(with: payloads)
    }

    private func restorePendingPayloadsLocally(with payloads: [BackupImportPayload]) async {
        let localFamily = makeLocalRestoreFamily()
        await restoreImportPayloads(
            payloads,
            into: localFamily,
            syncToCloudKit: false,
            successMessage: { count in
                L10n.format(
                    "%@件のアイテムを「%@」へローカル復元しました",
                    String(count),
                    localFamily.name
                )
            }
        )
    }

    private func restorePendingPayloadsToCurrentSharedFamily() async {
        let payloads = pendingImportPayloads
        let targetFamily = currentFamily
        clearPendingRestoreChoice()

        guard let targetFamily else {
            importResult = .error(L10n.string("復元先の家族を特定できませんでした"))
            return
        }

        await restoreImportPayloads(
            payloads,
            into: targetFamily,
            syncToCloudKit: true,
            successMessage: { count in
                L10n.format(
                    "%@件のアイテムを復元し、iCloud共有データを更新しました",
                    String(count)
                )
            }
        )
    }

    private func clearPendingRestoreChoice() {
        pendingImportPayloads = []
        showSharedRestoreOptions = false
    }

    private func decodeImportPayloads(from data: Data) throws -> [BackupImportPayload] {
        try BackupImportValidator.decodeAndValidate(data)
    }

    private func restoreImportPayloads(
        _ payloads: [BackupImportPayload],
        into targetFamily: Family?,
        syncToCloudKit: Bool,
        successMessage: @escaping (Int) -> String
    ) async {
        let projectedBagTotal = projectedBagCount(for: payloads, targetFamily: targetFamily)

        guard premiumAccessManager.hasPremiumAccess
            || projectedBagTotal <= PremiumAccessManager.freeBagLimit else {
            premiumAccessManager.presentPaywall(for: .bagLimit) {
                Task {
                    await self.restoreImportPayloads(
                        payloads,
                        into: targetFamily,
                        syncToCloudKit: syncToCloudKit,
                        successMessage: successMessage
                    )
                }
            }
            return
        }

        do {
            let items = try buildImportItems(from: payloads, targetFamily: targetFamily)
            for item in items {
                modelContext.insert(item)
            }
            try modelContext.save()

            if syncToCloudKit, let targetFamily {
                let sharingService = CloudKitFamilySharingService(modelContext: modelContext)
                try await sharingService.syncFamilyDataToCloudKit(for: targetFamily)
                try await sharingService.verifyCloudKitUpload(for: targetFamily)
            }

            importResult = .success(successMessage(items.count))
        } catch {
            importResult = .error(L10n.format("復元に失敗しました: %@", error.localizedDescription))
        }
    }

    private func makeLocalRestoreFamily() -> Family {
        let familyName = localRestoreFamilyName()
        let family = Family(name: familyName)
        family.markAsCurrent()
        modelContext.insert(family)
        return family
    }

    private func localRestoreFamilyName() -> String {
        let baseName = currentFamily?.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let baseName, !baseName.isEmpty {
            return L10n.format("%@（ローカル復元）", baseName)
        }
        return L10n.string("ローカル復元データ")
    }

    private func projectedBagCount(
        for payloads: [BackupImportPayload],
        targetFamily: Family?,
        includeExistingData: Bool = true
    ) -> Int {
        struct ItemSignature: Hashable {
            let name: String
            let janCode: String?
            let quantity: Int
            let expiryDate: String?
            let locationNote: String?
            let bagName: String?
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"

        func signature(
            name: String,
            janCode: String?,
            quantity: Int,
            expiryDate: Date?,
            locationNote: String?,
            bagName: String?
        ) -> ItemSignature {
            ItemSignature(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                janCode: normalized(janCode),
                quantity: quantity,
                expiryDate: expiryDate.map { dateFormatter.string(from: $0) },
                locationNote: normalized(locationNote),
                bagName: normalized(bagName)
            )
        }

        let existingBags: [Bag]
        let existingItems: [Item]
        if includeExistingData {
            let bagDescriptor = FetchDescriptor<Bag>()
            existingBags = ((try? modelContext.fetch(bagDescriptor)) ?? []).filter { bag in
                guard let targetFamily else {
                    return bag.family == nil
                }
                return bag.family?.id == targetFamily.id
            }

            let itemDescriptor = FetchDescriptor<Item>()
            existingItems = ((try? modelContext.fetch(itemDescriptor)) ?? []).filter { item in
                guard let targetFamily else {
                    return item.family == nil
                }
                return item.family?.id == targetFamily.id
            }
        } else {
            existingBags = []
            existingItems = []
        }

        var allBagKeys = Set(existingBags.compactMap { bag in
            bagLookupKey(bag.name)
        })
        var existingSignatures = Set(existingItems.map { item in
            signature(
                name: item.name,
                janCode: item.janCode,
                quantity: item.quantity,
                expiryDate: item.expiryDate,
                locationNote: item.locationNote,
                bagName: item.bag?.name
            )
        })

        for payload in payloads {
            let expiryDate = payload.expiryDate.flatMap { dateFormatter.date(from: $0) }
            let quantity = payload.quantity ?? 1
            let itemSignature = signature(
                name: payload.name,
                janCode: payload.janCode,
                quantity: quantity,
                expiryDate: expiryDate,
                locationNote: payload.locationNote,
                bagName: payload.bagName
            )

            guard !existingSignatures.contains(itemSignature) else { continue }
            existingSignatures.insert(itemSignature)

            if let key = bagLookupKey(payload.bagName) {
                allBagKeys.insert(key)
            }
        }
        return allBagKeys.count
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func bagLookupKey(_ value: String?) -> String? {
        guard let normalized = normalized(value) else { return nil }
        return normalized.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
    }

    private func buildImportItems(
        from importItems: [BackupImportPayload],
        targetFamily: Family?
    ) throws -> [Item] {
        struct ItemSignature: Hashable {
            let name: String
            let janCode: String?
            let quantity: Int
            let expiryDate: String?
            let locationNote: String?
            let bagName: String?
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        
        func signature(
            name: String,
            janCode: String?,
            quantity: Int,
            expiryDate: Date?,
            locationNote: String?,
            bagName: String?
        ) -> ItemSignature {
            ItemSignature(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                janCode: normalized(janCode),
                quantity: quantity,
                expiryDate: expiryDate.map { dateFormatter.string(from: $0) },
                locationNote: normalized(locationNote),
                bagName: normalized(bagName)
            )
        }
        
        // 既存のBagを取得
        let bagDescriptor = FetchDescriptor<Bag>()
        let existingBags = ((try? modelContext.fetch(bagDescriptor)) ?? []).filter { bag in
            guard let targetFamily else {
                return bag.family == nil
            }
            return bag.family?.id == targetFamily.id
        }
        var bagCache: [String: Bag] = [:]
        for bag in existingBags {
            if let key = bagLookupKey(bag.name) {
                bagCache[key] = bag
            }
        }

        // 既存のItemを重複判定用に読み込む
        let itemDescriptor = FetchDescriptor<Item>()
        let existingItems = ((try? modelContext.fetch(itemDescriptor)) ?? []).filter { item in
            guard let targetFamily else {
                return item.family == nil
            }
            return item.family?.id == targetFamily.id
        }
        var existingSignatures = Set(existingItems.map { item in
            signature(
                name: item.name,
                janCode: item.janCode,
                quantity: item.quantity,
                expiryDate: item.expiryDate,
                locationNote: item.locationNote,
                bagName: item.bag?.name
            )
        })
        
        var uniqueItems: [Item] = []
        for importItem in importItems {
            let expiryDate = importItem.expiryDate.flatMap { dateFormatter.date(from: $0) }
            let quantity = importItem.quantity ?? 1
            let signature = signature(
                name: importItem.name,
                janCode: importItem.janCode,
                quantity: quantity,
                expiryDate: expiryDate,
                locationNote: importItem.locationNote,
                bagName: importItem.bagName
            )
            
            if existingSignatures.contains(signature) {
                continue
            }
            
            let item = Item(
                name: importItem.name,
                janCode: normalized(importItem.janCode),
                quantity: quantity,
                expiryDate: expiryDate,
                locationNote: importItem.locationNote,
                category: importItem.resolvedCategory
            )
            item.family = targetFamily
            
            // Bagの関連付け
            if let bagName = normalized(importItem.bagName),
               let bagKey = bagLookupKey(bagName) {
                if let existingBag = bagCache[bagKey] {
                    item.bag = existingBag
                } else {
                    // 新規Bagを作成
                    let newBag = Bag(name: bagName)
                    newBag.family = targetFamily
                    modelContext.insert(newBag)
                    bagCache[bagKey] = newBag
                    item.bag = newBag
                }
            }
            
            uniqueItems.append(item)
            existingSignatures.insert(signature)
        }
        
        return uniqueItems
    }

    @ViewBuilder
    private func sharedRestoreOptionButton(
        title: String,
        subtitle: String,
        badge: String? = nil,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(AppTheme.ink)
                        .multilineTextAlignment(.leading)
                    if let badge {
                        Text(badge)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(tint)
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(tint.opacity(0.12), in: Capsule())
                    }
                }

                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.inkSecondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(AppTheme.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(tint.opacity(0.35), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func warningCard(title: String, message: String) -> some View {
        BackupWarningCard(title: title, message: message)
    }
}

// MARK: - バックアップ画面の共通部品

struct BackupHeaderCard: View {
    let icon: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(AppTheme.accentInk)
                .frame(width: 64, height: 64)
                .background(AppTheme.accentSoft, in: Circle())
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text(title)
                    .font(.title3.bold())
                    .foregroundStyle(AppTheme.ink)
                    .multilineTextAlignment(.center)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.inkSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .cardSurface()
    }
}

struct BackupResultBanner: View {
    let isSuccess: Bool
    let message: String

    private var color: Color {
        isSuccess ? AppTheme.accentInk : AppTheme.color(for: .expired)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(color)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(AppTheme.ink)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isSuccess ? AppTheme.accentSoft : AppTheme.softColor(for: .expired),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }
}

private struct BackupSampleCard: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("対応フォーマット:")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.inkSecondary)
            Text(text)
                .font(.caption2.monospaced())
                .foregroundStyle(AppTheme.ink)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppTheme.softFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(radius: 20)
    }
}

struct BackupWarningCard: View {
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "lock.trianglebadge.exclamationmark")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AppTheme.color(for: .imminent))
                .fixedSize(horizontal: false, vertical: true)
            Text(message)
                .font(.footnote)
                .foregroundStyle(AppTheme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            AppTheme.softColor(for: .imminent),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
    }
}

#Preview {
    ImportJSONView()
        .environment(PremiumAccessManager.shared)
        .modelContainer(for: [Family.self, Bag.self, Item.self], inMemory: true)
}

private struct JSONExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// バックアップ書き出しビュー
struct ExportJSONView: View {
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \Item.createdAt, order: .forward) private var items: [Item]
    @Query(sort: \Family.createdAt, order: .reverse) private var families: [Family]

    @State private var exportDocument: JSONExportDocument?
    @State private var suggestedFileName = "stockpile-export"
    @State private var isExporting = false
    @State private var showExportConfirmation = false
    @State private var exportResult: ExportResult?

    enum ExportResult {
        case success(String)
        case error(String)
    }

    private var currentFamily: Family? {
        CurrentFamilyResolver.currentFamily(from: families)
    }

    private var scopedItems: [Item] {
        guard let family = currentFamily else {
            return items.filter { $0.family == nil }
        }
        let familyItems = items.filter { $0.family?.id == family.id }
        if !familyItems.isEmpty || family.prefersStrictCloudKitScoping {
            return familyItems
        }
        return items.filter { $0.family == nil }
    }

    private var scopedItemsCountText: String {
        L10n.format("対象件数: %@件", String(scopedItems.count))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    BackupHeaderCard(
                        icon: "square.and.arrow.up",
                        title: "バックアップ",
                        subtitle: "現在の備蓄品データをバックアップファイルとして書き出します"
                    )
                    .riseIn(index: 0)

                    if let result = exportResult {
                        exportResultView(result)
                    }

                    Text(scopedItemsCountText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.accentInk)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                        .background(AppTheme.accentSoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .riseIn(index: 1)

                    if scopedItems.isEmpty {
                        Text("バックアップできる備蓄品がありません")
                            .font(.footnote)
                            .foregroundStyle(AppTheme.inkSecondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(16)
                            .cardSurface(radius: 20)
                    } else {
                        BackupSampleCard(text: exportExample)
                            .riseIn(index: 2)

                        warningCard(
                            title: "バックアップは暗号化されません",
                            message: "書き出しファイルは平文 JSON です。アイテム名、収納場所、位置メモ、JAN、期限情報が含まれる場合があるため、安全な保存先を選んで管理してください。"
                        )
                        .riseIn(index: 3)
                    }

                    Button {
                        showExportConfirmation = true
                    } label: {
                        Label("バックアップを書き出す", systemImage: "square.and.arrow.up")
                            .font(.headline)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(PrimaryActionButtonStyle())
                    .disabled(scopedItems.isEmpty)
                    .opacity(scopedItems.isEmpty ? 0.45 : 1)
                    .riseIn(index: 4)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .appScreenBackground()
            .tint(AppTheme.accent)
            .navigationTitle("バックアップ")
            .navigationBarTitleDisplayMode(.inline)
            .localizedRefresh()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") {
                        dismiss()
                    }
                }
            }
            .fileExporter(
                isPresented: $isExporting,
                document: exportDocument,
                contentType: .json,
                defaultFilename: suggestedFileName,
                onCompletion: handleExportResult
            )
            .alert("平文のバックアップを書き出しますか？", isPresented: $showExportConfirmation) {
                Button("キャンセル", role: .cancel) {}
                Button("書き出す") {
                    prepareExport()
                }
            } message: {
                Text(
                    "書き出しファイルは暗号化されない JSON です。アイテム名、JAN、期限、収納場所メモが含まれる場合があるため、安全な保存先を選んでください。"
                )
            }
        }
    }

    private var exportExample: String {
        """
        [
          {
            "name": "Canned Food",
            "quantity": 3,
            "expiryDate": "2025-12-31",
            "bagName": "Emergency Bag",
            "locationNote": "Top shelf",
            "category": "waterDrink"
          }
        ]
        """
    }

    @ViewBuilder
    private func exportResultView(_ result: ExportResult) -> some View {
        switch result {
        case .success(let message):
            BackupResultBanner(isSuccess: true, message: message)

        case .error(let message):
            BackupResultBanner(isSuccess: false, message: message)
        }
    }

    private func prepareExport() {
        do {
            let data = try makeExportData(from: scopedItems)
            exportDocument = JSONExportDocument(data: data)
            suggestedFileName = defaultFileName()
            exportResult = nil
            isExporting = true
        } catch {
            exportResult = .error(L10n.format("バックアップの準備に失敗しました: %@", error.localizedDescription))
        }
    }

    private func handleExportResult(_ result: Result<URL, Error>) {
        switch result {
        case .success:
            exportResult = .success(L10n.format("%@件のアイテムをバックアップしました", String(scopedItems.count)))
        case .failure(let error):
            if (error as? CocoaError)?.code == .userCancelled {
                return
            }
            exportResult = .error(L10n.format("バックアップに失敗しました: %@", error.localizedDescription))
        }
    }

    private func defaultFileName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "stockpile-items-\(formatter.string(from: Date()))"
    }

    private func makeExportData(from items: [Item]) throws -> Data {
        try BackupJSONCodec.makeExportData(from: items)
    }

    @ViewBuilder
    private func warningCard(title: String, message: String) -> some View {
        BackupWarningCard(title: title, message: message)
    }
}

#Preview("ExportJSONView") {
    ExportJSONView()
        .modelContainer(for: [Family.self, Item.self], inMemory: true)
}
