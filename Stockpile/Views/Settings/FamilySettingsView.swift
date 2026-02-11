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
    @State private var shareError: String?
    @State private var showShareError = false

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
            } header: {
                Text("招待")
            } footer: {
                Text("QRコードまたは6桁のコードを共有して、家族を招待できます。招待コードは24時間有効です。")
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

                _ = try await sharingService.startSharing(family: family)

                isStartingShare = false
                router.present(.inviteCode(family.inviteCode))
            } catch {
                isStartingShare = false

                if case FamilySharingService.SharingError.notSignedIn = error {
                    shareError = "iCloudにサインインしてください。設定アプリからiCloudにサインインした後、再試行してください。"
                } else {
                    shareError = "共有の開始に失敗しました: \(error.localizedDescription)"
                }
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
}

#Preview {
    NavigationStack {
        FamilySettingsView(family: Family(name: "テスト家族"))
    }
    .environment(Router())
    .modelContainer(for: [Family.self], inMemory: true)
}
