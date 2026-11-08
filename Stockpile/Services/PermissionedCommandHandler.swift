import Foundation

// MARK: - 適用処理の差し替え口（W-03 / W-05）

/// 権限判定で「許可」になったコマンドを実際のデータへ適用する処理。
/// W-02 では実装を持たず、既定の `UnavailableCommandApplier` が
/// `unsupported` / `unknown_type` を返す（データには触れない）。
protocol CommandApplier: Sendable {
  /// - Parameters:
  ///   - command: 検証済みの封筒。
  ///   - now: 処理時刻（テストで注入できるように引数で受け取る）。
  func apply(_ command: CommandInboxEnvelope, now: Date) async -> CommandInboxHandlingResult
}

/// まだ適用処理がない版の既定実装。
/// 許可されたコマンドでもデータは変えず、「この版では適用できない」と返す。
struct UnavailableCommandApplier: CommandApplier {
  func apply(_ command: CommandInboxEnvelope, now: Date) async -> CommandInboxHandlingResult {
    .unsupported(
      reason: .unknownType,
      message: L10n.string("このアプリの版ではまだ適用できません")
    )
  }
}

// MARK: - 権限つきハンドラ

/// 書き込み連携スイッチと能力別の権限を見て、コマンドの扱いを決めるハンドラ。
///
/// - スイッチ OFF → `rejected` / `writes_disabled`
/// - 不可 → `rejected` / `permission_denied`
/// - 承認制 → `pending_approval` / `approval_required`
///   （封筒は `CommandInboxProcessor` が `CommandInboxState.pendingApprovals` へ入れる）
/// - 許可 → `CommandApplier` へ渡す
struct PermissionedCommandHandler: CommandHandler {
  private let policyProvider: @Sendable () -> CommandWritePermissionPolicy
  private let applier: any CommandApplier

  init(
    policyProvider: @escaping @Sendable () -> CommandWritePermissionPolicy = {
      CommandWritePermissionSettings.policy()
    },
    applier: any CommandApplier = UnavailableCommandApplier()
  ) {
    self.policyProvider = policyProvider
    self.applier = applier
  }

  func handle(_ command: CommandInboxEnvelope, now: Date) async -> CommandInboxHandlingResult {
    switch CommandWritePermissionJudge.decide(command, policy: policyProvider()) {
    case .rejected(let reason):
      return .rejected(reason: reason, message: message(for: reason))
    case .approvalRequired:
      return .pendingApproval(
        reason: .approvalRequired,
        message: L10n.string("承認が必要な操作のため、承認待ちにしました")
      )
    case .allowed:
      return await applier.apply(command, now: now)
    }
  }

  private func message(for reason: CommandInboxReason) -> String {
    switch reason {
    case .writesDisabled:
      return L10n.string("書き込み連携がオフのため、このコマンドは適用していません")
    case .permissionDenied:
      return L10n.string("この操作は許可されていないため、適用しませんでした")
    default:
      return L10n.string("このコマンドは適用しませんでした")
    }
  }
}
