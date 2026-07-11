# 共有リンク作成失敗（CKError 11 / Record not found）の修正計画

## Context

家族設定画面で「共有リンクを作成」すると1分以上待たされた末に
「共有リンクの準備に失敗しました: 共有リンクの再準備に失敗しました。CKError(11): Error fetching record <cloudkit.zoneshare> ... Record not found」で失敗する。

**根本原因**（調査済み・確定）: コミット `3b4c9c7` (Improve initial CloudKit share verification) のリグレッション。
`DefaultCloudKitFamilySharingBackend.fetchRecords(with:)`（`Stockpile/Services/FamilySharingService.swift:2894`）が、`CKFetchRecordsOperation` の per-record エラーを生の `CKError(.unknownItem)` のまま rethrow するようになった（2915-2916行）。変更前は件数不一致 → `CloudKitSharingError.recordNotFound` にマップされていた。

その結果:
- `fetchExistingShare`（`FamilySharingService.swift:1284`）は `CloudKitSharingError.recordNotFound` だけを「共有未作成 = nil」として catch するため、生の `CKError.unknownItem` がすり抜けて `prepareShare` 全体を失敗させる
- **初回作成では `cloudkit.zoneshare` が存在しないのが正常**なのに、`CKShare` 新規作成（306行）に到達できない
- `shouldRetrySharePreparation`（1369行）が `unknownItem` を「リトライ可能」と判定 → 成功見込みのないリトライ4回（毎回フルゾーンフェッチ×2 + アップロード試行 + sleep 合計約9秒）→ 1分超の待ちの末にエラー

テストが検出できなかった理由: `StockpileTests/CloudKitFamilySharingServiceTests.swift` のモックはすべて `CloudKitSharingError.recordNotFound` を投げる想定で、実 CloudKit が返す生の `CKError(.unknownItem)` を通すケースがない。

## 修正内容

対象ファイル: `Stockpile/Services/FamilySharingService.swift`、`StockpileTests/CloudKitFamilySharingServiceTests.swift`

### 1. バックエンドのエラーマッピング修正（本命）

既存の compatibility enum パターン（`CloudKitRecordDeletionCompatibility` FamilySharingService.swift:3136 等）に倣い、テスト可能なヘルパーを追加する:

```swift
enum CloudKitMissingRecordCompatibility {
    /// per-record エラー（または partialFailure の中身）がすべて unknownItem なら
    /// 「レコード未存在」として扱う
    static func isRecordNotFound(_ error: Error) -> Bool
    static func areAllRecordsNotFound(_ errors: [Error]) -> Bool
}
```

`DefaultCloudKitFamilySharingBackend.fetchRecords(with:)` の `fetchRecordsResultBlock` で適用:
- `.success` かつ `fetchErrors` あり: 全エラーが unknownItem → `CloudKitSharingError.recordNotFound` を throw。そうでなければ最初の非 unknownItem エラーを throw（現行の診断性を維持）
- `.failure(error)`: `partialFailure` の中身が全て unknownItem の場合も `recordNotFound` にマップ

影響範囲の確認済み: `backend.fetchRecords(with:)` の呼び出し元は
`verifyCloudKitUpload`（1573行）と `fetchRecord(with:)`（2888行 → `fetchExistingShare`）のみ。
`shouldRetryCloudKitUploadVerification`（2228行）は `recordNotFound` もリトライ対象に含むため、`verifyCloudKitUpload` の挙動は変わらない。

### 2. fetchExistingShare の防御的 catch（多層防御）

`fetchExistingShare`（1284行）で `CloudKitSharingError.recordNotFound` に加え、
`CloudKitMissingRecordCompatibility.isRecordNotFound(error)` が true の生 CKError も「共有なし = nil」として扱う。
※ `zoneNotFound` は含めない（ゾーンなしで `CKShare` を save しても失敗するため、従来どおり上位のリトライに任せる）。

### 3. ensureFamilyRecordExists の軽量化（遅さの直接改善）

`ensureFamilyRecordExists`（1534行）は Family レコード1件の存在確認のために `fetchRemoteZoneState`（全4レコードタイプ・全件フェッチ）を実行しており、直前の `syncFamilyDataToCloudKit` と合わせて1試行で全件フェッチが2回走る。

修正: `fetchRecord(with: familyRecordID(...), scope:)` による単一レコードフェッチに置き換える。
`recordNotFound`（修正1により生 unknownItem もここにマップされる）は「リモートに Family レコードなし = アップロード必要」として `remoteRecord: nil` で `shouldUploadRecord` を評価する。

これで初回の共有リンク作成は「ゾーン同期1回 + share 保存 + アップロード検証」だけになり、95件超の全件フェッチが1回減る。

### 4. テスト追加・更新

`StockpileTests/CloudKitFamilySharingServiceTests.swift`（モックの handler: `fetchRecordHandler` / `fetchRecordsByIDHandler`、1814-1816行）:

- **新規（リグレッション再現）**: `fetchRecordHandler` が生の `CKError(.unknownItem)` を投げるケースで `prepareShare` が新規 `CKShare` の save に進み成功すること（現状は失敗する = red → green を確認）
- **新規**: `CloudKitMissingRecordCompatibility` の単体テスト（unknownItem 単体 / partialFailure 内包 / 非該当エラーが false）
- **更新**: `testPrepareShareDoesNotOverwriteNewerRemoteFamilyRecordDuringEnsureStep`（756行）は ensure ステップが `fetchRecordsHandler`（ゾーン全件）を使う前提の可能性があるため、単一レコードフェッチ前提に合わせて修正
- 修正3で ensure ステップの挙動に依存する他のテスト（`testPrepareShareSeedsPrivateZoneAndMarksBaseline` 等）が落ちたら同様に追随

## 検証

1. ユニットテスト:
   ```
   xcodebuild test -project Stockpile.xcodeproj -scheme Stockpile \
     -destination 'platform=iOS Simulator,name=iPhone 16' \
     -only-testing:StockpileTests/CloudKitFamilySharingServiceTests
   ```
   （まず修正前に新規リグレッションテストが red になることを確認してから修正を入れる）
2. 全テスト実行（同コマンドの `-only-testing` なし）でリグレッションがないこと
3. 実機/シミュレーター確認（可能なら）: 家族設定 → 共有リンクを作成が、リトライ地獄なしで完了すること。`scripts/run_two_simulators_family_share.sh` が使えれば2台構成で招待フローまで確認

## スコープ外（今回はやらない）

- `prepareShare` のリトライ間隔・回数チューニング（根本原因解消後は正当な一時エラーのみリトライされるため据え置き）
- `syncFamilyDataToCloudKit` 自体のフェッチ最適化（差分トークン化など）は別課題
