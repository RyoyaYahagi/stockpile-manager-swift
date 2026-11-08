import SwiftData
import SwiftUI

/// Muse連携（読み取り専用）の設定ビュー
/// 利用者が自分の送信先（Cloudflare Worker 等）を設定し、備蓄スナップショットを送る。
/// 連携は無料・デフォルトOFF。書き込みトークンは Keychain にだけ保存する。
struct AILinkSettingsView: View {
  @Environment(\.dismiss) private var dismiss

  @Query(sort: \Item.createdAt, order: .forward) private var items: [Item]
  @Query(sort: \Family.createdAt, order: .reverse) private var families: [Family]

  @State private var isEnabled = SnapshotLinkSettings.isEnabled
  @State private var destination = SnapshotLinkSettings.destination
  @State private var autoUploadEnabled = SnapshotLinkSettings.autoUploadEnabled
  @State private var writeEnabled = CommandWritePermissionSettings.writesEnabled
  @State private var writePermissions: [CommandWriteCapability: CommandWritePermission] =
    Dictionary(
      uniqueKeysWithValues: CommandWriteCapability.allCases.map {
        ($0, CommandWritePermissionSettings.permission(for: $0))
      }
    )
  @State private var endpointString = SnapshotLinkSettings.endpointURLString
  @State private var writeToken = SnapshotLinkKeychain.readWriteToken() ?? ""
  @State private var isSending = false
  @State private var showSendConfirmation = false
  @State private var sendResult: SendResult?
  @State private var promptCopied = false

  @Environment(GoogleDriveLinkManager.self) private var googleLink
  @State private var isGoogleSigningIn = false
  @State private var googleError: String?

  enum SendResult {
    case success(String)
    case error(String)
  }

  private var currentFamily: Family? {
    CurrentFamilyResolver.currentFamily(from: families)
  }

  /// 書き出し（バックアップ）と同じスコープ規則（自動送信と共通）
  private var scopedItems: [Item] {
    SnapshotLinkScope.resolved(items: items, families: families).items
  }

  /// 前回の送信成功時点から内容が変わっているか
  private var hasUnsentChanges: Bool {
    SnapshotFingerprint.compute(items: scopedItems, familyName: currentFamily?.name)
      != SnapshotLinkSettings.lastUploadedFingerprint(for: destination)
  }

  private var isSharedFamily: Bool {
    currentFamily?.isCloudKitSharedFamily ?? false
  }

  private var lastSentText: String? {
    guard let date = SnapshotLinkSettings.lastSentAt(for: destination) else { return nil }
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
            title: "Muse連携",
            subtitle: "備蓄データをMuseと連携します（上級者向け）"
          )
          .riseIn(index: 0)

          if let sendResult {
            resultView(sendResult)
              .riseIn(index: 1)
          }

          settingsCard
            .riseIn(index: 2)

          writePermissionCard
            .riseIn(index: 3)

          if isSharedFamily {
            BackupWarningCard(
              title: L10n.string("家族共有中のデータが含まれます"),
              message: L10n.string("この連携を有効にすると、共有中の家族の備蓄データが、あなたが設定した送信先に送られます。送信はこの端末からのみ行われます。")
            )
            .riseIn(index: 4)
          }

          BackupWarningCard(
            title: L10n.string("送信データは暗号化されません"),
            message: L10n.string(
              "スナップショットは平文のJSONです。アイテム名、JAN、期限、収納場所メモが含まれます。送信先は自分で管理する場所だけを設定してください。")
          )
          .riseIn(index: 5)

          sendCard
            .riseIn(index: 6)

          promptCard
            .riseIn(index: 7)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 32)
      }
      .appScreenBackground()
      .tint(AppTheme.accent)
      .navigationTitle(L10n.string("Muse連携"))
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
        Text(
          L10n.format(
            "送信先: %@\n対象: %@件のアイテム",
            destination == .googleDrive
              ? "Google Drive（Stockpile/snapshot.json）" : endpointString,
            String(scopedItems.count)))
      }
      .onChange(of: isEnabled) { _, newValue in
        SnapshotLinkSettings.isEnabled = newValue
        // 連携そのものを無効にしたら、承認待ちと未送信の結果は送り先を失うため破棄する。
        if !newValue {
          CommandInboxApprovalCoordinator.discardForLinkRemoval()
        }
      }
      .onChange(of: destination) { oldValue, newValue in
        SnapshotLinkSettings.destination = newValue
        promptCopied = false
        // 送信先の切り替えでも、前の送信先向けの承認待ちは破棄する。
        if oldValue != newValue {
          CommandInboxApprovalCoordinator.discardForLinkRemoval()
        }
      }
      .onChange(of: autoUploadEnabled) { _, newValue in
        SnapshotLinkSettings.autoUploadEnabled = newValue
      }
      .onChange(of: writeEnabled) { _, newValue in
        CommandWritePermissionSettings.writesEnabled = newValue
        // キルスイッチ: OFF にした時点で承認待ちをすべて writes_disabled にする。
        if !newValue {
          CommandInboxApprovalCoordinator.killSwitchTurnedOff()
        }
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
        Text(L10n.string("Muse連携を使う"))
          .font(.headline)
      }

      if isEnabled {
        VStack(alignment: .leading, spacing: 6) {
          Text(L10n.string("送信先"))
            .font(.subheadline.weight(.semibold))
          Picker(L10n.string("送信先"), selection: $destination) {
            Text(L10n.string("カスタムURL")).tag(SnapshotDestination.customURL)
            Text("Google Drive").tag(SnapshotDestination.googleDrive)
          }
          .pickerStyle(.segmented)
          .labelsHidden()
        }

        if destination == .customURL {
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
          Text(L10n.string("トークンはこの端末のKeychainにだけ保存されます。読み取りトークンはMuse側に別途渡してください。"))
            .font(.caption)
            .foregroundStyle(AppTheme.inkSecondary)
          }
        } else {
          googleDriveSection
        }

        Divider()

        Toggle(isOn: $autoUploadEnabled) {
          Text(L10n.string("自動送信"))
            .font(.subheadline.weight(.semibold))
        }
        Text(L10n.string("アイテムの追加・変更・削除を検知して自動で送信します。バックグラウンドでの定期送信はiOSの制約のためできません。対象は、アプリを開いた時と開いている間の変更です。"))
          .font(.caption)
          .foregroundStyle(AppTheme.inkSecondary)
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardSurface(radius: 20)
  }

  /// Google Drive 選択時の連携セクション（G-02。Drive への実送信は G-03 / G-04）
  @ViewBuilder
  private var googleDriveSection: some View {
    if googleLink.isRestoring {
      HStack(spacing: 8) {
        ProgressView()
        Text(L10n.string("連携状態を確認しています…"))
          .font(.caption)
          .foregroundStyle(AppTheme.inkSecondary)
      }
    } else if googleLink.isSignedIn {
      HStack(spacing: 10) {
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(AppTheme.accent)
        VStack(alignment: .leading, spacing: 2) {
          Text(L10n.string("Google Driveと連携中"))
            .font(.subheadline.weight(.semibold))
          if let email = googleLink.accountEmail {
            Text(email)
              .font(.caption)
              .foregroundStyle(AppTheme.inkSecondary)
          }
        }
        Spacer()
        Button(L10n.string("連携を解除")) {
          googleLink.signOut()
        }
        .font(.subheadline)
      }

      if !googleLink.hasDriveScope {
        Text(L10n.string("Driveへの保存権限が許可されていません。一度連携を解除して、連携し直してください。"))
          .font(.caption)
          .foregroundStyle(AppTheme.inkSecondary)
      }
    } else {
      Button {
        Task { await performGoogleSignIn() }
      } label: {
        Label(
          isGoogleSigningIn ? L10n.string("サインイン中…") : L10n.string("Google Driveと連携"),
          systemImage: "link"
        )
        .font(.subheadline.weight(.semibold))
      }
      .buttonStyle(.plain)
      .foregroundStyle(AppTheme.accent)
      .disabled(isGoogleSigningIn)

      if let googleError {
        Text(googleError)
          .font(.caption)
          .foregroundStyle(.red)
      }
    }

    Text(L10n.format("スナップショットは、あなたのGoogle Driveに「%@」フォルダを作って保存されます。このアプリが作ったファイルにだけアクセスします。", GoogleDriveSnapshotWriter.folderName))
      .font(.caption)
      .foregroundStyle(AppTheme.inkSecondary)
  }

  private func performGoogleSignIn() async {
    isGoogleSigningIn = true
    googleError = nil
    defer { isGoogleSigningIn = false }
    do {
      _ = try await googleLink.signIn()
    } catch {
      googleError = error.localizedDescription
    }
  }

  /// 書き込み権限の設定（W-02）。スイッチはキルスイッチを兼ねる。
  private var writePermissionCard: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(L10n.string("書き込み権限"))
        .font(.headline)

      Toggle(isOn: $writeEnabled) {
        Text(L10n.string("書き込み連携を使う"))
          .font(.subheadline.weight(.semibold))
      }

      Text(L10n.string("Museが権限の範囲で備蓄データを変更できるようにします。既定はオフです。オフの間はすべてのコマンドを適用しません。"))
        .font(.caption)
        .foregroundStyle(AppTheme.inkSecondary)

      if writeEnabled {
        Text(L10n.string("能力ごとに「許可」「承認制」「不可」を選べます。承認制はアプリ内で承認するまでデータを変更しません。"))
          .font(.caption)
          .foregroundStyle(AppTheme.inkSecondary)

        ForEach(CommandWriteCapability.allCases, id: \.self) { capability in
          VStack(alignment: .leading, spacing: 6) {
            Text(capability.displayName)
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(AppTheme.ink)
            Picker(capability.displayName, selection: permissionBinding(for: capability)) {
              ForEach(CommandWritePermission.allCases, id: \.self) { permission in
                Text(permission.displayName).tag(permission)
              }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
          }
        }
      }

      Divider()

      NavigationLink {
        CommandInboxHistoryView()
      } label: {
        HStack(spacing: 14) {
          SettingsIconTile(symbol: "clock.arrow.circlepath", tint: AppTheme.accent)
          Text(L10n.string("適用履歴"))
            .font(.body.weight(.semibold))
            .foregroundStyle(AppTheme.ink)
          Spacer(minLength: 8)
          Image(systemName: "chevron.right")
            .font(.footnote.weight(.bold))
            .foregroundStyle(AppTheme.inkSecondary.opacity(0.6))
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardSurface(radius: 20)
  }

  private func permissionBinding(
    for capability: CommandWriteCapability
  ) -> Binding<CommandWritePermission> {
    Binding(
      get: { writePermissions[capability] ?? capability.defaultPermission },
      set: { newValue in
        writePermissions[capability] = newValue
        CommandWritePermissionSettings.setPermission(newValue, for: capability)
      }
    )
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

      if isEnabled && hasUnsentChanges {
        Text(L10n.string("前回の送信から変更があります"))
          .font(.caption)
          .foregroundStyle(AppTheme.inkSecondary)
      }
    }
  }

  /// 送信先に応じたセットアップ依頼文（カスタムURLは v1、Google Driveは v2）
  private var setupPromptText: String {
    destination == .googleDrive
      ? SnapshotLinkPrompt.makeDrivePrompt()
      : SnapshotLinkPrompt.makePrompt(snapshotURLString: endpointString)
  }

  private var promptDescription: String {
    destination == .googleDrive
      ? L10n.string("下の文をコピーして、あなたのClaudeに貼ると連携設定が始まります。トークンやURLは不要です。")
      : L10n.string("下の文をコピーして、あなたのClaudeに貼ると連携設定が始まります。トークンはこの文に含まれていません。")
  }

  private var promptCard: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(L10n.string("Museへのセットアップ依頼"))
        .font(.headline)
      Text(promptDescription)
        .font(.caption)
        .foregroundStyle(AppTheme.inkSecondary)

      Text(setupPromptText)
        .font(.caption.monospaced())
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(AppTheme.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

      Button {
        UIPasteboard.general.string = setupPromptText
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

  /// 選択中の送信先に応じて送信する（G-04）
  private func performSend() async {
    switch destination {
    case .customURL:
      await performSendToCustomURL()
    case .googleDrive:
      await performSendToDrive()
    }
  }

  private func performSendToCustomURL() async {
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
      SnapshotLinkSettings.setLastSentAt(Date(), for: .customURL)
      SnapshotLinkSettings.setLastUploadedFingerprint(
        SnapshotFingerprint.compute(items: scopedItems, familyName: currentFamily?.name),
        for: .customURL)
      let count = (response["itemCount"] as? Int) ?? scopedItems.count
      sendResult = .success(L10n.format("%@件のアイテムを送信しました", String(count)))
    } catch let error as SnapshotUploadError {
      sendResult = .error(error.errorDescription ?? error.localizedDescription)
    } catch {
      sendResult = .error(error.localizedDescription)
    }
  }

  private func performSendToDrive() async {
    isSending = true
    defer { isSending = false }

    do {
      let data = try SnapshotBuilder.makeJSONData(
        items: scopedItems,
        familyName: currentFamily?.name
      )
      try await googleLink.uploadSnapshot(data: data)
      SnapshotLinkSettings.setLastSentAt(Date(), for: .googleDrive)
      SnapshotLinkSettings.setLastUploadedFingerprint(
        SnapshotFingerprint.compute(items: scopedItems, familyName: currentFamily?.name),
        for: .googleDrive)
      sendResult = .success(
        L10n.format("%@件のアイテムを送信しました", String(scopedItems.count)))
    } catch let error as GoogleDriveUploadError {
      sendResult = .error(error.errorDescription ?? error.localizedDescription)
    } catch {
      sendResult = .error(error.localizedDescription)
    }
  }
}

#Preview("AILinkSettingsView") {
  AILinkSettingsView()
    .environment(GoogleDriveLinkManager.shared)
    .modelContainer(for: [Family.self, Item.self], inMemory: true)
}
