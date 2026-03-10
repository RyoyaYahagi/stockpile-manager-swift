import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// JSONインポートビュー
struct ImportJSONView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    
    @State private var isImporting = false
    @State private var importResult: ImportResult?
    
    enum ImportResult {
        case success(count: Int)
        case error(String)
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 60))
                    .foregroundStyle(.blue)
                
                VStack(spacing: 8) {
                    Text("JSONインポート")
                        .font(.title2.bold())
                    
                    Text("備蓄品データをJSONファイルから一括読み込みします")
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
                }
                .padding(.horizontal, 32)
                
                Spacer()
            }
            .padding(.top, 40)
            .navigationTitle("インポート")
            .navigationBarTitleDisplayMode(.inline)
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
        }
    }
    
    private var formatExample: String {
        """
        [
          {
            "name": "缶詰",
            "quantity": 3,
            "expiryDate": "2025-12-31",
            "bagName": "非常袋",
            "locationNote": "棚の上"
          }
        ]
        """
    }
    
    @ViewBuilder
    private func resultView(_ result: ImportResult) -> some View {
        switch result {
        case .success(let count):
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("\(count)件のアイテムをインポートしました")
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
                    importResult = .error("ファイルにアクセスできません")
                    return
                }
                defer { url.stopAccessingSecurityScopedResource() }
                
                let data = try Data(contentsOf: url)
                let items = try parseJSON(data)
                
                for item in items {
                    modelContext.insert(item)
                }
                try modelContext.save()
                
                importResult = .success(count: items.count)
                
            } catch {
                importResult = .error("インポートに失敗しました: \(error.localizedDescription)")
            }
            
        case .failure(let error):
            importResult = .error("ファイル選択に失敗しました: \(error.localizedDescription)")
        }
    }
    
    private func parseJSON(_ data: Data) throws -> [Item] {
        struct ImportItem: Decodable {
            let name: String
            let quantity: Int?
            let expiryDate: String?
            let bagName: String?
            let locationNote: String?
        }
        
        struct ItemSignature: Hashable {
            let name: String
            let quantity: Int
            let expiryDate: String?
            let locationNote: String?
            let bagName: String?
        }
        
        let decoder = JSONDecoder()
        let importItems = try decoder.decode([ImportItem].self, from: data)
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        
        func normalized(_ value: String?) -> String? {
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        
        func signature(
            name: String,
            quantity: Int,
            expiryDate: Date?,
            locationNote: String?,
            bagName: String?
        ) -> ItemSignature {
            ItemSignature(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                quantity: quantity,
                expiryDate: expiryDate.map { dateFormatter.string(from: $0) },
                locationNote: normalized(locationNote),
                bagName: normalized(bagName)
            )
        }
        
        // 既存のBagを取得
        let bagDescriptor = FetchDescriptor<Bag>()
        let existingBags = (try? modelContext.fetch(bagDescriptor)) ?? []
        var bagCache: [String: Bag] = [:]
        for bag in existingBags {
            bagCache[bag.name] = bag
        }
        
        // 既存のItemを重複判定用に読み込む
        let itemDescriptor = FetchDescriptor<Item>()
        let existingItems = (try? modelContext.fetch(itemDescriptor)) ?? []
        var existingSignatures = Set(existingItems.map { item in
            signature(
                name: item.name,
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
                quantity: quantity,
                expiryDate: expiryDate,
                locationNote: importItem.locationNote
            )
            
            // Bagの関連付け
            if let bagName = normalized(importItem.bagName) {
                if let existingBag = bagCache[bagName] {
                    item.bag = existingBag
                } else {
                    // 新規Bagを作成
                    let newBag = Bag(name: bagName)
                    modelContext.insert(newBag)
                    bagCache[bagName] = newBag
                    item.bag = newBag
                }
            }
            
            uniqueItems.append(item)
            existingSignatures.insert(signature)
        }
        
        return uniqueItems
    }
}

#Preview {
    ImportJSONView()
        .modelContainer(for: [Item.self], inMemory: true)
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

/// JSONエクスポートビュー
struct ExportJSONView: View {
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \Item.createdAt, order: .forward) private var items: [Item]
    @Query(sort: \Family.createdAt, order: .reverse) private var families: [Family]

    @State private var exportDocument: JSONExportDocument?
    @State private var suggestedFileName = "stockpile-export"
    @State private var isExporting = false
    @State private var exportResult: ExportResult?

    enum ExportResult {
        case success(String)
        case error(String)
    }

    private var currentFamily: Family? {
        families.first
    }

    private var scopedItems: [Item] {
        guard let family = currentFamily else {
            return items.filter { $0.family == nil }
        }
        return items.filter { $0.family?.id == family.id }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 60))
                    .foregroundStyle(.blue)

                VStack(spacing: 8) {
                    Text("JSONエクスポート")
                        .font(.title2.bold())

                    Text("現在の備蓄品データをJSONファイルとして書き出します")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if let result = exportResult {
                    exportResultView(result)
                }

                VStack(spacing: 12) {
                    Text("対象件数: \(scopedItems.count)件")
                        .font(.subheadline.weight(.medium))

                    Button {
                        prepareExport()
                    } label: {
                        Label("JSONを書き出す", systemImage: "square.and.arrow.up")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(.blue, in: RoundedRectangle(cornerRadius: 12))
                            .foregroundStyle(.white)
                    }
                    .disabled(scopedItems.isEmpty)

                    if scopedItems.isEmpty {
                        Text("書き出せる備蓄品がありません")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(exportExample)
                            .font(.caption2.monospaced())
                            .padding()
                            .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(.horizontal, 32)

                Spacer()
            }
            .padding(.top, 40)
            .navigationTitle("エクスポート")
            .navigationBarTitleDisplayMode(.inline)
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
        }
    }

    private var exportExample: String {
        """
        [
          {
            "name": "缶詰",
            "quantity": 3,
            "expiryDate": "2025-12-31",
            "bagName": "非常袋",
            "locationNote": "棚の上"
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
            exportResult = .error("エクスポートの準備に失敗しました: \(error.localizedDescription)")
        }
    }

    private func handleExportResult(_ result: Result<URL, Error>) {
        switch result {
        case .success:
            exportResult = .success("\(scopedItems.count)件のアイテムを書き出しました")
        case .failure(let error):
            if (error as? CocoaError)?.code == .userCancelled {
                return
            }
            exportResult = .error("エクスポートに失敗しました: \(error.localizedDescription)")
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
}

#Preview("ExportJSONView") {
    ExportJSONView()
        .modelContainer(for: [Family.self, Item.self], inMemory: true)
}
