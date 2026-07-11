# 共有リンク作成失敗（CKError 11 / Record not found）インシデントレポート

更新日: 2026-07-11
対象: `Stockpile/Services/FamilySharingService.swift`、`StockpileTests/CloudKitFamilySharingServiceTests.swift`

## 概要

家族設定画面で初めて「共有リンクを作成」した際、1分以上待ったあと、次のエラーで失敗する問題が発生した。

```text
共有リンクの準備に失敗しました:
共有リンクの再準備に失敗しました。
CKError(11): Error fetching record <cloudkit.zoneshare> ... Record not found
```

原因は、コミット `3b4c9c7`（Improve initial CloudKit share verification）で入った `CKFetchRecordsOperation` のエラー処理のリグレッションだった。初回共有時に `cloudkit.zoneshare` が存在しない正常な状態を、共有作成前の致命的エラーとして扱っていた。

修正はコミット `08686fa`（Fix initial CloudKit share record lookup）で実施し、ビルド `202607111405` として TestFlight へアップロード済み。

## 根本原因

`DefaultCloudKitFamilySharingBackend.fetchRecords(with:)` は、CloudKit がレコード単位で返す `CKError(.unknownItem)` を生のまま上位へ投げていた。

初回共有では zone-wide share レコード `cloudkit.zoneshare` がまだ存在しないため、CloudKit が `unknownItem` を返すこと自体は正常である。本来はこれを `CloudKitSharingError.recordNotFound` に正規化し、「既存共有なし」と判断して新しい `CKShare` を作成する必要があった。

しかし実際には、次の経路で処理が失敗した。

1. `fetchExistingShare` が `cloudkit.zoneshare` を取得する。
2. CloudKit が per-record error として生の `CKError(.unknownItem)` を返す。
3. バックエンドがエラーを正規化せず、そのまま rethrow する。
4. `fetchExistingShare` は `CloudKitSharingError.recordNotFound` だけを「共有なし」として扱っていたため、生の `CKError` を捕捉できない。
5. 新規 `CKShare` の保存処理へ到達する前に `prepareShare` が失敗する。

つまり、共有レコードが存在しないことが問題だったのではなく、**初回には存在しないのが正常な共有レコードを、エラー境界で正しく分類できていなかったこと**が根本原因である。

## 失敗まで1分以上かかった理由

`shouldRetrySharePreparation` は `CKError(.unknownItem)` を一時的に回復可能なエラーとして扱う。そのため、成功可能性がない状態のまま共有準備全体を最大4回繰り返していた。

各試行では次の重い処理が含まれていた。

- CloudKit zone の同期
- Family / Bag / Item / DeletionMarker の全件取得
- Family レコードの存在確認
- アップロードと読み戻し検証
- リトライ間の待機

正常な「共有未作成」を致命的かつ再試行可能なエラーに誤分類したことで、最終エラーが表示されるまでの待ち時間も大幅に増えていた。

## テストで検出できなかった理由

既存のモックは、共有レコードが存在しない場合に `CloudKitSharingError.recordNotFound` を直接投げていた。実際の `CKFetchRecordsOperation` が返す生の `CKError(.unknownItem)` を通すケースがなかったため、サービス層と実CloudKitのエラー表現の差を検出できなかった。

## 修正内容

### 1. missing-record エラーの正規化

`CloudKitMissingRecordCompatibility` を追加し、次をレコード未存在として統一判定するようにした。

- `CloudKitSharingError.recordNotFound`
- `CKError(.unknownItem)`
- 全内包エラーが record-not-found の `CKError(.partialFailure)`
- per-record error が全て record-not-found の配列

`fetchRecords(with:)` は全エラーが missing-record の場合、`CloudKitSharingError.recordNotFound` に変換する。ネットワーク障害などが混在する場合は最初の非 missing-record エラーを維持し、診断情報を失わない。

### 2. `fetchExistingShare` の多層防御

正規化前の生の `CKError(.unknownItem)` が届いた場合でも、「既存共有なし」として `nil` を返す防御的 catch を追加した。

`CKError(.zoneNotFound)` はこの判定に含めていない。zone 自体がない場合は share を保存しても失敗するため、従来どおり上位の回復処理へ渡す。

### 3. Family レコード確認の軽量化

`ensureFamilyRecordExists` は、Family レコード1件を確認するために zone 全体を取得していた。これを対象 Family の単一レコード fetch に変更した。

レコード未存在の場合だけ `remoteRecord: nil` としてアップロード要否を評価するため、新しいリモートレコードを古いローカル値で上書きしない既存の timestamp 判定も維持している。

## 回帰テスト

次のテストを追加・更新した。

- 生の `CKError(.unknownItem)` を受けても、新しい `CKShare` の保存へ進んで成功すること
- `unknownItem` 単体を record-not-found と判定すること
- `partialFailure` 内が全て `unknownItem` の場合に record-not-found と判定すること
- `networkFailure` や `zoneNotFound`、混在エラーを record-not-found と誤判定しないこと
- 空のエラー配列を「全件未存在」と判定しないこと
- 単一レコード fetch へ変更後も、新しいリモート Family を上書きしないこと

## 検証結果

2026-07-11 に iPhone 17 Simulator（iOS 26.2）で検証した。

- `CloudKitFamilySharingServiceTests`: 全51件成功
- `Stockpile` scheme 全テスト: 成功
- Release archive: 成功
- CloudKit Production schema 検証: 成功
- 署名済みIPAの Production environment / container / `InProcessOneTimeLinks` entitlement 検証: 成功
- TestFlightアップロード: 成功（ビルド `202607111405`）

指定されていた iPhone 16 Simulator は実行環境に存在しなかったため、同等の利用可能ランタイムである iPhone 17 Simulatorを使用した。

## 影響と期待される改善

- 初回共有で `cloudkit.zoneshare` が存在しない正常状態から、新規 `CKShare` 作成へ進める。
- 回復不能な同一処理の4回リトライがなくなり、1分超の待機を解消する。
- Family レコード確認時の全件 fetch が1回減り、初回共有のCloudKitリクエスト数と待ち時間を削減する。
- missing-record 以外のエラーは従来どおり保持されるため、障害時の診断性を損なわない。

## 関連コミット

- `3b4c9c7` — リグレッション導入: Improve initial CloudKit share verification
- `08686fa` — 原因修正: Fix initial CloudKit share record lookup
- `22df834` — TestFlightビルド番号: Set TestFlight build number 202607111405

## 残る確認事項

ユニットテストとRelease/TestFlightアップロードは完了している。最終確認として、Apple Accountへサインインした実機2台で以下を確認する。

1. 所有者側で初回の共有リンクが長時間リトライせず作成できること
2. 参加者側で招待リンクを受け入れられること
3. Family / Bag / Item が参加者側へ同期されること
4. 同じ家族で再度リンクを作成した場合も正常に完了すること
