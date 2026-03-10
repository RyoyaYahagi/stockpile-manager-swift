import SwiftUI
import SwiftData

/// 家族設定画面
struct FamilySettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(Router.self) private var router

    @Bindable var family: Family

    @State private var isEditing = false
    @State private var editedName = ""
    @State private var showLeaveConfirmation = false
    @State private var isStartingShare = false
    @State private var isRetryingMigration = false
    @State private var isSyncingFamilyData = false
    @State private var autoSyncedFamilyID: UUID?
    @State private var shareError: String?
    @State private var showShareError = false

    private var isFirebaseDeveloperModeEnabled: Bool {
        APIConfig.isFirebaseDeveloperModeEnabled
    }

    var body: some View {
        List {
            Section {
                if isEditing {
                    TextField("家族名", text: $editedName)
                        .onSubmit {
                            saveChanges()
                        }
                } else {
                    HStack {
                        Label("家族名", systemImage: "person.3")
                        Spacer()
                        Text(family.name)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("家族情報")
            }

            Section {
                if isFirebaseDeveloperModeEnabled {
                    Button {
                        startSharingAndShowInvite()
                    } label: {
                        HStack {
                            Label("招待コードを表示", systemImage: "qrcode")
                            Spacer()
                            if isStartingShare {
                                ProgressView()
                                    .progressViewStyle(.circular)
                            }
                        }
                    }
                    .disabled(isStartingShare)
                } else {
                    HStack {
                        Label("iCloud同期", systemImage: "icloud")
                        Spacer()
                        Text("有効")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("招待")
            } footer: {
                Text(
                    isFirebaseDeveloperModeEnabled
                    ? "QRコードまたは6桁のコードを共有して、家族を招待できます。招待コードは24時間有効です。"
                    : "通常の同期はiCloudで行われます。Firebase招待は開発者オプション有効時のみ利用できます。"
                )
            }

            if isFirebaseDeveloperModeEnabled {
                firebaseMigrationSection
            }

            Section {
                ForEach(family.members) { member in
                    HStack {
                        Image(systemName: "person.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.blue)

                        VStack(alignment: .leading) {
                            Text(member.displayName)
                                .font(.body)
                            if let email = member.email {
                                Text(email)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if family.members.isEmpty {
                    HStack {
                        Image(systemName: "person.badge.plus")
                            .foregroundStyle(.secondary)
                        Text("まだメンバーがいません")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("メンバー (\(family.members.count)人)")
            }

            Section {
                HStack {
                    Label("収納場所", systemImage: "bag")
                    Spacer()
                    Text("\(family.bags.count)件")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Label("アイテム", systemImage: "archivebox")
                    Spacer()
                    Text("\(family.items.count)件")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("共有データ")
            }

            Section {
                Button(role: .destructive) {
                    showLeaveConfirmation = true
                } label: {
                    Label("家族から離脱", systemImage: "person.badge.minus")
                }
            } footer: {
                Text("離脱すると、この家族の共有データにアクセスできなくなります")
            }
        }
        .navigationTitle("家族設定")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(isEditing ? "完了" : "編集") {
                    if isEditing {
                        saveChanges()
                    } else {
                        editedName = family.name
                        isEditing = true
                    }
                }
            }
        }
        .confirmationDialog(
            "家族から離脱しますか？",
            isPresented: $showLeaveConfirmation,
            titleVisibility: .visible
        ) {
            Button("離脱", role: .destructive) {
                leaveFamily()
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("離脱すると、この家族の共有データにアクセスできなくなります。")
        }
        .alert("エラー", isPresented: $showShareError) {
            Button("OK") {}
        } message: {
            Text(shareError ?? "不明なエラーが発生しました")
        }
        .task(id: family.id) {
            await autoSyncFamilyStateIfPossible()
        }
    }

    private func saveChanges() {
        let trimmedName = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty {
            family.name = trimmedName
        }
        isEditing = false
    }

    private func startSharingAndShowInvite() {
        isStartingShare = true

        Task {
            do {
                let sharingService = FamilySharingService(modelContext: modelContext)

                try await sharingService.startSharing(family: family)

                isStartingShare = false
                router.present(.inviteCode(family.inviteCode))
            } catch {
                isStartingShare = false

                shareError = "共有の開始に失敗しました: \(error.localizedDescription)"
                showShareError = true
            }
        }
    }

    private func leaveFamily() {
        Task {
            do {
                let sharingService = FamilySharingService(modelContext: modelContext)
                try await sharingService.leaveFamily(family)
            } catch {
                // エラーは画面遷移を妨げない
            }

            router.popToRoot()
        }
    }

    @ViewBuilder
    private var firebaseMigrationSection: some View {
        let sharingService = FamilySharingService(modelContext: modelContext)
        let status = sharingService.firebaseMigrationStatus(for: family)
        let isFirebaseUnavailable: Bool = {
            if case .notConfigured = status {
                return true
            }
            return false
        }()
        let migrationActionTitle: String = {
            switch status {
            case .notStarted:
                return "Firebase移行を実行"
            default:
                return "Firebase移行を再実行"
            }
        }()

        Section {
            switch status {
            case .completed:
                HStack {
                    Label("初回移行", systemImage: "checkmark.seal.fill")
                    Spacer()
                    Text("完了")
                        .foregroundStyle(.secondary)
                }
            case .notConfigured:
                HStack {
                    Label("初回移行", systemImage: "exclamationmark.triangle.fill")
                    Spacer()
                    Text("未設定")
                        .foregroundStyle(.secondary)
                }
            case .notStarted:
                HStack {
                    Label("初回移行", systemImage: "arrow.clockwise")
                    Spacer()
                    Text("未実行")
                        .foregroundStyle(.secondary)
                }
            case .pending(let lastError):
                HStack {
                    Label("初回移行", systemImage: "exclamationmark.triangle.fill")
                    Spacer()
                    Text("再試行待ち")
                        .foregroundStyle(.orange)
                }
                if let lastError, !lastError.isEmpty {
                    Text(lastError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                retryFirebaseMigration()
            } label: {
                HStack {
                    Text(migrationActionTitle)
                    Spacer()
                    if isRetryingMigration {
                        ProgressView()
                            .progressViewStyle(.circular)
                    }
                }
            }
            .disabled(isRetryingMigration || isFirebaseUnavailable)

            Button {
                syncFamilyDataFromFirebase()
            } label: {
                HStack {
                    Text("Firebaseから最新データを取得")
                    Spacer()
                    if isSyncingFamilyData {
                        ProgressView()
                            .progressViewStyle(.circular)
                    }
                }
            }
            .disabled(isSyncingFamilyData || isFirebaseUnavailable)
        } header: {
            Text("Firebase同期")
        } footer: {
            Text("家族共有接続後はFirebase上のデータを正として同期します。")
        }
    }

    private func retryFirebaseMigration() {
        isRetryingMigration = true

        Task {
            defer { isRetryingMigration = false }
            do {
                let sharingService = FamilySharingService(modelContext: modelContext)
                try await sharingService.retryInitialFirebaseMigration(for: family)
                try await sharingService.syncFamilyStateFromFirebase(for: family)
            } catch {
                shareError = "Firebase移行に失敗しました: \(error.localizedDescription)"
                showShareError = true
            }
        }
    }

    private func syncFamilyDataFromFirebase() {
        isSyncingFamilyData = true

        Task {
            defer { isSyncingFamilyData = false }
            do {
                let sharingService = FamilySharingService(modelContext: modelContext)
                try await sharingService.syncFamilyStateFromFirebase(for: family)
            } catch {
                shareError = "Firebase同期に失敗しました: \(error.localizedDescription)"
                showShareError = true
            }
        }
    }

    private func autoSyncFamilyStateIfPossible() async {
        guard APIConfig.isFirebaseEnabled else { return }
        guard autoSyncedFamilyID != family.id else { return }
        autoSyncedFamilyID = family.id

        do {
            let sharingService = FamilySharingService(modelContext: modelContext)
            try await sharingService.syncFamilyStateFromFirebase(for: family)
        } catch {
            // 画面表示時の自動同期は失敗してもUI操作を妨げない。
        }
    }
}

#Preview {
    NavigationStack {
        FamilySettingsView(family: Family(name: "テスト家族"))
    }
    .environment(Router())
    .modelContainer(for: [Family.self], inMemory: true)
}
