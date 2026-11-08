import Foundation

// MARK: - 書き込み権限のモデル（docs/command-inbox-v1.md 5 章）

/// 書き込みを許可する能力。type ごとにこのどれかへ割り当てる。
enum CommandWriteCapability: String, CaseIterable, Codable, Sendable {
  case itemAdd
  case itemUpdate
  case itemDelete
  case bagOperation

  /// 未設定時の既定。削除だけ承認制（D1）、それ以外は不可。
  var defaultPermission: CommandWritePermission {
    switch self {
    case .itemDelete:
      return .approvalRequired
    case .itemAdd, .itemUpdate, .bagOperation:
      return .denied
    }
  }

  var displayName: String {
    switch self {
    case .itemAdd:
      return L10n.string("アイテム追加")
    case .itemUpdate:
      return L10n.string("アイテム編集")
    case .itemDelete:
      return L10n.string("アイテム削除")
    case .bagOperation:
      return L10n.string("バッグ操作")
    }
  }
}

/// 能力ごとの権限（不可 / 許可 / 承認制）。
enum CommandWritePermission: String, CaseIterable, Codable, Sendable {
  case denied
  case allowed
  case approvalRequired

  var displayName: String {
    switch self {
    case .denied:
      return L10n.string("不可")
    case .allowed:
      return L10n.string("許可")
    case .approvalRequired:
      return L10n.string("承認制")
    }
  }
}

extension CommandInboxCommandType {
  /// type → 能力の対応（仕様 4 章）。バッグ系の 3 つは同じ「バッグ操作」。
  var writeCapability: CommandWriteCapability {
    switch self {
    case .itemAdd:
      return .itemAdd
    case .itemUpdate:
      return .itemUpdate
    case .itemDelete:
      return .itemDelete
    case .bagAdd, .bagRename, .bagDelete:
      return .bagOperation
    }
  }
}

// MARK: - 判定に渡す設定値

/// 権限判定に必要な設定をまとめた値。純粋関数へ引数で渡すために使う。
struct CommandWritePermissionPolicy: Equatable, Sendable {
  var writesEnabled: Bool
  var permissions: [CommandWriteCapability: CommandWritePermission]

  init(
    writesEnabled: Bool = false,
    permissions: [CommandWriteCapability: CommandWritePermission] = [:]
  ) {
    self.writesEnabled = writesEnabled
    self.permissions = permissions
  }

  /// 書き込み連携オフ・全能力が既定値の状態。
  static let `default` = CommandWritePermissionPolicy(
    writesEnabled: false,
    permissions: Dictionary(
      uniqueKeysWithValues: CommandWriteCapability.allCases.map { ($0, $0.defaultPermission) }
    )
  )

  func permission(for capability: CommandWriteCapability) -> CommandWritePermission {
    permissions[capability] ?? capability.defaultPermission
  }

  /// 既知の type に対応する権限。未知の type は nil。
  func permission(for type: String) -> CommandWritePermission? {
    guard let commandType = CommandInboxCommandType(rawValue: type) else { return nil }
    return permission(for: commandType.writeCapability)
  }
}

// MARK: - 設定の保存（UserDefaults。SnapshotLinkSettings と同じ流儀）

/// 書き込み連携スイッチと能力別の権限を UserDefaults に保存する。
/// テストでは専用の `UserDefaults(suiteName:)` を渡して本物の設定を汚さない。
enum CommandWritePermissionSettings {
  private static let writesEnabledKey = "commandWrite.enabled"
  private static let permissionKeyPrefix = "commandWrite.permission."

  /// 書き込み連携スイッチ。既定 OFF（仕様 5 章のキルスイッチを兼ねる）。
  static var writesEnabled: Bool {
    get { writesEnabled(defaults: .standard) }
    set { setWritesEnabled(newValue, defaults: .standard) }
  }

  static func writesEnabled(defaults: UserDefaults) -> Bool {
    defaults.bool(forKey: writesEnabledKey)
  }

  static func setWritesEnabled(_ enabled: Bool, defaults: UserDefaults) {
    defaults.set(enabled, forKey: writesEnabledKey)
  }

  static func permission(
    for capability: CommandWriteCapability,
    defaults: UserDefaults = .standard
  ) -> CommandWritePermission {
    guard
      let raw = defaults.string(forKey: permissionKey(for: capability)),
      let permission = CommandWritePermission(rawValue: raw)
    else {
      return capability.defaultPermission
    }
    return permission
  }

  static func setPermission(
    _ permission: CommandWritePermission,
    for capability: CommandWriteCapability,
    defaults: UserDefaults = .standard
  ) {
    defaults.set(permission.rawValue, forKey: permissionKey(for: capability))
  }

  /// 現在の設定を判定用の値として読み出す。
  static func policy(defaults: UserDefaults = .standard) -> CommandWritePermissionPolicy {
    CommandWritePermissionPolicy(
      writesEnabled: writesEnabled(defaults: defaults),
      permissions: Dictionary(
        uniqueKeysWithValues: CommandWriteCapability.allCases.map {
          ($0, permission(for: $0, defaults: defaults))
        }
      )
    )
  }

  private static func permissionKey(for capability: CommandWriteCapability) -> String {
    permissionKeyPrefix + capability.rawValue
  }
}

// MARK: - 権限判定（純粋関数）

enum CommandWritePermissionDecision: Equatable, Sendable {
  /// 適用処理へ進む
  case allowed
  /// 承認キューへ入れる（データには触れない）
  case approvalRequired
  /// 適用しない。reason を結果ファイルに書く
  case rejected(CommandInboxReason)
}

enum CommandWritePermissionJudge {
  /// 書き込み連携スイッチ → 能力別の権限の順に見て、適用可否を決める。
  /// 設定値は引数で受け取り、UserDefaults や時刻には触れない。
  static func decide(
    _ command: CommandInboxEnvelope,
    policy: CommandWritePermissionPolicy
  ) -> CommandWritePermissionDecision {
    guard policy.writesEnabled else {
      return .rejected(.writesDisabled)
    }
    // 未知の type は受信箱側で先に unsupported になる。ここへ来たら適用処理に委ねる。
    guard let commandType = command.commandType else {
      return .allowed
    }
    switch policy.permission(for: commandType.writeCapability) {
    case .denied:
      return .rejected(.permissionDenied)
    case .approvalRequired:
      return .approvalRequired
    case .allowed:
      return .allowed
    }
  }
}
