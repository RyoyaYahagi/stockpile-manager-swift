# CloudKit / CKShare 家族共有障害 総括レポート

更新日: 2026-07-11  
対象アプリ: Stockpile (`com.stockpile-manager.app`)  
CloudKit Container: `iCloud.com.stockpile-manager.app`

## 1. 結論

家族共有ができなかった原因は1つではなく、Development（Simulator）とProduction（TestFlight）で異なる条件が重なっていた。

確認済みの主因は次の3つである。

1. **CloudKit Developmentのスキーマ変更がProductionへ配備されていなかった**
2. **初回CKShare作成時の「共有レコード未存在」を正常状態として扱えないコード不具合があった**
3. **共有所有者のiCloudストレージ容量不足により、private databaseへの保存が拒否されたケースがあった**

これに加え、shared databaseのzone owner解決、共有承認処理、レコード単位エラーの欠落、短すぎる保存直後検証など、実機Productionで失敗を増幅する複数の問題を修正した。

## 2. なぜSimulatorでは成功し、Productionでは失敗したのか

Simulatorで開発ビルドを実行した場合、通常はCloudKitのDevelopment環境を使用する。Developmentではアプリから新しいrecord typeやfieldを書き込むことで、スキーマが開発中に追加される。

一方、TestFlight／App StoreビルドはProduction環境を使用する。Developmentで追加されたスキーマはProductionへ自動反映されないため、CloudKit Consoleで明示的にDeployする必要がある。

この差により、同じコードでも次の状態になっていた。

| 環境 | 状態 | 結果 |
|---|---|---|
| Simulator / Development | 必要なrecord type・fieldが存在 | 保存・検索が成功しやすい |
| TestFlight / Production | 一部のrecord type・fieldが未配備 | 保存・検索が失敗 |

Productionから実際にexportしたスキーマでは、次が不足していた。

- `Family.updatedAt`
- `Bag.updatedAt`
- `Item.janCode`
- `Item.updatedAt`
- `DeletionMarker` record type

2026-07-11にCloudKit Consoleの **Deploy Schema Changes** を実行し、配備後に `cktool` で再exportした結果、`Family` / `Bag` / `Item` / `DeletionMarker` の必要fieldがすべて存在することを確認した。

## 3. 確認済みの根本原因

### 3.1 Productionスキーマ未配備

#### 症状

- Simulatorでは同期できるがTestFlightでは失敗する
- record typeやfieldが見つからない
- queryが失敗し、zone changesへのfallbackが発生する

#### 原因

Developmentで生成・更新されたCloudKitスキーマがProductionへDeployされていなかった。

#### 対応

- DevelopmentスキーマをCloudKit ConsoleからProductionへ配備
- リリース前にProductionスキーマをexportして検証する `scripts/verify_cloudkit_schema.rb` を追加
- Fastlaneの`build` / `beta` / `release`前にスキーマ検証を必須化
- CIにもProductionスキーマ検証用の環境変数を追加

### 3.2 初回共有レコード未存在の誤判定

#### 症状

初回共有リンク作成時に、次のエラーが発生した。

```text
CKError(11): Error fetching record <cloudkit.zoneshare> ... Record not found
```

#### 原因

初回共有ではzone-wide shareレコード `cloudkit.zoneshare` がまだ存在しないことが正常である。しかし、実CloudKitが返す `CKError(.unknownItem)` を、アプリ側が `CloudKitSharingError.recordNotFound` に正規化していなかった。

その結果、「既存共有なし」と判断して新しい`CKShare`を作成すべき場面で処理が終了した。また、`unknownItem`を再試行対象にしていたため、失敗表示まで1分以上かかるケースもあった。

#### 対応

- `unknownItem`と、missing-recordだけを含む`partialFailure`を`recordNotFound`へ正規化
- `fetchExistingShare`でもmissing-recordを「既存共有なし」として扱う多層防御を追加
- missing-recordとnetwork／zoneエラーが混在する場合は、非missingエラーを保持
- 実CloudKitと同じ生の`CKError(.unknownItem)`を使う回帰テストを追加

詳細は [共有リンク作成失敗インシデントレポート](share-link-record-not-found-incident-report.md) を参照。

### 3.3 iCloudストレージ容量不足

#### 症状

TestFlight実機でFamilyレコード保存時に次のエラーが発生した。

```text
Error saving record ... to server: Quota exceeded
```

#### 原因

CKShareの所有者データはCloudKit private databaseに保存され、所有者のiCloudストレージquotaを使用する。端末内のBag 8件／Item 95件というレコード数自体より、Apple Account全体のiCloud使用量が上限に達していたことが直接原因である。

この制限はアプリやCloudKitスキーマから回避できない。所有者が「設定 → Apple Account → iCloud → ストレージ」で空き容量を確保する必要がある。

#### 対応

- `CKError(.quotaExceeded)`を専用の`iCloudStorageQuotaExceeded`へ正規化
- `partialFailure`内のquota errorも検出
- 生の英語エラーではなく、iCloudストレージ確認手順を日本語で表示
- 容量不足時にも端末内データは削除されていないことを案内
- direct／partial failureの回帰テストを追加

## 4. Productionで失敗しやすくしていた関連問題

以下は今回のエラー画面そのものの直接原因とは限らないが、Production共有の信頼性を下げていたため修正した。

### 4.1 shared zone ownerの解決不足

保存済みのzone ownerを信用してshared databaseへアクセスすると、実際に受諾したzone ownerと一致せず読み書きに失敗する可能性があった。

対応として、`sharedCloudDatabase`のzone一覧からzone nameを照合し、実際のownerを持つzone IDを読み書きの両方で使用するようにした。同名zoneが複数ある場合は曖昧なまま処理せずエラーにする。

### 4.2 共有承認処理の状態・container不整合

- 既に承認済みのshareにも再度accept処理を行う可能性があった
- share metadataが示すcontainerではなくdefault containerを使う経路があった
- per-share errorがoperation全体の成功に隠れる可能性があった

対応として、`participantStatus`によりpendingのみacceptし、acceptedは既存共有を同期するようにした。`metadata.containerIdentifier`から正しい`CKContainer`を生成し、per-share errorを優先して返すようにした。

### 4.3 保存直後の検証時間不足

初回保存直後にFamily／Bag／Itemを読み戻す厳格検証が、CloudKitの反映遅延より短い時間で終了していた。そのため保存に成功していても`recordNotFound`になる可能性があった。

対応として検証リトライ時間を拡大し、レコード単位のfetch／save errorを保持するようにした。

### 4.4 `isAtomic = false`時の部分失敗の欠落

`CKModifyRecordsOperation`は`isAtomic = false`で実行しているため、一部レコードだけが失敗することがある。以前はoperation全体の結果だけで判断し、per-record errorが後段のgenericな`recordNotFound`に見える場合があった。

対応としてper-record save／delete resultを収集し、最初の具体的なCloudKit errorを上位へ返すようにした。

### 4.5 一時的な空レスポンスと共有解除の誤判定

一時的にFamily queryが空になっただけで、共有解除やremote data消失と判断するとローカルデータを失う危険があった。

対応として、空queryだけでは既存データを消さず、明示的な`zoneNotFound`／`userDeletedZone`を複数回確認してから共有メタデータを解除するようにした。共有解除後もBag／Itemのローカルデータは保持する。

### 4.6 iOS 26 one-time invitation URLの扱い

一時招待用participantをcanonical shareへ直接追加すると、通常のshare状態を不要に変更する可能性があった。

対応として`CKShare`のcopyに一時participantを追加し、未使用participantをcleanupするようにした。

## 5. Entitlement・署名の確認

Production共有ではコードだけでなく、配布IPAのentitlementも必要である。

最終IPAについて、次を機械検証した。

- CloudKit environment: `Production`
- iCloud container: `iCloud.com.stockpile-manager.app`
- Extended Share Access: `InProcessOneTimeLinks`
- APNs environment: `production`
- `get-task-allow`: `false`

検証は `scripts/verify_cloudkit_ipa.sh` で行い、FastlaneのTestFlight／App Store upload前に必須化した。

## 6. 実施した検証

### 自動検証

- `CloudKitFamilySharingServiceTests`
- CloudKit Production schema export／field検証
- iOS Simulatorでの対象回帰テスト
- 実機向けDebug build
- Release archive／IPA export
- 署名済みIPA entitlement検証

### TestFlight

- ビルド `1.0.1 (202607110915)` をアップロードし、App Store Connect処理完了を確認
- 初回share lookup修正後、ビルド `202607111405` をTestFlightへアップロード

TestFlight初回アップロード時にはApp Store Connectの有料アプリ契約未同意による403も発生したが、契約同意後に再送して成功した。これはCKShare障害の原因ではなく、配布経路のブロッカーである。

## 7. 関連コミット

主要な修正コミットは次のとおり。

- `12cdf27` — shared databaseから実zone IDを解決
- `e2bd843` — TestFlight signing／export修正
- `f9032b9` — CloudKit sharing edge case修正
- `81ce132` — 初回共有準備の重複処理削減
- `3b4c9c7` — 初回保存検証のリトライ・エラー保持改善
- `76a951a` — Production家族共有の包括的安定化
- `0d654e8` — Production schema検証条件の修正
- `d5738ae` — 検証済みIPAのTestFlight再送lane追加
- `edde176` — quota exceededの復旧可能な案内を追加
- `08686fa` — 初回`cloudkit.zoneshare`未存在の正規化
- `ad0bacb` — share lookupインシデント記録

## 8. 現在の状態と残る確認

### 完了

- Productionスキーマ配備
- Productionスキーマの機械検証
- CloudKit／CKShareコード修正
- Release IPAのProduction entitlement検証
- TestFlight配布
- 確認済み障害に対する回帰テスト追加

### 実機で必要な最終確認

異なるApple Accountでサインインした実機2台を使い、次を確認する。

1. 所有者側のiCloudストレージに空き容量がある
2. 所有者が初回共有リンクを作成できる
3. 参加者が共有リンクを受け入れられる
4. 所有者が追加したFamily／Bag／Itemが参加者へ反映される
5. 参加者の変更が所有者へ反映される
6. アプリ再起動後も共有状態を維持する
7. 共有解除後も端末内のローカルデータを保持する
8. 同じ家族で共有リンクを再作成できる

## 9. 再発防止チェックリスト

リリース前に次を必ず実施する。

- [ ] DevelopmentのSchema欄に`Modified`が残っていない
- [ ] `ruby scripts/verify_cloudkit_schema.rb`がProductionに対して成功する
- [ ] Release IPAが`bash scripts/verify_cloudkit_ipa.sh build/Stockpile.ipa`を通過する
- [ ] 初回共有未作成時の`CKError(.unknownItem)`回帰テストが成功する
- [ ] quota exceededが日本語の復旧案内へ変換される
- [ ] 異なるApple Accountの実機2台で双方向同期を確認する

## 10. 関連資料

- [初回の共有リンク作成が失敗する原因と対策](initial-share-link-failure-report.md)
- [共有リンク作成失敗（Record not found）インシデント](share-link-record-not-found-incident-report.md)
- [共有リンク作成が遅い原因と対策](share-link-performance-report.md)
- [CloudKit共有を含むアプリ問題レポート](issues-report.md)
- [App Store / TestFlight Release Automation](app-store-release.md)

