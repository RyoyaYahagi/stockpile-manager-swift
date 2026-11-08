import SwiftData
import SwiftUI

/// 承認待ちのコマンド（W-04）。
/// 承認制のコマンドを古い順に並べ、許可・却下を選べるようにする。
/// 同じ対象を指す先行のコマンドがある間は「先のコマンド待ち」として操作できない。
struct CommandInboxApprovalView: View {
  @Environment(\.modelContext) private var modelContext
  @Query(sort: \Item.createdAt, order: .forward) private var items: [Item]
  @Query(sort: \Family.createdAt, order: .reverse) private var families: [Family]

  /// 承認待ちの件数が変わったときに設定画面へ知らせる。
  var onPendingCountChanged: (Int) -> Void = { _ in }

  @State private var queue: [CommandInboxPendingApproval] = []
  @State private var isLoading = true
  @State private var isWorking = false
  @State private var confirmationEntry: CommandInboxPendingApproval?

  private var scopedItems: [Item] {
    SnapshotLinkScope.resolved(items: items, families: families).items
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        BackupHeaderCard(
          icon: "checkmark.seal",
          title: "承認待ち",
          subtitle: "Museから届いた操作を確認して、許可するか却下するかを選びます。"
        )
        .riseIn()

        if isLoading {
          loadingCard
        } else if queue.isEmpty {
          emptyCard
            .riseIn(index: 1)
        } else {
          ForEach(Array(queue.enumerated()), id: \.element.commandId) { index, entry in
            approvalCard(entry)
              .riseIn(index: min(index + 1, 8))
          }
        }

        if !isLoading && !queue.isEmpty {
          Text(L10n.string("許可すると、その時点のデータで検証と競合判定をやり直してから適用します。"))
            .font(.caption)
            .foregroundStyle(AppTheme.inkSecondary)
            .padding(.top, 4)
        }
      }
      .padding(.horizontal, 20)
      .padding(.top, 12)
      .padding(.bottom, 32)
    }
    .appScreenBackground()
    .tint(AppTheme.accent)
    .navigationTitle(L10n.string("承認待ち"))
    .navigationBarTitleDisplayMode(.inline)
    .localizedRefresh()
    .task {
      await reloadWithMaintenance()
    }
    .refreshable {
      await reloadWithMaintenance()
    }
    .confirmationDialog(
      L10n.string("この削除を許可しますか？"),
      isPresented: Binding(
        get: { confirmationEntry != nil },
        set: { isPresented in
          if !isPresented {
            confirmationEntry = nil
          }
        }
      ),
      presenting: confirmationEntry
    ) { entry in
      Button(L10n.string("許可する"), role: .destructive) {
        Task { await approve(entry) }
      }
      Button(L10n.string("キャンセル"), role: .cancel) {
        confirmationEntry = nil
      }
    } message: { entry in
      Text(description(for: entry))
    }
  }

  // MARK: - 一覧

  private var loadingCard: some View {
    HStack(spacing: 10) {
      ProgressView()
      Text(L10n.string("承認待ちを読み込んでいます…"))
        .font(.subheadline)
        .foregroundStyle(AppTheme.inkSecondary)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 28)
    .cardSurface(radius: 20)
  }

  private var emptyCard: some View {
    VStack(spacing: 10) {
      Image(systemName: "checkmark.seal")
        .font(.system(size: 28, weight: .semibold))
        .foregroundStyle(AppTheme.inkSecondary)
      Text(L10n.string("承認待ちはありません"))
        .font(.headline)
        .foregroundStyle(AppTheme.ink)
      Text(L10n.string("承認制の操作が届くと、ここに表示されます。"))
        .font(.caption)
        .foregroundStyle(AppTheme.inkSecondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 28)
    .padding(.horizontal, 16)
    .cardSurface(radius: 20)
  }

  private func approvalCard(_ entry: CommandInboxPendingApproval) -> some View {
    let waiting = isWaiting(entry)

    return VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(Self.dateText(entry.issuedAt))
          .font(.caption)
          .foregroundStyle(AppTheme.inkSecondary)
        Spacer(minLength: 8)
        Text(waiting ? L10n.string("先のコマンド待ち") : L10n.string("承認制"))
          .font(.caption.weight(.semibold))
          .foregroundStyle(waiting ? AppTheme.inkSecondary : AppTheme.accentInk)
          .padding(.horizontal, 10)
          .padding(.vertical, 4)
          .background(
            (waiting ? AppTheme.inkSecondary : AppTheme.accentInk).opacity(0.14),
            in: Capsule()
          )
      }

      Text(description(for: entry))
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(AppTheme.ink)
        .fixedSize(horizontal: false, vertical: true)

      HStack(spacing: 6) {
        Text(Self.typeText(entry.type))
          .font(.caption.weight(.semibold))
          .foregroundStyle(AppTheme.inkSecondary)
        Text("·")
          .foregroundStyle(AppTheme.inkSecondary)
        Text(entry.origin)
          .font(.caption)
          .foregroundStyle(AppTheme.inkSecondary)
          .lineLimit(1)
      }

      if waiting {
        Text(L10n.string("先のコマンドが片付くまで、このコマンドは許可・却下できません。"))
          .font(.caption)
          .foregroundStyle(AppTheme.inkSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      HStack(spacing: 10) {
        Button(L10n.string("却下")) {
          Task { await deny(entry) }
        }
        .buttonStyle(SecondaryActionButtonStyle())
        .disabled(waiting || isWorking)

        Button(L10n.string("許可")) {
          requestApproval(entry)
        }
        .buttonStyle(PrimaryActionButtonStyle())
        .disabled(waiting || isWorking)
      }
      .padding(.top, 2)
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardSurface(radius: 18)
    .opacity(isWorking ? 0.7 : 1)
  }

  // MARK: - 操作

  private func requestApproval(_ entry: CommandInboxPendingApproval) {
    // 削除系は取り返しがつかないため、許可の前に確認する（W-05 の削除と共通）。
    if entry.type == CommandInboxCommandType.itemDelete.rawValue
      || entry.type == CommandInboxCommandType.bagDelete.rawValue
    {
      confirmationEntry = entry
    } else {
      Task { await approve(entry) }
    }
  }

  private func approve(_ entry: CommandInboxPendingApproval) async {
    guard !isWorking else { return }
    isWorking = true
    confirmationEntry = nil
    defer { isWorking = false }

    let outcome = await CommandInboxService.shared.approve(commandId: entry.commandId)
    let run = await CommandInboxService.shared.processIfNeeded()
    if outcome.appliedCount + run.appliedCount > 0 {
      await uploadSnapshotIfNeeded()
    }
    await reload()
  }

  private func deny(_ entry: CommandInboxPendingApproval) async {
    guard !isWorking else { return }
    isWorking = true
    defer { isWorking = false }

    let outcome = await CommandInboxService.shared.deny(commandId: entry.commandId)
    let run = await CommandInboxService.shared.processIfNeeded()
    // 却下で待機が解けた後続が適用されることがあるため、件数を見て送る。
    if outcome.appliedCount + run.appliedCount > 0 {
      await uploadSnapshotIfNeeded()
    }
    await reload()
  }

  /// 最後に適用した内容をスナップショットとして送る（仕様 1 章）。
  private func uploadSnapshotIfNeeded() async {
    let storedItems = (try? modelContext.fetch(FetchDescriptor<Item>())) ?? items
    let storedFamilies = (try? modelContext.fetch(FetchDescriptor<Family>())) ?? families
    let scoped = SnapshotLinkScope.resolved(items: storedItems, families: storedFamilies)
    _ = await SnapshotAutoUploader.uploadAfterCommandApplied(
      items: scoped.items,
      familyName: scoped.family?.name
    )
  }

  // MARK: - 読み込み

  /// 承認画面を開いたときに失効を反映し、結果を書き戻してから一覧を読む。
  private func reloadWithMaintenance() async {
    isLoading = true
    let refresh = await CommandInboxService.shared.refreshApprovalQueue(
      modelContext: modelContext)
    queue = refresh.queue
    onPendingCountChanged(queue.count)
    isLoading = false
    // 失効で待機が解けたコマンドが適用されていることがある。
    if refresh.appliedCount > 0 {
      await uploadSnapshotIfNeeded()
    }
  }

  /// 操作後の一覧を読み直す。失効判定は次の取り込み・再表示に任せる。
  private func reload() async {
    queue = CommandInboxService.shared.pendingApprovals()
    onPendingCountChanged(queue.count)
  }

  private func isWaiting(_ entry: CommandInboxPendingApproval) -> Bool {
    CommandInboxTargetKey.isWaitingForEarlier(entry, in: queue)
  }

  // MARK: - 表示用の変換

  private func description(for entry: CommandInboxPendingApproval) -> String {
    guard let envelope = entry.envelope else {
      return L10n.string("コマンドの内容を読み取れませんでした")
    }
    return CommandDescriber.describe(envelope, items: scopedItems)
  }

  private static func dateText(_ value: String) -> String {
    guard let date = CommandInboxDate.parse(value) else { return value }
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter.string(from: date)
  }

  private static func typeText(_ type: String) -> String {
    guard let commandType = CommandInboxCommandType(rawValue: type) else { return type }
    switch commandType {
    case .itemAdd:
      return L10n.string("アイテム追加")
    case .itemUpdate:
      return L10n.string("アイテム編集")
    case .itemDelete:
      return L10n.string("アイテム削除")
    case .bagAdd:
      return L10n.string("バッグ追加")
    case .bagRename:
      return L10n.string("バッグ名の変更")
    case .bagDelete:
      return L10n.string("バッグ削除")
    }
  }
}

#Preview("CommandInboxApprovalView") {
  NavigationStack {
    CommandInboxApprovalView()
  }
  .modelContainer(for: [Family.self, Item.self, Bag.self], inMemory: true)
}
