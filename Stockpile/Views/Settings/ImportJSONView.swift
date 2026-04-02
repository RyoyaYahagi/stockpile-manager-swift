import SwiftUI
import SwiftData
import UniformTypeIdentifiers

private struct BackupImportPayload: Decodable {
    let name: String
    let janCode: String?
    let quantity: Int?
    let expiryDate: String?
    let bagName: String?
    let locationNote: String?

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
        bagName =
            try container.decodeIfPresent(String.self, forKey: .bagName)
            ?? container.decodeIfPresent(String.self, forKey: .bagname)
            ?? container.decodeIfPresent(String.self, forKey: .bag_name)
            ?? container.decodeIfPresent(String.self, forKey: .storageName)
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case janCode
        case jan
        case barcode
        case quantity
        case expiryDate
        case locationNote
        case bagName
        case bagname
        case bag_name
        case storageName
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
            VStack(spacing: 24) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 60))
                    .foregroundStyle(.blue)
                
                VStack(spacing: 8) {
                    Text("バックアップから復元")
                        .font(.title2.bold())
                    
                    Text("バックアップファイルから備蓄品データをまとめて復元します")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                
                if let result = importResult {
                    resultView(result)
                }
                
                VStack(spacing: 12) {
                    Button {
                        isImporting = true
                    } label: {
                        Label("ファイルを選択", systemImage: "folder")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(.blue, in: RoundedRectangle(cornerRadius: 12))
                            .foregroundStyle(.white)
                    }
                    
                    Text("対応フォーマット:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    Text(formatExample)
                        .font(.caption2.monospaced())
                        .padding()
                        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 8))

                    warningCard(
                        title: "信頼できるバックアップだけを復元してください",
                        message: "JSON の内容はそのまま端末内データとして保存されます。受け取り元が不明なファイルは取り込まないでください。"
                    )
                }
                .padding(.horizontal, 32)
                
                Spacer()
            }
            .padding(.top, 40)
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
            "locationNote": "Top shelf"
          }
        ]
        """
    }
    
    @ViewBuilder
    private func resultView(_ result: ImportResult) -> some View {
        switch result {
        case .success(let message):
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(message)
            }
            .padding()
            .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            
        case .error(let message):
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(message)
            }
            .padding()
            .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
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
                .fill(Color.secondary.opacity(0.25))
                .frame(width: 36, height: 5)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)

            VStack(alignment: .leading, spacing: 10) {
                Label("復元先を選択", systemImage: "arrow.triangle.branch")
                    .font(.title3.bold())
                    .foregroundStyle(.primary)

                Text(sharedRestoreDialogMessage)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 12) {
                sharedRestoreOptionButton(
                    title: "この端末だけに復元",
                    subtitle: "新しいローカル家族を作って、共有データとは切り離して戻します。",
                    badge: "推奨",
                    tint: .blue
                ) {
                    Task {
                        await restorePendingPayloadsLocally()
                    }
                }

                sharedRestoreOptionButton(
                    title: "iCloud共有データとして復元",
                    subtitle: "この復元内容を共有データへ反映し、ほかの参加端末にも同期します。",
                    tint: .orange
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
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
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
        let decoder = JSONDecoder()
        return try decoder.decode([BackupImportPayload].self, from: data)
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
                locationNote: importItem.locationNote
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
                        .foregroundStyle(.primary)
                    if let badge {
                        Text(badge)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(tint)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(tint.opacity(0.12), in: Capsule())
                    }
                }

                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(tint.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(tint.opacity(0.18), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func warningCard(title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "lock.trianglebadge.exclamationmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
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
            VStack(spacing: 24) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 60))
                    .foregroundStyle(.blue)

                VStack(spacing: 8) {
                    Text("バックアップ")
                        .font(.title2.bold())

                    Text("現在の備蓄品データをバックアップファイルとして書き出します")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if let result = exportResult {
                    exportResultView(result)
                }

                VStack(spacing: 12) {
                    Text(scopedItemsCountText)
                        .font(.subheadline.weight(.medium))

                    Button {
                        showExportConfirmation = true
                    } label: {
                            Label("バックアップを書き出す", systemImage: "square.and.arrow.up")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(.blue, in: RoundedRectangle(cornerRadius: 12))
                            .foregroundStyle(.white)
                    }
                    .disabled(scopedItems.isEmpty)

                    if scopedItems.isEmpty {
                        Text("バックアップできる備蓄品がありません")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(exportExample)
                            .font(.caption2.monospaced())
                            .padding()
                            .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 8))

                        warningCard(
                            title: "バックアップは暗号化されません",
                            message: "書き出しファイルは平文 JSON です。アイテム名、収納場所、位置メモ、JAN、期限情報が含まれる場合があるため、安全な保存先を選んで管理してください。"
                        )
                    }
                }
                .padding(.horizontal, 32)

                Spacer()
            }
            .padding(.top, 40)
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
            "locationNote": "Top shelf"
          }
        ]
        """
    }

    @ViewBuilder
    private func exportResultView(_ result: ExportResult) -> some View {
        switch result {
        case .success(let message):
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(message)
            }
            .padding()
            .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))

        case .error(let message):
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(message)
            }
            .padding()
            .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
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
        struct ExportItem: Encodable {
            let name: String
            let janCode: String?
            let quantity: Int
            let expiryDate: String?
            let bagName: String?
            let locationNote: String?
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        let payload = items.map { item in
            ExportItem(
                name: item.name,
                janCode: item.janCode,
                quantity: item.quantity,
                expiryDate: item.expiryDate.map { formatter.string(from: $0) },
                bagName: item.bag?.name,
                locationNote: item.locationNote
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(payload)
    }

    @ViewBuilder
    private func warningCard(title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "lock.trianglebadge.exclamationmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}

#Preview("ExportJSONView") {
    ExportJSONView()
        .modelContainer(for: [Family.self, Item.self], inMemory: true)
}
