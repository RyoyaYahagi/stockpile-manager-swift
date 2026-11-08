import Foundation
import GoogleSignIn
import UIKit

// MARK: - Google Drive 連携のサインイン状態管理（G-02）

/// Muse連携の送信先としての Google Drive 接続を管理する。
/// このクラスが扱うのは「接続（サインイン状態）」だけで、Drive への実送信は
/// G-03（書き込み）/ G-04（送信統合）が担う。
/// 要求スコープは drive.file のみ（このアプリが作ったファイルだけにアクセス）。
/// 連携解除はアプリ側の signOut のみで、Google 側の権限剥奪（disconnect）はしない
/// （勝手に切ると利用者の Google アカウント側の状態まで変えてしまうため）。
@MainActor
@Observable
final class GoogleDriveLinkManager {
  static let shared = GoogleDriveLinkManager()

  /// この連携で要求する唯一のスコープ
  static let driveScope = "https://www.googleapis.com/auth/drive.file"

  private(set) var currentUser: GIDGoogleUser?

  /// 起動直後の復元が終わるまで true（設定画面でチラつかせないため）
  private(set) var isRestoring = true

  var isSignedIn: Bool { currentUser != nil }

  /// 連携中アカウントのメールアドレス（設定画面の表示用）
  var accountEmail: String? { currentUser?.profile?.email }

  /// drive.file が許可済みか。サインイン時に要求するが、Google 側で
  /// 後から剥奪されていた場合に再連携を促すために都度確認する。
  var hasDriveScope: Bool {
    currentUser?.grantedScopes?.contains(Self.driveScope) == true
  }

  private init() {
    restorePreviousSignIn()
  }

  /// 前回のサインインを復元する（アプリ再起動後も連携状態を保つ）
  func restorePreviousSignIn() {
    isRestoring = true
    GIDSignIn.sharedInstance.restorePreviousSignIn { [weak self] user, _ in
      // SDK はこのコールバックをメインキューで呼ぶことをヘッダで保証している。
      // GIDGoogleUser は Sendable ではないため Swift 6 の領域分離では通常の方法で
      // MainActor 側へ渡せないが、実際にはメインキュー上での受け渡しになり
      // 競合は起きないため、nonisolated(unsafe) で明示して引き渡す。
      nonisolated(unsafe) let restoredUser = user
      Task { @MainActor [weak self] in
        self?.currentUser = restoredUser
        self?.isRestoring = false
      }
    }
  }

  /// Google サインインし、drive.file を追加スコープとして要求する。
  /// ユーザーが途中でキャンセルした場合は throw せず false を返す
  /// （呼び出し側はエラー表示をしなくてよい）。
  @discardableResult
  func signIn() async throws -> Bool {
    guard let presenter = Self.topViewController() else {
      throw GoogleDriveLinkError.noPresenter
    }
    do {
      let result = try await GIDSignIn.sharedInstance.signIn(
        withPresenting: presenter,
        hint: nil,
        additionalScopes: [Self.driveScope]
      )
      currentUser = result.user
      // 受信箱（commands.json / command-results.json）をサインイン完了時に作る（W-01）。
      // 失敗してもサインインは成功として扱い、取り込み時に作り直す。
      await CommandInboxFileBootstrap.ensureFiles(for: result.user)
      return true
    } catch {
      if (error as NSError).code == GIDSignInError.canceled.rawValue {
        return false
      }
      throw error
    }
  }

  /// 現在のユーザーで Drive へスナップショットを送信する（G-04 の送信統合用）。
  /// GIDGoogleUser は Sendable ではないため、呼び出し側に渡さずこの中で書き込みまで行う。
  func uploadSnapshot(data: Data) async throws {
    guard let currentUser else {
      throw GoogleDriveUploadError.notSignedIn
    }
    try await GoogleDriveSnapshotWriter.upload(data: data, user: currentUser)
  }

  /// 連携解除（アプリ側のサインアウトのみ）。
  /// 承認待ちのコマンドは送信先を失うため、キューと未送信の結果を破棄する（W-02）。
  func signOut() {
    GIDSignIn.sharedInstance.signOut()
    currentUser = nil
    CommandInboxService.shared.discardForLinkRemoval()
  }

  /// サインイン UI の提示元（最前面のビューコントローラ）
  private static func topViewController() -> UIViewController? {
    let window = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
      .first { $0.isKeyWindow }
    var top = window?.rootViewController
    while let presented = top?.presentedViewController {
      top = presented
    }
    return top
  }
}

enum GoogleDriveLinkError: Error, LocalizedError {
  case noPresenter

  var errorDescription: String? {
    switch self {
    case .noPresenter:
      return L10n.string("サインイン画面を表示できませんでした")
    }
  }
}
