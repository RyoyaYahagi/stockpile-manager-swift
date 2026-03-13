import SwiftUI
import SwiftData

/// 設定画面
struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(Router.self) private var router
    
    @Query(sort: \Family.createdAt, order: .reverse) private var families: [Family]
    @AppStorage(APIConfig.firebaseDeveloperModeKey)
    private var isFirebaseDeveloperModeEnabled = false
    @AppStorage("app.tutorial.replayRequestToken")
    private var tutorialReplayRequestToken = 0
    
    private var currentFamily: Family? {
        CurrentFamilyResolver.currentFamily(from: families)
    }
    
    var body: some View {
        List {
            // 家族セクション
            Section {
                if let family = currentFamily {
                    NavigationLink(value: Destination.familySettings(family)) {
                        HStack {
                            Label("家族共有設定", systemImage: "person.3")
                            Spacer()
                            Text(family.name)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    // メンバー数
                    HStack {
                        Label("メンバー", systemImage: "person.2")
                        Spacer()
                        Text("\(family.uniqueMembers.count)人")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button {
                        router.push(.familySetup)
                    } label: {
                        Label("家族を設定", systemImage: "person.3.fill")
                    }
                }
            } header: {
                Text("家族")
            } footer: {
                if currentFamily != nil {
                    Text("通常のデータ同期はiCloudで行います。Firebase連携は開発者オプション有効時のみ表示されます。")
                }
            }
            
            // 収納場所セクション
            Section {
                NavigationLink(value: Destination.bagList) {
                    Label("収納場所", systemImage: "bag")
                }
            } header: {
                Text("管理")
            }
            
            // 通知セクション
            Section {
                NavigationLink(value: Destination.notificationSettings) {
                    Label("通知", systemImage: "bell")
                }
            } header: {
                Text("通知")
            }

            // ガイドセクション
            Section {
                Button {
                    tutorialReplayRequestToken += 1
                    router.popToRoot()
                } label: {
                    Label("はじめての使い方を見る", systemImage: "questionmark.circle")
                }
            } header: {
                Text("ガイド")
            }
            
            // データセクション
            Section {
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
            } header: {
                Text("データ")
            }

            Section {
                Toggle("Firebase連携を有効化", isOn: $isFirebaseDeveloperModeEnabled)
            } header: {
                Text("開発者オプション")
            } footer: {
                Text("既定ではiCloudで同一Apple IDの端末間同期を行います。家族の別Apple IDと共有する場合は家族設定からiCloud共有リンクを作成します。Firebaseは検証用に明示的に有効化した場合のみ利用します。")
            }
            
            // アプリ情報
            Section {
                HStack {
                    Label("バージョン", systemImage: "info.circle")
                    Spacer()
                    Text("1.0.0")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("アプリ情報")
            }
        }
        .navigationTitle("設定")
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
    .environment(Router())
    .modelContainer(for: [Family.self], inMemory: true)
}
