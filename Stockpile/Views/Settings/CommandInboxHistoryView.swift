import SwiftUI

/// 書き込みコマンドの適用履歴（W-02）。
/// 端末内の `CommandInboxState.history` を新しい順に表示する。
struct CommandInboxHistoryView: View {
  private let store = CommandInboxStore()
  @State private var history: [CommandInboxHistoryEntry] = []

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        if history.isEmpty {
          emptyCard
            .riseIn()
        } else {
          ForEach(Array(history.enumerated()), id: \.offset) { index, entry in
            historyCard(entry)
              .riseIn(index: min(index, 8))
          }
        }
      }
      .padding(.horizontal, 20)
      .padding(.top, 12)
      .padding(.bottom, 32)
    }
    .appScreenBackground()
    .tint(AppTheme.accent)
    .navigationTitle(L10n.string("適用履歴"))
    .navigationBarTitleDisplayMode(.inline)
    .localizedRefresh()
    .onAppear {
      history = store.load().history
    }
  }

  private var emptyCard: some View {
    VStack(spacing: 10) {
      Image(systemName: "clock.arrow.circlepath")
        .font(.system(size: 28, weight: .semibold))
        .foregroundStyle(AppTheme.inkSecondary)
      Text(L10n.string("適用履歴はまだありません"))
        .font(.headline)
        .foregroundStyle(AppTheme.ink)
      Text(L10n.string("Museからコマンドが届くと、適用した結果がここに表示されます。"))
        .font(.caption)
        .foregroundStyle(AppTheme.inkSecondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 28)
    .padding(.horizontal, 16)
    .cardSurface(radius: 20)
  }

  private func historyCard(_ entry: CommandInboxHistoryEntry) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(Self.dateText(entry.occurredAt))
          .font(.caption)
          .foregroundStyle(AppTheme.inkSecondary)
        Spacer(minLength: 8)
        Text(Self.resultText(entry))
          .font(.caption.weight(.semibold))
          .foregroundStyle(Self.color(for: entry.status))
          .padding(.horizontal, 10)
          .padding(.vertical, 4)
          .background(
            Self.color(for: entry.status).opacity(0.14),
            in: Capsule()
          )
      }

      HStack(spacing: 6) {
        Text(Self.typeText(entry.type))
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(AppTheme.ink)
        if let origin = entry.origin, !origin.isEmpty {
          Text("·")
            .foregroundStyle(AppTheme.inkSecondary)
          Text(origin)
            .font(.caption)
            .foregroundStyle(AppTheme.inkSecondary)
            .lineLimit(1)
        }
      }

      if let message = entry.message, !message.isEmpty {
        Text(message)
          .font(.caption)
          .foregroundStyle(AppTheme.inkSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardSurface(radius: 18)
  }

  // MARK: - 表示用の変換

  private static func dateText(_ value: String) -> String {
    guard let date = CommandInboxDate.parse(value) else { return value }
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter.string(from: date)
  }

  private static func typeText(_ type: String?) -> String {
    guard let type, let commandType = CommandInboxCommandType(rawValue: type) else {
      return type ?? L10n.string("不明な種類")
    }
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

  /// 「却下（書き込み連携オフ）」のように status と reason を日本語で並べる。
  private static func resultText(_ entry: CommandInboxHistoryEntry) -> String {
    let status = statusText(entry.status)
    guard let reason = entry.reason else { return status }
    return L10n.format("%@（%@）", status, reasonText(reason))
  }

  private static func statusText(_ status: CommandInboxStatus) -> String {
    switch status {
    case .applied:
      return L10n.string("適用済み")
    case .pendingApproval:
      return L10n.string("承認待ち")
    case .rejected:
      return L10n.string("却下")
    case .conflict:
      return L10n.string("競合")
    case .expired:
      return L10n.string("失効")
    case .invalid:
      return L10n.string("不正")
    case .unsupported:
      return L10n.string("未対応")
    case .error:
      return L10n.string("エラー")
    }
  }

  private static func reasonText(_ reason: CommandInboxReason) -> String {
    switch reason {
    case .approvalRequired:
      return L10n.string("承認待ち")
    case .waitingForEarlier:
      return L10n.string("先行の承認待ち")
    case .writesDisabled:
      return L10n.string("書き込み連携オフ")
    case .permissionDenied:
      return L10n.string("権限なし")
    case .deniedByUser:
      return L10n.string("利用者が却下")
    case .linkRemoved:
      return L10n.string("連携解除")
    case .notFound:
      return L10n.string("対象なし")
    case .bagNotFound:
      return L10n.string("バッグなし")
    case .bagAmbiguous:
      return L10n.string("バッグ名が重複")
    case .bagExists:
      return L10n.string("バッグ名が既存")
    case .bagNotEmpty:
      return L10n.string("バッグが空でない")
    case .staleBase:
      return L10n.string("競合")
    case .expired:
      return L10n.string("失効")
    case .invalidEnvelope:
      return L10n.string("形式が不正")
    case .invalidPayload:
      return L10n.string("内容が不正")
    case .tooManyCommands:
      return L10n.string("コマンドが多すぎる")
    case .unknownType:
      return L10n.string("未対応の種類")
    case .malformedFile:
      return L10n.string("ファイルが不正")
    case .internalError:
      return L10n.string("内部エラー")
    }
  }

  private static func color(for status: CommandInboxStatus) -> Color {
    switch status {
    case .applied:
      return AppTheme.accent
    case .pendingApproval:
      return Color(light: 0xA85208, dark: 0xFFA149)
    case .conflict, .expired:
      return Color(light: 0x8A6D0B, dark: 0xE8C547)
    case .rejected, .invalid, .unsupported, .error:
      return Color(light: 0xB83A2B, dark: 0xFF7A66)
    }
  }
}

#Preview("CommandInboxHistoryView") {
  NavigationStack {
    CommandInboxHistoryView()
  }
}
