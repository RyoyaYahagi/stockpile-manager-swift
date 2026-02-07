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
            "expiryDate": "2025-12-31"
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
            let locationNote: String?
        }
        
        let decoder = JSONDecoder()
        let importItems = try decoder.decode([ImportItem].self, from: data)
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        
        return importItems.map { importItem in
            let expiryDate = importItem.expiryDate.flatMap { dateFormatter.date(from: $0) }
            return Item(
                name: importItem.name,
                quantity: importItem.quantity ?? 1,
                expiryDate: expiryDate,
                locationNote: importItem.locationNote
            )
        }
    }
}

#Preview {
    ImportJSONView()
        .modelContainer(for: [Item.self], inMemory: true)
}
