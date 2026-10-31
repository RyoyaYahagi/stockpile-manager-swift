import SwiftUI
import SwiftData

/// 設定画面
struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(Router.self) private var router
    @Environment(LocalizationController.self) private var localizationController
    
    @Query(sort: \Family.createdAt, order: .reverse) private var families: [Family]
    @AppStorage("app.tutorial.replayRequestToken")
    private var tutorialReplayRequestToken = 0
    @State private var cloudKitMemberCount: Int?
    @State private var isLoadingCloudKitMemberCount = false
    private var currentFamily: Family? {
        CurrentFamilyResolver.currentFamily(from: families)
    }

    private var memberCountRefreshKey: String {
        guard let family = currentFamily else { return "none" }
        let scope = family.cloudKitDatabaseScope?.rawValue ?? "local"
        let shareURL = family.cloudKitShareURL?.absoluteString ?? "no-share"
        return "\(family.id.uuidString)|\(scope)|\(shareURL)|\(family.cloudKitPendingSync)"
    }

    private var displayedMemberCountText: String {
        guard let family = currentFamily else { return L10n.string("同期中") }
        guard family.shareState != .localOnly else {
            return L10n.format("%@人", String(family.uniqueMembers.count))
        }
        guard let cloudKitMemberCount else {
            return L10n.string("同期中")
        }
        return L10n.format("%@人", String(cloudKitMemberCount))
    }

    private var selectedAppLanguage: AppLanguage {
        localizationController.selectedLanguage
    }
    
    var body: some View {
        let refreshToken = localizationController.uiRefreshToken

        List {
            // 家族セクション
            Section {
                Group {
                if let family = currentFamily {
                    NavigationLink(value: Destination.familySettings(family)) {
                        HStack {
                            Label("家族共有設定", systemImage: "person.3")
                            Spacer()
                            Text(family.displayNameForCurrentState)
                                .foregroundStyle(AppTheme.inkSecondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                    }
                    
                    // メンバー数
                    HStack {
                        Label("メンバー", systemImage: "person.2")
                        Spacer()
                        Text(displayedMemberCountText)
                            .foregroundStyle(AppTheme.inkSecondary)
                    }
                } else {
                    Button {
                        router.push(.familySetup)
                    } label: {
                        Label("家族を設定", systemImage: "person.3.fill")
                    }
                }
                }
                .listRowBackground(AppTheme.card)
            } header: {
                Text("家族")
            } footer: {
                if currentFamily != nil {
                    Text("通常のデータ同期と家族共有は iCloud で行います。")
                }
            }

            // 収納場所セクション
            Section {
                NavigationLink(value: Destination.bagList) {
                    Label("収納場所", systemImage: "bag")
                }
                .listRowBackground(AppTheme.card)
            } header: {
                Text("管理")
            }
            
            // 通知セクション
            Section {
                NavigationLink(value: Destination.notificationSettings) {
                    Label("通知", systemImage: "bell")
                }
                .listRowBackground(AppTheme.card)
            } header: {
                Text("通知")
            }

            Section {
                NavigationLink {
                    LanguageSettingsView()
                } label: {
                    HStack {
                        Label("言語", systemImage: "globe")
                        Spacer()
                        Text(selectedAppLanguage.displayName)
                            .foregroundStyle(AppTheme.inkSecondary)
                    }
                }
                .listRowBackground(AppTheme.card)
            } header: {
                Text("表示")
            }

            // ガイドセクション
            Section {
                Button {
                    tutorialReplayRequestToken += 1
                    router.popToRoot()
                } label: {
                    Label("はじめての使い方を見る", systemImage: "questionmark.circle")
                }
                .listRowBackground(AppTheme.card)
            } header: {
                Text("ガイド")
            }
            
            // データセクション
            Section {
                Group {
                Button {
                    router.present(.exportJSON)
                } label: {
                    Label("バックアップを書き出す", systemImage: "square.and.arrow.up")
                }

                Button {
                    router.present(.importJSON)
                } label: {
                    Label("バックアップから復元", systemImage: "square.and.arrow.down")
                }
                }
                .listRowBackground(AppTheme.card)
            } header: {
                Text("データ")
            }

            // アプリ情報
            Section {
                Group {
                HStack {
                    Label("バージョン", systemImage: "info.circle")
                    Spacer()
                    Text(appVersion)
                        .foregroundStyle(AppTheme.inkSecondary)
                }

                if let privacyPolicyURL = APIConfig.privacyPolicyURL {
                    Link(destination: privacyPolicyURL) {
                        Label("プライバシーポリシー", systemImage: "hand.raised")
                    }
                }

                if let supportURL = APIConfig.supportURL {
                    Link(destination: supportURL) {
                        Label("サポート", systemImage: "questionmark.circle")
                    }
                }
                }
                .listRowBackground(AppTheme.card)
            } header: {
                Text("アプリ情報")
            }
        }
        .appScreenBackground()
        .tint(AppTheme.accent)
        .navigationTitle("設定")
        .id(refreshToken)
        .localizedRefresh()
        .task(id: memberCountRefreshKey) {
            await refreshCloudKitMemberCount()
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
    }

    @MainActor
    private func refreshCloudKitMemberCount() async {
        guard let family = currentFamily else {
            cloudKitMemberCount = nil
            isLoadingCloudKitMemberCount = false
            return
        }

        guard family.shareState != .localOnly else {
            cloudKitMemberCount = nil
            isLoadingCloudKitMemberCount = false
            return
        }

        isLoadingCloudKitMemberCount = true
        defer { isLoadingCloudKitMemberCount = false }

        do {
            let sharingService = CloudKitFamilySharingService(modelContext: modelContext)
            cloudKitMemberCount = try await sharingService.fetchShareParticipants(for: family).count
        } catch {
            cloudKitMemberCount = nil
        }
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
    .environment(Router())
    .modelContainer(for: [Family.self], inMemory: true)
}
