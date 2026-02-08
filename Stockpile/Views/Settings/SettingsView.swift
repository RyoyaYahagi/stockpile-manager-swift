import SwiftUI
import SwiftData

/// 設定画面
struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(Router.self) private var router
    
    @Query private var families: [Family]
    
    private var currentFamily: Family? {
        families.first
    }
    
    var body: some View {
        List {
            // 家族セクション
            Section {
                if let family = currentFamily {
                    // 家族名を表示（CloudKitなしのシンプル版）
                    HStack {
                        Label("家族名", systemImage: "person.3")
                        Spacer()
                        Text(family.name)
                            .foregroundStyle(.secondary)
                    }
                    
                    // メンバー数
                    HStack {
                        Label("メンバー", systemImage: "person.2")
                        Spacer()
                        Text("\(family.members.count)人")
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
            
            // データセクション
            Section {
                Button {
                    router.present(.importJSON)
                } label: {
                    Label("JSONインポート", systemImage: "square.and.arrow.down")
                }
            } header: {
                Text("データ")
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
