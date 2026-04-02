import SwiftUI
import SwiftData

/// 家族セットアップ画面
struct FamilySetupView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(Router.self) private var router
    
    @State private var familyName = ""
    @State private var errorMessage: String?
    @State private var isCreating = false
    
    private var isValid: Bool {
        !familyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isSubmitting: Bool {
        isCreating
    }
    
    var body: some View {
        Form {
            Section {
                Label("家族共有はiCloud共有リンクで行われます", systemImage: "person.3.sequence")
            } footer: {
                Text("家族を作成したあと、設定画面から共有リンクを送れます。参加側はそのリンクを開くと共有を受理できます。")
            }
            
            createFamilySection
            
            if let error = errorMessage {
                Section {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
            }
            
            Section {
                Button(action: submit) {
                    HStack {
                        Spacer()
                        if isSubmitting {
                            ProgressView()
                                .progressViewStyle(.circular)
                        } else {
                            Text("家族を作成")
                                .fontWeight(.semibold)
                        }
                        Spacer()
                    }
                }
                .disabled(!isValid || isSubmitting)
            }
        }
        .navigationTitle("家族セットアップ")
        .navigationBarTitleDisplayMode(.inline)
        .localizedRefresh()
    }
    
    private var createFamilySection: some View {
        Section {
            TextField("家族名", text: $familyName)
        } header: {
            Text("家族名")
        } footer: {
            Text("家族グループの名前を入力してください（例: 山田家）")
        }
    }
    
    private func submit() {
        Task {
            await createFamily()
        }
    }
    
    private func createFamily() async {
        isCreating = true
        defer { isCreating = false }

        let trimmedName = familyName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        let family = Family(name: trimmedName)
        family.markAsCurrent()
        modelContext.insert(family)
        
        do {
            try modelContext.save()
            router.pop()
            router.push(.familySettings(family))
        } catch {
            errorMessage = L10n.format("家族の作成に失敗しました: %@", error.localizedDescription)
        }
    }
}

#Preview {
    NavigationStack {
        FamilySetupView()
    }
    .environment(Router())
    .modelContainer(for: [Family.self], inMemory: true)
}
