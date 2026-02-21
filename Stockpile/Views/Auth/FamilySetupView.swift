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
    @State private var showQRScanner = false
    @State private var isCreating = false
    @State private var isJoining = false
    
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

    private var isSubmitting: Bool {
        isCreating || isJoining
    }
    
    var body: some View {
        Form {
            Section {
                Picker("セットアップ方法", selection: $selectedMode) {
                    Text("新規作成").tag(SetupMode.create)
                    Text("参加する").tag(SetupMode.join)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
            }
            
            switch selectedMode {
            case .create:
                createFamilySection
                
            case .join:
                joinFamilySection
            }
            
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
                            Text(selectedMode == .create ? "家族を作成" : "家族に参加")
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
        .sheet(isPresented: $showQRScanner) {
            QRScannerView { scannedCode in
                inviteCode = scannedCode
                Task {
                    await joinWithCode(scannedCode)
                }
            }
        }
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
    
    private var joinFamilySection: some View {
        Group {
            Section {
                Button {
                    showQRScanner = true
                } label: {
                    HStack {
                        Image(systemName: "qrcode.viewfinder")
                            .font(.title2)
                        VStack(alignment: .leading) {
                            Text("QRコードをスキャン")
                                .font(.body)
                            Text("共有されたQRコードを読み取ります")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            
            Section {
                TextField("招待コード（6桁）", text: $inviteCode)
                    .textInputAutocapitalization(.characters)
                    .font(.system(.body, design: .monospaced))
                    .onChange(of: inviteCode) { _, newValue in
                        inviteCode = String(newValue.prefix(6)).uppercased()
                        errorMessage = nil
                    }
            } header: {
                Text("または招待コードを入力")
            } footer: {
                Text("家族から共有された6桁の招待コードを入力してください")
            }
        }
    }
    
    private func submit() {
        switch selectedMode {
        case .create:
            Task {
                await createFamily()
            }
        case .join:
            Task {
                await joinWithCode(inviteCode)
            }
        }
    }
    
    private func createFamily() async {
        isCreating = true
        defer { isCreating = false }

        let trimmedName = familyName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        let family = Family(name: trimmedName)
        modelContext.insert(family)
        
        do {
            try modelContext.save()
            let sharingService = FamilySharingService(modelContext: modelContext)
            do {
                try await sharingService.migrateInitialDataToFirebaseIfNeeded(for: family)
            } catch {
                // 家族作成自体は完了扱いにし、設定画面から再試行可能にする。
                print("Firebase初回移行に失敗: \(error)")
            }
            router.popToRoot()
        } catch {
            errorMessage = "家族の作成に失敗しました: \(error.localizedDescription)"
        }
    }
    
    private func joinWithCode(_ code: String) async {
        isJoining = true
        errorMessage = nil
        
        let sharingService = FamilySharingService(modelContext: modelContext)
        
        do {
            let result = try await sharingService.joinFamilyWithCode(code)
            
            switch result {
            case .success:
                router.popToRoot()
            case .alreadyMember:
                router.popToRoot()
            case .pendingSync:
                router.popToRoot()
            case .notFound:
                errorMessage = "招待コードに一致する家族が見つかりません。コードを確認して再試行してください。"
            case .expired:
                errorMessage = "この招待コードは有効期限が切れています。新しい招待コードを発行してもらってください。"
            case .error(let error):
                errorMessage = error.localizedDescription
            }
        } catch {
            errorMessage = "参加に失敗しました: \(error.localizedDescription)"
        }
        
        isJoining = false
    }
}

#Preview {
    NavigationStack {
        FamilySetupView()
    }
    .environment(Router())
    .modelContainer(for: [Family.self], inMemory: true)
}
