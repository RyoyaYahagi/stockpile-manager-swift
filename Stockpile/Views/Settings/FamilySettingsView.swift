import SwiftUI
import SwiftData
import CloudKit
import UIKit

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
    @State private var isRefreshingFamilyData = false
    @State private var isSavingFamilyDataToCloud = false
    @State private var autoSyncedFamilyID: UUID?
    @State private var shareError: String?
    @State private var showShareError = false
    @State private var showFamilyNamePrompt = false
    @State private var activeShare: CKShare?
    @State private var showShareManagementSheet = false
    @State private var sharePayload: ShareActivityPayload?
    @State private var participantDisplays: [CloudKitFamilySharingService.ShareParticipantDisplay] = []
    @State private var isLoadingParticipants = false
    @State private var isOpeningShareManagement = false

    private var isParticipantFamily: Bool {
        family.cloudKitDatabaseScope == .sharedDatabase
    }

    private var usesCloudKitParticipantList: Bool {
        family.shareState != .localOnly
    }

    private var shareButtonTitle: String {
        family.cloudKitShareURL == nil ? L10n.string("共有リンクを作成") : L10n.string("共有リンクを再送")
    }

    private var canManageShare: Bool {
        !isParticipantFamily && family.cloudKitShareURL != nil
    }

    private var memberSectionFooter: String {
        if usesCloudKitParticipantList {
            return isLoadingParticipants
                ? L10n.string("iCloud共有の参加者を読み込んでいます")
                : L10n.string("iCloud共有の参加者を表示しています")
        }
        return L10n.string("メンバー情報はこの端末のローカルデータです")
    }

    private var invitationSectionFooter: String {
        family.cloudKitShareURL == nil
            ? L10n.string("共有リンクの作成には時間がかかる場合があります。完了後に共有方法を選んで送信できます。")
            : L10n.string("共有リンクを再送できます。以前にこの共有から離脱した人を再招待する場合は、「共有設定を管理」から招待してください。")
    }

    private var memberSectionTitle: String {
        L10n.format("メンバー（%@人）", String(displayedMemberCount))
    }

    private var displayedLocalMembers: [User] {
        family.shouldShowMemberList ? family.uniqueMembers : []
    }

    private var displayedMemberCount: Int {
        usesCloudKitParticipantList ? participantDisplays.count : displayedLocalMembers.count
    }

    private var scopedItemsCount: Int {
        let familyItems = items.filter { $0.family?.id == family.id }
        if !familyItems.isEmpty || family.prefersStrictCloudKitScoping {
            return familyItems.count
        }
        return items.filter { $0.family == nil }.count
    }

    private var scopedBagsCount: Int {
        let familyBags = bags.filter { $0.family?.id == family.id }
        if !familyBags.isEmpty || family.prefersStrictCloudKitScoping {
            return familyBags.count
        }
        return bags.filter { $0.family == nil }.count
    }

    private var isAnyCloudSyncInFlight: Bool {
        isRefreshingFamilyData || isSavingFamilyDataToCloud
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
                    Button {
                        editedName = family.name
                        isEditing = true
                    } label: {
                        HStack {
                            Label("家族名", systemImage: "person.3")
                            Spacer()
                            Text(family.displayNameForCurrentState)
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("家族情報")
            }

            if !isParticipantFamily {
                Section {
                    Button {
                        handleShareButtonTap()
                    } label: {
                        HStack {
                            Label(shareButtonTitle, systemImage: "link")
                            Spacer()
                            if isStartingShare {
                                ProgressView()
                                    .progressViewStyle(.circular)
                            }
                        }
                    }
                    .disabled(isStartingShare || isOpeningShareManagement)

                    if canManageShare {
                        Button {
                            openShareManagement()
                        } label: {
                            HStack {
                                Label("共有設定を管理", systemImage: "person.crop.circle.badge.checkmark")
                                Spacer()
                                if isOpeningShareManagement {
                                    ProgressView()
                                        .progressViewStyle(.circular)
                                }
                            }
                        }
                        .disabled(isStartingShare || isOpeningShareManagement)
                    }
                } header: {
                    Text("招待")
                } footer: {
                    Text(invitationSectionFooter)
                }
            }

            Section {
                HStack {
                    Label("共有方法", systemImage: "icloud")
                    Spacer()
                    Text(family.shareState.label)
                        .foregroundStyle(.secondary)
                }

                Button {
                    saveFamilyDataToCloudKitNow()
                } label: {
                    HStack {
                        Label("iCloudに保存", systemImage: "arrow.up.circle")
                        Spacer()
                        if isSavingFamilyDataToCloud {
                            ProgressView()
                                .progressViewStyle(.circular)
                        }
                    }
                }
                .disabled(isAnyCloudSyncInFlight || family.shareState == .localOnly)

                Button {
                    syncFamilyDataNow()
                } label: {
                    HStack {
                        Label("iCloudから最新化", systemImage: "arrow.clockwise.icloud")
                        Spacer()
                        if isRefreshingFamilyData {
                            ProgressView()
                                .progressViewStyle(.circular)
                        }
                    }
                }
                .disabled(isAnyCloudSyncInFlight || family.shareState == .localOnly)
            } header: {
                Text("iCloud同期")
            } footer: {
                if family.shareState == .preparing {
                    Text("共有受理後の同期を再試行できます。CloudKit の共有データを同期中です。")
                }
            }

            Section {
                if usesCloudKitParticipantList {
                    ForEach(participantDisplays) { participant in
                        HStack {
                            Image(systemName: participant.isOwner ? "person.crop.circle.badge.checkmark" : "person.circle.fill")
                                .font(.title2)
                                .foregroundStyle(participant.isOwner ? .orange : .blue)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(participant.displayName)
                                    .font(.body)
                                Text(participant.statusLabel)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    ForEach(displayedLocalMembers) { member in
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
                }

                if displayedMemberCount == 0 {
                    HStack {
                        Image(systemName: "person.badge.plus")
                            .foregroundStyle(.secondary)
                        Text(memberSectionFooter)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(memberSectionTitle)
            } footer: {
                Text(memberSectionFooter)
            }

            Section {
                HStack {
                    Label("収納場所", systemImage: "bag")
                    Spacer()
                    Text(L10n.format("%@件", String(scopedBagsCount)))
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Label("アイテム", systemImage: "archivebox")
                    Spacer()
                    Text(L10n.format("%@件", String(scopedItemsCount)))
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
        .localizedRefresh()
        .toolbar {
            if isEditing {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完了") {
                        saveChanges()
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
            Text(shareError ?? L10n.string("不明なエラーが発生しました"))
        }
        .sheet(isPresented: $showFamilyNamePrompt) {
            NavigationStack {
                Form {
                    Section {
                        TextField("家族名", text: $editedName)
                    } header: {
                        Text("家族名")
                    } footer: {
                        Text("最初に家族名を登録すると、その名前で共有リンクを送信できます。")
                    }
                }
                .navigationTitle("家族名を設定")
                .navigationBarTitleDisplayMode(.inline)
                .localizedRefresh()
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("キャンセル") {
                            showFamilyNamePrompt = false
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("続ける") {
                            saveFamilyNameAndStartSharing()
                        }
                        .disabled(editedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
        .sheet(isPresented: $showShareManagementSheet, onDismiss: {
            activeShare = nil
            Task { @MainActor in
                await refreshParticipantDisplays(forceRefresh: true)
            }
        }) {
            if let activeShare {
                CloudKitSharingSheet(
                    share: activeShare,
                    container: CKContainer.default(),
                    onDidStopSharing: {
                        let sharingService = CloudKitFamilySharingService(modelContext: modelContext)
                        sharingService.clearShareMetadata(for: family)
                    },
                    onError: { error in
                        CloudKitSharingDiagnostics.logError(
                            context: "共有管理シート",
                            error: error
                        )
                        shareError = L10n.format(
                            "共有設定の保存に失敗しました: %@",
                            error.localizedDescription
                        )
                        showShareError = true
                    }
                )
            }
        }
        .sheet(item: $sharePayload) { payload in
            ShareActivitySheet(payload: payload)
        }
        .task(id: family.id) {
            await refreshParticipantDisplays()
            await autoSyncFamilyStateIfPossible()
        }
    }

    private func saveChanges() {
        let trimmedName = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty {
            family.name = trimmedName
            family.markUpdated()
        }

        do {
            try modelContext.save()
        } catch {
            shareError = L10n.format("家族名の保存に失敗しました: %@", error.localizedDescription)
            showShareError = true
            return
        }
        isEditing = false
    }

    private func handleShareButtonTap() {
        if requiresFamilyNameBeforeSharing {
            editedName = family.name
            showFamilyNamePrompt = true
            return
        }

        prepareShareLinkAndPresentActivity()
    }

    private var requiresFamilyNameBeforeSharing: Bool {
        family.shareState == .localOnly
            && family.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func saveFamilyNameAndStartSharing() {
        let trimmedName = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        family.name = trimmedName
        family.markUpdated()

        do {
            try modelContext.save()
            showFamilyNamePrompt = false
            prepareShareLinkAndPresentActivity()
        } catch {
            shareError = L10n.format("家族名の保存に失敗しました: %@", error.localizedDescription)
            showShareError = true
        }
    }

    private func prepareShareLinkAndPresentActivity() {
        isStartingShare = true

        Task { @MainActor in
            do {
                let sharingService = CloudKitFamilySharingService(modelContext: modelContext)
                activeShare = try await sharingService.prepareShare(for: family)
                let invitationURL: URL?
                do {
                    invitationURL = try await sharingService.prepareInvitationURL(
                        for: family,
                        preparedShare: activeShare
                    )
                } catch {
                    print("[CloudKitShare] 招待リンクURLの取得に失敗。共有管理シートへフォールバック: \(error.localizedDescription)")
                    invitationURL = nil
                }
                isStartingShare = false
                presentPreparedShare(invitationURL: invitationURL)
                await refreshParticipantDisplays()
            } catch {
                isStartingShare = false
                shareError = L10n.format("共有リンクの準備に失敗しました: %@", error.localizedDescription)
                showShareError = true
            }
        }
    }

    private func openShareManagement() {
        isOpeningShareManagement = true

        Task { @MainActor in
            do {
                let sharingService = CloudKitFamilySharingService(modelContext: modelContext)
                activeShare = try await sharingService.prepareShare(for: family)
                isOpeningShareManagement = false
                showShareManagementSheet = true
                await refreshParticipantDisplays()
            } catch {
                isOpeningShareManagement = false
                shareError = L10n.format("共有設定の読み込みに失敗しました: %@", error.localizedDescription)
                showShareError = true
            }
        }
    }

    private func presentPreparedShare(invitationURL: URL? = nil) {
        if let shareURL = invitationURL {
            presentShareActivity(for: shareURL)
            return
        }

        if activeShare != nil {
            showShareManagementSheet = true
            return
        }

        shareError = L10n.string("共有リンクの取得に失敗しました")
        showShareError = true
    }

    private func presentShareActivity(for shareURL: URL) {
        let trimmedName = family.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = trimmedName.isEmpty
            ? L10n.string("Stockpile の家族共有リンクです。")
            : L10n.format("「%@」の Stockpile 家族共有リンクです。", trimmedName)
        sharePayload = ShareActivityPayload(message: message, url: shareURL)
    }

    private func leaveFamily() {
        Task { @MainActor in
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
        isRefreshingFamilyData = true

        Task { @MainActor in
            defer { isRefreshingFamilyData = false }

            do {
                let sharingService = CloudKitFamilySharingService(modelContext: modelContext)
                try await sharingService.syncFamilyStateFromCloudKit(for: family)
            } catch {
                shareError = L10n.format("iCloud同期に失敗しました: %@", error.localizedDescription)
                showShareError = true
            }
        }
    }

    private func saveFamilyDataToCloudKitNow() {
        isSavingFamilyDataToCloud = true
        let zoneName = family.cloudKitZoneName ?? "family-\(family.id.uuidString)"
        let databaseScope = family.cloudKitDatabaseScope?.rawValue ?? "privateDatabase"
        let allItemsCount = items.count
        let familyItemsCount = items.filter { $0.family?.id == family.id }.count
        let orphanItemsCount = items.filter { $0.family == nil }.count
        let allBagsCount = bags.count
        let familyBagsCount = bags.filter { $0.family?.id == family.id }.count
        let orphanBagsCount = bags.filter { $0.family == nil }.count
        debugLog(
            """
            [CloudKit] iCloudに保存: zone=\(zoneName) scope=\(databaseScope) \
            items(all=\(allItemsCount), family=\(familyItemsCount), orphan=\(orphanItemsCount)) \
            bags(all=\(allBagsCount), family=\(familyBagsCount), orphan=\(orphanBagsCount))
            """
        )

        Task { @MainActor in
            defer { isSavingFamilyDataToCloud = false }

            do {
                let sharingService = CloudKitFamilySharingService(modelContext: modelContext)
                try await sharingService.syncFamilyDataToCloudKit(for: family)
                let remoteCounts = try await sharingService.fetchRemoteRecordCounts(for: family)
                debugLog(
                    """
                    [CloudKit] iCloud保存後: remote(family=\(remoteCounts.familyCount), \
                    bags=\(remoteCounts.bagCount), items=\(remoteCounts.itemCount))
                    """
                )
                try await sharingService.syncFamilyStateFromCloudKit(for: family)
            } catch {
                shareError = L10n.format("iCloud保存に失敗しました: %@", error.localizedDescription)
                showShareError = true
            }
        }
    }

    @MainActor
    private func autoSyncFamilyStateIfPossible() async {
        guard family.shareState != .localOnly else { return }
        guard autoSyncedFamilyID != family.id else { return }
        autoSyncedFamilyID = family.id

        do {
            let sharingService = CloudKitFamilySharingService(modelContext: modelContext)
            try await sharingService.syncFamilyStateFromCloudKit(for: family)
        } catch {
            // 自動同期の失敗はUI操作を妨げない。
        }
    }

    @MainActor
    private func refreshParticipantDisplays(forceRefresh: Bool = false) async {
        guard usesCloudKitParticipantList else {
            participantDisplays = []
            isLoadingParticipants = false
            return
        }

        isLoadingParticipants = true
        defer { isLoadingParticipants = false }

        do {
            let sharingService = CloudKitFamilySharingService(modelContext: modelContext)
            participantDisplays = try await sharingService.fetchShareParticipants(
                for: family,
                forceRefresh: forceRefresh
            )
        } catch {
            participantDisplays = []
        }
    }

    private func debugLog(_ message: @autoclosure () -> String) {
        #if DEBUG
        print(message())
        #endif
    }
}

private struct ShareActivityPayload: Identifiable {
    let id = UUID()
    let message: String
    let url: URL
}

private struct ShareActivitySheet: UIViewControllerRepresentable {
    let payload: ShareActivityPayload

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(
            activityItems: [payload.message, payload.url],
            applicationActivities: nil
        )
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct CloudKitSharingSheet: UIViewControllerRepresentable {
    let share: CKShare
    let container: CKContainer
    var onDidStopSharing: (() -> Void)?
    var onError: ((Error) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onDidStopSharing: onDidStopSharing, onError: onError)
    }

    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController(share: share, container: container)
        controller.availablePermissions = [.allowReadWrite, .allowPrivate]
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UICloudSharingController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        private let onDidStopSharing: (() -> Void)?
        private let onError: ((Error) -> Void)?

        init(
            onDidStopSharing: (() -> Void)?,
            onError: ((Error) -> Void)?
        ) {
            self.onDidStopSharing = onDidStopSharing
            self.onError = onError
        }

        func itemTitle(for csc: UICloudSharingController) -> String? {
            L10n.string("Stockpile 家族共有")
        }

        func cloudSharingController(
            _ csc: UICloudSharingController,
            failedToSaveShareWithError error: any Error
        ) {
            onError?(error)
        }

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
