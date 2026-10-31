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
    @State private var showInvitePanel = false
    @State private var showRenameSheet = false

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
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("家族")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .foregroundStyle(AppTheme.ink)
                    .accessibilityAddTraits(.isHeader)

                familyCard
                    .padding(.top, 20)
                    .riseIn()

                if showInvitePanel && !isParticipantFamily {
                    invitePanel
                        .padding(.top, 12)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                SectionHeading(title: "共有データ")
                    .padding(.top, 28)
                    .padding(.bottom, 12)
                dataCard
                    .riseIn(index: 3)

                if isParticipantFamily {
                    leaveCard
                        .padding(.top, 28)
                        .riseIn(index: 4)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .refreshable {
            // 下に引っ張ると、家族の備蓄と参加者を iCloud から読み直す
            let sharingService = CloudKitFamilySharingService(modelContext: modelContext)
            try? await sharingService.syncFamilyStateFromCloudKit(for: family)
            await refreshParticipantDisplays(forceRefresh: true)
        }
        .appScreenBackground()
        .tint(AppTheme.accent)
        .toolbar(.hidden, for: .navigationBar)
        .localizedRefresh()
        .sheet(isPresented: $showRenameSheet) {
            NavigationStack {
                Form {
                    Section {
                        TextField("家族名", text: $editedName)
                            .submitLabel(.done)
                            .listRowBackground(AppTheme.card)
                    }
                }
                .appScreenBackground()
                .tint(AppTheme.accent)
                .navigationTitle("家族名を変更")
                .navigationBarTitleDisplayMode(.inline)
                .localizedRefresh()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("キャンセル") { showRenameSheet = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            saveChanges()
                            showRenameSheet = false
                        }
                        .fontWeight(.bold)
                        .disabled(editedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .presentationDetents([.height(220)])
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
                            .listRowBackground(AppTheme.card)
                    } header: {
                        Text("家族名")
                    } footer: {
                        Text("最初に家族名を登録すると、その名前で共有リンクを送信できます。")
                    }
                }
                .appScreenBackground()
                .tint(AppTheme.accent)
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

    // MARK: - Family card

    private var syncPillTitle: String {
        if isAnyCloudSyncInFlight { return L10n.string("同期中") }
        return family.shareState == .shared ? L10n.string("同期済み") : family.shareState.label
    }

    private var syncPillIcon: String {
        switch family.shareState {
        case .shared: return isAnyCloudSyncInFlight ? "arrow.triangle.2.circlepath.icloud" : "checkmark.icloud"
        case .preparing: return "arrow.triangle.2.circlepath.icloud"
        case .localOnly: return "icloud.slash"
        }
    }

    private var familyCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(family.displayNameForCurrentState)
                        .font(.system(.title3, design: .rounded, weight: .bold))
                        .foregroundStyle(AppTheme.ink)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                    Text(displayedMemberCount > 0
                         ? L10n.format("%@人で備蓄を共有中", String(displayedMemberCount))
                         : memberSectionFooter)
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        editedName = family.name
                        showRenameSheet = true
                    } label: {
                        Label("名前を変更", systemImage: "pencil")
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(AppTheme.accentInk)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 32)
                            .background(AppTheme.accentSoft, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(PressableButtonStyle())
                    .padding(.top, 6)
                    .frame(minHeight: 44)
                }
                Spacer(minLength: 8)
                HStack(spacing: 5) {
                    Image(systemName: syncPillIcon)
                        .font(.caption.weight(.bold))
                    Text(syncPillTitle)
                        .font(.caption.weight(.bold))
                        .lineLimit(1)
                }
                .foregroundStyle(AppTheme.accentInk)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(AppTheme.accentSoft, in: Capsule())
            }

            Divider()

            VStack(spacing: 14) {
                if usesCloudKitParticipantList {
                    ForEach(Array(participantDisplays.enumerated()), id: \.element.id) { index, participant in
                        memberRow(
                            name: participant.displayName,
                            role: participant.statusLabel,
                            index: index
                        )
                    }
                } else {
                    ForEach(Array(displayedLocalMembers.enumerated()), id: \.element.id) { index, member in
                        memberRow(
                            name: member.displayName,
                            role: member.email ?? L10n.string("メンバー"),
                            index: index
                        )
                    }
                }
            }

            if !isParticipantFamily {
                Button {
                    toggleInvitePanel()
                } label: {
                    Label("家族を招待する", systemImage: showInvitePanel ? "xmark" : "plus")
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                }
                .buttonStyle(PrimaryActionButtonStyle())
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private static let avatarColors: [Color] = [
        Color(light: 0xCBE5D5, dark: 0x2B5A44),
        Color(light: 0xF7D9BC, dark: 0x6A4526),
        Color(light: 0xD6DFF3, dark: 0x30406E),
        Color(light: 0xEBD3EA, dark: 0x5A3A58)
    ]

    private func memberRow(name: String, role: String, index: Int) -> some View {
        HStack(spacing: 12) {
            Text(String(name.trimmingCharacters(in: .whitespaces).prefix(1)))
                .font(.system(.headline, design: .rounded, weight: .bold))
                .foregroundStyle(AppTheme.ink)
                .frame(width: 44, height: 44)
                .background(Self.avatarColors[index % Self.avatarColors.count], in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.body.weight(.bold))
                    .foregroundStyle(AppTheme.ink)
                    .lineLimit(1)
                Text(role)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.inkSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }

    private func toggleInvitePanel() {
        withAnimation(AppTheme.accordionAnimation) {
            showInvitePanel.toggle()
        }
    }

    // MARK: - Invite panel

    private var invitePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                handleShareButtonTap()
            } label: {
                HStack(spacing: 8) {
                    Label(shareButtonTitle, systemImage: "link")
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                    if isStartingShare {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                    }
                }
            }
            .buttonStyle(PrimaryActionButtonStyle())
            .disabled(isStartingShare || isOpeningShareManagement)

            if canManageShare {
                Button {
                    openShareManagement()
                } label: {
                    HStack(spacing: 8) {
                        Label("共有設定を管理", systemImage: "person.crop.circle.badge.checkmark")
                            .lineLimit(2)
                            .minimumScaleFactor(0.85)
                        if isOpeningShareManagement {
                            ProgressView()
                                .progressViewStyle(.circular)
                        }
                    }
                }
                .buttonStyle(SecondaryActionButtonStyle())
                .disabled(isStartingShare || isOpeningShareManagement)
            }

            Text(invitationSectionFooter)
                .font(.footnote)
                .foregroundStyle(AppTheme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    // MARK: - Setting cards

    private var dataCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Label("収納場所", systemImage: "bag")
                    .foregroundStyle(AppTheme.ink)
                Spacer(minLength: 8)
                Text(L10n.format("%@件", String(scopedBagsCount)))
                    .foregroundStyle(AppTheme.inkSecondary)
            }
            .frame(minHeight: 44)

            Divider()

            HStack(spacing: 12) {
                Label("アイテム", systemImage: "archivebox")
                    .foregroundStyle(AppTheme.ink)
                Spacer(minLength: 8)
                Text(L10n.format("%@件", String(scopedItemsCount)))
                    .foregroundStyle(AppTheme.inkSecondary)
            }
            .frame(minHeight: 44)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private var leaveCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                showLeaveConfirmation = true
            } label: {
                Label("共有家族から離脱", systemImage: "person.badge.minus")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(AppTheme.color(for: .expired))
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text("離脱すると、この家族の共有データにアクセスできなくなります")
                .font(.footnote)
                .foregroundStyle(AppTheme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
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
