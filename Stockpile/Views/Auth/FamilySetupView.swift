import SwiftUI
import SwiftData

/// 家族セットアップ画面
struct FamilySetupView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(Router.self) private var router
    
    @State private var selectedMode: SetupMode = .create
    @State private var familyName = ""
    @State private var inviteCode = ""
    @State private var errorMessage: String?
    
    @Query private var families: [Family]
    
    enum SetupMode {
        case create
        case join
    }
    
    private var isValid: Bool {
        switch selectedMode {
        case .create:
            return !familyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .join:
            return inviteCode.count == 6
        }
    }
    
    var body: some View {
        Form {
            Section {
                Picker("セットアップ方法", selection: $selectedMode) {
                    Text("新規作成").tag(SetupMode.create)
                    Text("招待コードで参加").tag(SetupMode.join)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
            }
            
            switch selectedMode {
            case .create:
                Section {
                    TextField("家族名", text: $familyName)
                } header: {
                    Text("家族名")
                } footer: {
                    Text("家族グループの名前を入力してください（例: 山田家）")
                }
                
            case .join:
                Section {
                    TextField("招待コード（6桁）", text: $inviteCode)
                        .textInputAutocapitalization(.characters)
                        .onChange(of: inviteCode) { _, newValue in
                            inviteCode = String(newValue.prefix(6)).uppercased()
                        }
                } header: {
                    Text("招待コード")
                } footer: {
                    Text("家族から共有された6桁の招待コードを入力してください")
                }
            }
            
            if let error = errorMessage {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }
            
            Section {
                Button(action: submit) {
                    HStack {
                        Spacer()
                        Text(selectedMode == .create ? "家族を作成" : "家族に参加")
                            .fontWeight(.semibold)
                        Spacer()
                    }
                }
                .disabled(!isValid)
            }
        }
        .navigationTitle("家族セットアップ")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    private func submit() {
        switch selectedMode {
        case .create:
            let family = Family(name: familyName.trimmingCharacters(in: .whitespacesAndNewlines))
            modelContext.insert(family)
            router.popToRoot()
            
        case .join:
            // オフラインモードでは既存の家族をコードで検索
            if families.first(where: { $0.inviteCode == inviteCode }) != nil {
                // 既にこの家族がローカルにある
                errorMessage = nil
                router.popToRoot()
            } else {
                // オフラインモードでは他デバイスの家族には参加できない
                errorMessage = "オフラインモードでは招待コードでの参加はできません。同じデバイスで作成された家族のみ利用可能です。"
            }
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
