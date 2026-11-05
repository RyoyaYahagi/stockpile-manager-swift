import SwiftData
import SwiftUI

/// AI連携（読み取り専用）の設定ビュー
/// 利用者が自分の送信先（Cloudflare Worker 等）を設定し、備蓄スナップショットを送る。
/// 連携は無料・デフォルトOFF。書き込みトークンは Keychain にだけ保存する。
struct AILinkSettingsView: View {
  @Environment(\.dismiss) private var dismiss

  @Query(sort: \Item.createdAt, order: .forward) private var items: [Item]
  @Query(sort: \Family.createdAt, order: .reverse) private var families: [Family]

  @State private var isEnabled = SnapshotLinkSettings.isEnabled
  @State private var endpointString = SnapshotLinkSettings.endpointURLString
  @State private var writeToken = SnapshotLinkKeychain.readWriteToken() ?? ""
  @State private var isSending = false
  @State private var showSendConfirmation = false
  @State private var sendResult: SendResult?
  @State private var promptCopied = false

  enum SendResult {
    case success(String)
    case error(String)
  }

  private var currentFamily: Family? {
    CurrentFamilyResolver.currentFamily(from: families)
  }

  /// 書き出し（バックアップ）と同じスコープ規則
  private var scopedItems: [Item] {
    guard let family = currentFamily else {
      return items.filter { $0.family == nil }
    }
    let familyItems = items.filter { $0.family?.id == family.id }
    if !familyItems.isEmpty || family.prefersStrictCloudKitScoping {
      return familyItems
    }
    return items.filter { $0.family == nil }
  }

  private var isSharedFamily: Bool {
    currentFamily?.isCloudKitSharedFamily ?? false
  }

  private var lastSentText: String? {
    guard let date = SnapshotLinkSettings.lastSentAt else { return nil }
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter.string(from: date)
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 16) {
          BackupHeaderCard(
            icon: "sparkles",
            title: "AI連携",
            subtitle: "備蓄データを自分のAIアシスタントに読み取り専用で渡します（上級者向け）"
          )
          .riseIn(index: 0)

          if let sendResult {
            resultView(sendResult)
              .riseIn(index: 1)
          }

          settingsCard
            .riseIn(index: 2)

          if isSharedFamily {
            BackupWarningCard(
              title: L10n.string("家族共有中のデータが含まれます"),
              message: L10n.string("この連携を有効にすると、共有中の家族の備蓄データが、あなたが設定した送信先に送られます。送信はこの端末からのみ行われます。")
            )
            .riseIn(index: 3)
          }

          BackupWarningCard(
            title: L10n.string("送信データは暗号化されません"),
            message: L10n.string(
              "スナップショットは平文のJSONです。アイテム名、JAN、期限、収納場所メモが含まれます。送信先は自分で管理する場所だけを設定してください。")
          )
          .riseIn(index: 4)

          sendCard
            .riseIn(index: 5)

          promptCard
            .riseIn(index: 6)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 32)
      }
      .appScreenBackground()
      .tint(AppTheme.accent)
      .navigationTitle(L10n.string("AI連携"))
      .navigationBarTitleDisplayMode(.inline)
      .localizedRefresh()
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(L10n.string("閉じる")) { dismiss() }
        }
      }
      .alert(L10n.string("スナップショットを送信しますか？"), isPresented: $showSendConfirmation) {
        Button(L10n.string("キャンセル"), role: .cancel) {}
        Button(L10n.string("送信する")) {
          Task { await performSend() }
        }
      } message: {
        Text(L10n.format("送信先: %@\n対象: %@件のアイテム", endpointString, String(scopedItems.count)))
      }
      .onChange(of: isEnabled) { _, newValue in
        SnapshotLinkSettings.isEnabled = newValue
      }
      .onChange(of: endpointString) { _, newValue in
        SnapshotLinkSettings.endpointURLString = newValue
      }
      .onChange(of: writeToken) { _, newValue in
        SnapshotLinkKeychain.saveWriteToken(newValue)
      }
    }
  }

  private var settingsCard: some View {
    VStack(alignment: .leading, spacing: 12) {
      Toggle(isOn: $isEnabled) {
        Text(L10n.string("AI連携を使う"))
          .font(.headline)
      }

      if isEnabled {
        VStack(alignment: .leading, spacing: 6) {
          Text(L10n.string("送信先URL"))
            .font(.subheadline.weight(.semibold))
          TextField(
            "https://stockpile-snapshot.example.workers.dev/v1/snapshot", text: $endpointString
          )
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .keyboardType(.URL)
          .font(.footnote.monospaced())
        }

        VStack(alignment: .leading, spacing: 6) {
          Text(L10n.string("書き込みトークン"))
            .font(.subheadline.weight(.semibold))
          SecureField(L10n.string("書き込みトークン"), text: $writeToken)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.footnote.monospaced())
          Text(L10n.string("トークンはこの端末のKeychainにだけ保存されます。読み取りトークンはAI側に別途渡してください。"))
            .font(.caption)
            .foregroundStyle(AppTheme.inkSecondary)
        }
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardSurface(radius: 20)
  }

  private var sendCard: some View {
    VStack(spacing: 10) {
      Button {
        showSendConfirmation = true
      } label: {
        Label(
          isSending ? L10n.string("送信中…") : L10n.string("今すぐ送信"),
          systemImage: "paperplane"
        )
        .font(.headline)
        .padding(.vertical, 6)
      }
      .buttonStyle(PrimaryActionButtonStyle())
      .disabled(!isEnabled || isSending)

      if let lastSentText {
        Text(L10n.format("最終送信: %@", lastSentText))
          .font(.caption)
          .foregroundStyle(AppTheme.inkSecondary)
      }
    }
  }

  private var promptCard: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(L10n.string("Museへのセットアップ依頼"))
        .font(.headline)
      Text(L10n.string("下の文をコピーして、あなたのAIアシスタント（Muse）に貼ると連携設定が始まります。トークンはこの文に含まれていません。"))
        .font(.caption)
        .foregroundStyle(AppTheme.inkSecondary)

      Text(SnapshotLinkPrompt.makePrompt(snapshotURLString: endpointString))
        .font(.caption.monospaced())
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(AppTheme.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

      Button {
        UIPasteboard.general.string = SnapshotLinkPrompt.makePrompt(
          snapshotURLString: endpointString)
        promptCopied = true
      } label: {
        Label(
          promptCopied ? L10n.string("コピーしました") : L10n.string("プロンプトをコピー"),
          systemImage: promptCopied ? "checkmark" : "doc.on.doc"
        )
        .font(.subheadline.weight(.semibold))
      }
      .buttonStyle(.plain)
      .foregroundStyle(AppTheme.accent)
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardSurface(radius: 20)
  }

  @ViewBuilder
  private func resultView(_ result: SendResult) -> some View {
    switch result {
    case .success(let message):
      BackupResultBanner(isSuccess: true, message: message)
    case .error(let message):
      BackupResultBanner(isSuccess: false, message: message)
    }
  }

  private func performSend() async {
    guard let endpoint = SnapshotLinkSettings.validatedEndpoint(endpointString) else {
      sendResult = .error(SnapshotUploadError.invalidEndpoint.errorDescription ?? "")
      return
    }
    let token = writeToken.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !token.isEmpty else {
      sendResult = .error(SnapshotUploadError.notConfigured.errorDescription ?? "")
      return
    }

    isSending = true
    defer { isSending = false }

    do {
      let data = try SnapshotBuilder.makeJSONData(
        items: scopedItems,
        familyName: currentFamily?.name
      )
      let response = try await SnapshotUploader.upload(
        data: data, endpoint: endpoint, writeToken: token)
      SnapshotLinkSettings.lastSentAt = Date()
      let count = (response["itemCount"] as? Int) ?? scopedItems.count
      sendResult = .success(L10n.format("%@件のアイテムを送信しました", String(count)))
    } catch let error as SnapshotUploadError {
      sendResult = .error(error.errorDescription ?? error.localizedDescription)
    } catch {
      sendResult = .error(error.localizedDescription)
    }
  }
}

#Preview("AILinkSettingsView") {
  AILinkSettingsView()
    .modelContainer(for: [Family.self, Item.self], inMemory: true)
}
