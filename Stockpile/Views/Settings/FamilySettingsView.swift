import SwiftUI
import SwiftData
import CloudKit

/// 家族設定画面
struct FamilySettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(Router.self) private var router
    @Query private var items: [Item]
    @Query private var bags: [Bag]

    @Bindable var family: Family

    @State private var isEditing = false
    @State private var editedName = ""
    @State private var showLeaveConfirmation = false
    @State private var isStartingShare = false
    @State private var isSyncingFamilyData = false
    @State private var autoSyncedFamilyID: UUID?
    @State private var shareError: String?
    @State private var showShareError = false
    @State private var activeShare: CKShare?
    @State private var showShareSheet = false

    private var isParticipantFamily: Bool {
        family.cloudKitDatabaseScope == .sharedDatabase
    }

    private var shareButtonTitle: String {
        family.isCloudKitSharedFamily ? "共有リンクを送信" : "家族共有を開始"
    }

    private var scopedItemsCount: Int {
        let familyItems = items.filter { $0.family?.id == family.id }
        if !familyItems.isEmpty {
            return familyItems.count
        }
        return items.filter { $0.family == nil }.count
    }

    private var scopedBagsCount: Int {
        let familyBags = bags.filter { $0.family?.id == family.id }
        if !familyBags.isEmpty {
            return familyBags.count
        }
        return bags.filter { $0.family == nil }.count
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
                Button {
                    presentCloudKitShareSheet()
                } label: {
                    HStack {
                        Label(shareButtonTitle, systemImage: "square.and.arrow.up")
                        Spacer()
                        if isStartingShare {
                            ProgressView()
                                .progressViewStyle(.circular)
                        }
                    }
                }
                .disabled(isStartingShare)
            } header: {
                Text("招待")
            } footer: {
                Text(
                    family.isCloudKitSharedFamily
                    ? "iCloud の共有リンクを使って家族を招待します。参加側はリンクを開くと共有を受理できます。"
                    : "iCloud の共有リンクを作成すると、家族の別 Apple ID 端末とも備蓄データを共有できます。"
                )
            }

            Section {
                HStack {
                    Label("共有方法", systemImage: "icloud")
                    Spacer()
                    Text(family.isCloudKitSharedFamily ? "iCloud共有" : "未共有")
                        .foregroundStyle(.secondary)
                }

                Button {
                    syncFamilyDataNow()
                } label: {
                    HStack {
                        Label("iCloudから最新化", systemImage: "arrow.clockwise.icloud")
                        Spacer()
                        if isSyncingFamilyData {
                            ProgressView()
                                .progressViewStyle(.circular)
                        }
                    }
                }
                .disabled(isSyncingFamilyData || !family.isCloudKitSharedFamily)
            } header: {
                Text("iCloud同期")
            }

            Section {
                ForEach(family.resolvedMembers) { member in
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

                if family.resolvedMembers.isEmpty {
                    HStack {
                        Image(systemName: "person.badge.plus")
                            .foregroundStyle(.secondary)
                        Text("メンバー情報は端末ローカルです")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("メンバー (\(family.resolvedMembers.count)人)")
            }

            Section {
                HStack {
                    Label("収納場所", systemImage: "bag")
                    Spacer()
                    Text("\(scopedBagsCount)件")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Label("アイテム", systemImage: "archivebox")
                    Spacer()
                    Text("\(scopedItemsCount)件")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("共有データ")
            }

            if isParticipantFamily {
                Section {
                    Button(role: .destructive) {
                        showLeaveConfirmation = true
                    } label: {
                        Label("共有家族から離脱", systemImage: "person.badge.minus")
                    }
                } footer: {
                    Text("離脱すると、この家族の共有データにアクセスできなくなります")
                }
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
            "家族共有から離脱しますか？",
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
        .sheet(isPresented: $showShareSheet, onDismiss: {
            activeShare = nil
        }) {
            if let activeShare {
                CloudKitSharingSheet(
                    share: activeShare,
                    container: CKContainer.default(),
                    onDidStopSharing: {
                        let sharingService = CloudKitFamilySharingService(modelContext: modelContext)
                        sharingService.clearShareMetadata(for: family)
                    }
                )
            }
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

    private func presentCloudKitShareSheet() {
        isStartingShare = true

        Task {
            do {
                let sharingService = CloudKitFamilySharingService(modelContext: modelContext)
                activeShare = try await sharingService.prepareShare(for: family)
                isStartingShare = false
                showShareSheet = true
            } catch {
                isStartingShare = false
                shareError = "共有リンクの準備に失敗しました: \(error.localizedDescription)"
                showShareError = true
            }
        }
    }

    private func leaveFamily() {
        Task {
            do {
                let sharingService = CloudKitFamilySharingService(modelContext: modelContext)
                try await sharingService.leaveFamily(family)
            } catch {
                // エラーは画面遷移を妨げない
            }

            router.popToRoot()
        }
    }

    private func syncFamilyDataNow() {
        isSyncingFamilyData = true

        Task {
            defer { isSyncingFamilyData = false }

            do {
                let sharingService = CloudKitFamilySharingService(modelContext: modelContext)
                try await sharingService.syncFamilyStateFromCloudKit(for: family)
            } catch {
                shareError = "iCloud同期に失敗しました: \(error.localizedDescription)"
                showShareError = true
            }
        }
    }

    private func autoSyncFamilyStateIfPossible() async {
        guard family.isCloudKitSharedFamily else { return }
        guard autoSyncedFamilyID != family.id else { return }
        autoSyncedFamilyID = family.id

        do {
            let sharingService = CloudKitFamilySharingService(modelContext: modelContext)
            try await sharingService.syncFamilyStateFromCloudKit(for: family)
        } catch {
            // 自動同期の失敗はUI操作を妨げない。
        }
    }
}

struct CloudKitSharingSheet: UIViewControllerRepresentable {
    let share: CKShare
    let container: CKContainer
    var onDidStopSharing: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onDidStopSharing: onDidStopSharing)
    }

    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController(share: share, container: container)
        controller.availablePermissions = [.allowReadWrite, .allowPrivate]
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UICloudSharingController, context: Context) {}

    final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        private let onDidStopSharing: (() -> Void)?

        init(onDidStopSharing: (() -> Void)?) {
            self.onDidStopSharing = onDidStopSharing
        }

        func itemTitle(for csc: UICloudSharingController) -> String? {
            "Stockpile 家族共有"
        }

        func cloudSharingController(
            _ csc: UICloudSharingController,
            failedToSaveShareWithError error: any Error
        ) {}

        func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {}

        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
            onDidStopSharing?()
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
