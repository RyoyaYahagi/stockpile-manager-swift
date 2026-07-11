# CloudKit / CKShare 共有まわり 修正レポート

更新日: 2026-06-12

---

## TLDR

`FamilySharingService` と共有 UI を確認し、共有リンク作成・参加・再同期で実害が出やすい問題を修正した。

1. **one-time URL を永続化しない**  
   iOS 26 の one-time URL は使い捨てとして扱い、`family.cloudKitShareURL` には保存しない。
2. **アクセス不能な素の `share.url` を配らない**  
   `publicPermission = .none` の共有で one-time URL が取れない場合は、URL 共有ではなく `UICloudSharingController` に戻す。
3. **Production schema 未展開時の missing record type を全主要レコード型で空扱いする**  
   `Family` / `Bag` / `Item` / `DeletionMarker` の全てに `fetchRecordsAllowingMissingRecordType` を適用した。
4. **新しいリモート `Family` レコードを上書きしない**  
   `ensureFamilyRecordExists` はリモート timestamp を見て、ローカルが新しい場合だけ保存する。
5. **一時エラーを「既存共有なし」と誤判定しない**  
   `fetchExistingShare` は retryable エラーを握りつぶさず throw する。
6. **共有から離脱すると shared zone を削除する**  
   `leaveFamily` は shared database の zone を削除してからローカル家族を削除する。

---

## 修正内容

### 1. one-time URL の永続化を停止

**対象:** `FamilySharingService.prepareOneTimeInvitationURL`

以前は `CKShare.Participant.oneTimeURLParticipant()` から生成した URL を `family.cloudKitShareURL` に保存していた。これにより、2人目以降や再共有時に使用済み one-time URL を再送する可能性があった。

現在は、one-time URL を呼び出し元へ返すだけにし、永続化する URL は `savedShare.url` / `refetchedShare.url` のみとした。`share.url` が無い場合は `cloudKitShareURL` も更新しない。

### 2. 招待制共有で `share.url` をフォールバック配布しない

**対象:** `FamilySharingService.prepareInvitationURL`, `FamilySettingsView.presentPreparedShare`

このアプリは `share.publicPermission = .none` の招待制共有を使っている。`publicPermission = .none` の `share.url` は URL を知っているだけでは参加できないため、one-time URL 取得失敗時のフォールバックとして配ると「リンクは届くが参加できない」状態になり得る。

現在は、`publicPermission != .none` のときだけ `share.url` を URL 共有に使う。`FamilySettingsView` 側も `invitationURL` が無い場合は `activeShare.url` / `family.cloudKitShareURL` を配らず、共有管理シートへフォールバックする。

### 3. Production schema 未展開時の missing record type 対応を拡大

**対象:** `FamilySharingService.fetchRemoteZoneState`

以前は `DeletionMarker` だけが `Did not find record type` を空配列として扱っていた。TestFlight / App Store の Production CloudKit では Just-In-Time schema 作成が効かないため、`Family` / `Bag` / `Item` のクエリで同じエラーが出ると共有準備が失敗する。

現在は `Family` / `Bag` / `Item` / `DeletionMarker` 全てを `fetchRecordsAllowingMissingRecordType` 経由に統一した。

注意: これは初回共有時の防衛策であり、リリース前の CloudKit Console `Deploy Schema Changes` は引き続き必要。

### 4. `ensureFamilyRecordExists` の上書き抑制

**対象:** `FamilySharingService.ensureFamilyRecordExists`

以前は `makeFamilyRecord` を無条件に private database へ保存していたため、より新しいリモートの家族名を古いローカル値で巻き戻す可能性があった。

現在は `fetchRemoteZoneState` でリモート `Family` を取得し、`shouldUploadRecord` の timestamp 判定を通った場合だけ保存する。保存先 scope も現在の family scope に合わせた。

### 5. `fetchExistingShare` の一時エラー誤判定を修正

**対象:** `FamilySharingService.fetchExistingShare`

以前は network / service unavailable / request rate limited などの retryable エラーで `nil` を返していた。これは「既存 share が無い」と同じ意味になり、重複 share 作成や後続の競合につながる。

現在は `recordNotFound` のときだけ `nil` を返し、それ以外は throw する。上位の retry / recovery ロジックに任せる。

### 6. shared family 離脱時の server-side cleanup

**対象:** `FamilySharingService.leaveFamily`, `CloudKitFamilySharingBackend`

以前の `leaveFamily` はローカル削除だけだった。これだと CloudKit 上では共有参加状態が残り、再インストールや再同期で「離脱したはずの家族」が戻る可能性があった。

現在は `readableZoneID` で shared database 上の実 zone ID を解決し、`CKModifyRecordZonesOperation(recordZoneIDsToDelete:)` で shared zone を削除してからローカルデータを削除する。

---

## 追加した回帰テスト

- `testPrepareShareIgnoresMissingPrimaryRecordTypesDuringInitialProductionSchemaWarmup`
- `testPrepareShareDoesNotOverwriteNewerRemoteFamilyRecordDuringEnsureStep`
- `testLeaveFamilyDeletesSharedZoneBeforeRemovingLocalFamily`

既存の missing `DeletionMarker` テストと合わせて、Production schema 未展開、防衛的上書き、共有離脱の回帰を押さえている。

---

## 残リスク / 今後の改善

### one-time pending participant の掃除

未使用 one-time participant の掃除はまだ専用実装していない。CloudKit API 上、one-time participant と通常 pending participant の安全な識別条件を実機で確認してから入れるのがよい。

### `shouldTreatMissingRecordTypeAsEmptyResult` の文字列依存

CloudKit の missing record type 判定は引き続きエラーメッセージ文字列に依存している。`CKError` の構造化情報だけで確実に判定できる形が取れるなら置き換えたい。

### `prepareShare` の重い同期フロー

共有リンク準備では full zone query / sync / verification が複数回走る。正しさ優先で維持したが、rate limit や体感速度が問題になる場合は、差分 fetch または verification 対象の絞り込みを検討する。

### 実機の共有参加テスト

`build-for-testing` は成功。Simulator での XCTest 実行は起動後にランナーが戻らず完走確認できなかった。CloudKit 共有の本命は Apple Account / CloudKit Production を含む実機検証なので、TestFlight または実機 Debug で以下を確認する。

1. iOS 26 端末で共有リンクを作成し、受信側が一度だけ参加できること
2. 同じリンクを再利用して参加できないこと
3. 2人目へ再共有したとき、新しい one-time URL が発行されること
4. one-time URL 取得失敗時に URL 共有ではなく共有管理シートへ戻ること
5. 参加者が `leaveFamily` したあと、再インストールしても共有家族が復活しないこと

---

## 検証

- `xcodebuild build-for-testing -project Stockpile.xcodeproj -scheme Stockpile -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/stockpile-derived-data`  
  結果: 成功
- `xcodebuild test -project Stockpile.xcodeproj -scheme Stockpile -destination 'platform=iOS Simulator,id=AB556D29-AF1D-4D66-A56B-D6A770C552E3' -derivedDataPath /tmp/stockpile-derived-data -only-testing:StockpileTests/CloudKitFamilySharingServiceTests`  
  結果: テスト runner が戻らず未完了。ビルドとテスト bundle 生成までは成功。
