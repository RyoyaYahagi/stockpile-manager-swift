import Foundation

/// サイレントプッシュがコマンド受信箱の取り込みを促すものかを判定する。
///
/// 受信箱を起こすペイロードは次の形とする。
/// `{"aps":{"content-available":1},"stockpile":{"wake":"commandInbox"}}`
///
/// `stockpile.wake` が `commandInbox` のときだけ true を返す。
/// CloudKit のプッシュ（`ck` キーを持つ）は、たとえ `stockpile` を併せ持っていても
/// 受信箱のプッシュとして扱わない。
enum CommandInboxWakePush {
  static let stockpileKey = "stockpile"
  static let wakeKey = "wake"
  static let wakeValue = "commandInbox"
  static let cloudKitKey = "ck"

  static func matches(_ userInfo: [AnyHashable: Any]) -> Bool {
    guard !userInfo.keys.contains(where: { key in
      (key as? String) == cloudKitKey
    }) else {
      return false
    }
    guard let stockpile = userInfo[stockpileKey] as? [String: Any] else {
      return false
    }
    guard let wake = stockpile[wakeKey] as? String else {
      return false
    }
    return wake == wakeValue
  }
}
