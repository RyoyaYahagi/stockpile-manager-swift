# 初回の共有リンク作成が失敗する原因と対策レポート

更新日: 2026-06-13
対象: `FamilySharingService.swift`（`CloudKitFamilySharingService` / `DefaultCloudKitFamilySharingBackend`）、`FamilySettingsView.swift`

---

## TLDR

「**CloudKit上のレコードが見つかりません**」は `CloudKitSharingError.recordNotFound`（FamilySharingService.swift:2855-2856）の文言で、初回共有では主に **`verifyCloudKitUpload`（共有保存直後の読み戻し検証）** から発生する。

初回が特に失敗しやすい本質的な理由は、**CloudKit のサーバー反映（eventual consistency）が完了する前に、保存したばかりの Family/Bag/Item を読み戻して検証している**こと。実機は `strict` ポリシーのためこの検証がブロッキングで、失敗するとリンクを返さずエラーになる。リトライ間隔（0/0.3/1秒）が初回書き込みの伝播時間に対して短すぎる。

ただし「レコードが見つかりません」に至る経路は複数あり、根本原因は1つではない。下記の通り **(1) 反映遅延、(2) `isAtomic=false` による部分保存失敗の握りつぶし、(3) Production スキーマ未デプロイ、(4) 検証対象とアップロード対象のズレ、(5) iCloud アカウント状態** が絡む。

---

## 1. 「レコードが見つかりません」が投げられる場所

`recordNotFound` は3か所で発生する。

| # | 発生箇所 | 条件 |
|---|---|---|
| A | `backend.fetchRecords(with:)`（FamilySharingService.swift:2717-2724） | `CKFetchRecordsOperation` が**成功扱い**でも、取得できたレコード数が要求 ID 数に満たない（= 1件でも欠ける）と `recordNotFound` を throw |
| B | `backend.fetchRecord(with:)`（同:2697-2699） | fetch 結果が空のとき |
| C | `save(record:)`（同:2021-2026） | `modify` が保存済みレコードを1件も返さなかったとき |

初回共有でユーザーが目にするのは、ほぼ **(A) 経由で `verifyCloudKitUpload` が失敗** → `shareDataNotUploaded(detail: recordNotFound)`（同:1482-1484）に包まれて
「CloudKit上に共有データを保存できませんでした。CloudKit上のレコードが見つかりません。」と表示されるパターン。

`FamilySettingsView.prepareShareLinkAndPresentActivity()`（FamilySettingsView.swift:432-436）の catch でこの `localizedDescription` がそのまま
「共有リンクの準備に失敗しました: …」として表示される。

---

## 2. 初回が失敗しやすい原因（影響が大きい順）

### 原因1: 保存直後の読み戻し検証がサーバー反映を待てていない（主因）

`finalizePreparedShare` は CKShare 保存後に
`syncFamilyDataToCloudKit` → `ensureFamilyRecordExists` → **`verifyCloudKitUpload`**（FamilySharingService.swift:329）を実行する。

`verifyCloudKitUpload`（同:1433）は Family＋先頭 Bag＋先頭 Item の record ID を
`fetchRecord` で**読み戻して存在確認**する。リトライ間隔は `0 / 0.3秒 / 1秒`（同:1438-1442）しかない。

CloudKit は書き込み後すぐに同一レコードを読み戻せる保証がなく、**初回（ゾーン新規作成 + 初回書き込み）は伝播に数秒かかることがある**。2回目以降は伝播済みなので通りやすいが、初回はこの 1.3 秒のリトライ枠を超えて `recordNotFound` のまま終わり、`shareDataNotUploaded` で失敗する。

実機は `strict` ポリシー（`shouldAllowDeferredSharePreparationAutomatically` が Simulator 限定 = FamilySharingService.swift:10-14）のため、この検証失敗が**そのままユーザー向けエラー**になる。Simulator では `allowPendingUpload` で検証を後回しにできるので再現しにくい — これが「実機の初回だけ落ちる」という症状につながる。

### 原因2: `isAtomic = false` で部分的な保存失敗が握りつぶされる

`modify`（FamilySharingService.swift:2741-2743）は `savePolicy = .changedKeys`、`isAtomic = false`。
`perRecordSaveBlock` は **`.success` のレコードしか集めず、失敗したレコードは黙って捨てる**（同:2747-2749）。

その結果、Bag や Item の保存が一部失敗しても **`syncFamilyDataToCloudKit` は成功として返る**。直後の `verifyCloudKitUpload` で「保存したはずのレコードが無い」＝ `recordNotFound` になって初めて表面化する。
つまり**本当の失敗理由（個々の `CKError`）がログに残らず、症状だけが recordNotFound として出る**。これが「原因が分かりにくい」最大の要因。

### 原因3: Production スキーマ未デプロイ（TestFlight / App Store）

Production CloudKit は Just-In-Time スキーマ作成が効かない。`Family` / `Bag` / `Item` の record type や queryable index（特に `recordName`）が未デプロイだと、初回の保存・クエリで失敗する。

`fetchRemoteZoneState` 側は `fetchRecordsAllowingMissingRecordType`（同:1837）で missing record type を空配列として吸収しているが、**`verifyCloudKitUpload` は素の `fetchRecord` を使うため、この保護が効かない**。スキーマ未デプロイ環境では verify が確実に recordNotFound になる。
（issues-report.md でも「リリース前の `Deploy Schema Changes` は引き続き必要」と明記済み。）

### 原因4: 検証対象とアップロード対象のズレ（空ファミリー / timestamp スキップ）

`verifyCloudKitUpload` の検証対象は「ローカルの先頭 Bag / 先頭 Item」（`ownerShareVerificationRecordIDs` = 同:1487-1498）。一方アップロードは `syncFamilyDataToCloudKit` の `shouldUploadRecord` 判定（timestamp 比較）で**差分のみ**送る。

- ローカルにデータがあるのにリモートの timestamp が新しく見えてアップロードをスキップ → でも verify は存在を要求 → recordNotFound。
- 逆に Bag/Item が無い空ファミリーでは Family だけ検証する（影響は小さいが、Family レコード自体の反映遅延で原因1に帰着）。

### 原因5: iCloud アカウント状態・ゾーン作成レース

- `ensureCloudKitAccountAvailable`（同:1341）が `.noAccount` / `.restricted` / `.couldNotDetermine` を返すと、そもそも準備が始まらない（Simulator で Apple Account 未ログインの典型）。
- `ensureZoneExists`（同:1500, 2513）でゾーンを作った直後にクエリすると `zoneNotFound` になり得る。リトライ対象だが、原因1と同じく待ち枠が短い。

### 原因6: リトライ自体が誘発するレート制限

[share-link-performance-report.md](share-link-performance-report.md) の通り初回は 15〜20 往復が直列で走る。失敗リトライ（外側 0.75/1.5/3秒）も重なり、`requestRateLimited` / `zoneBusy` を誘発する。これらはリトライ対象だが、有限回数を使い切ると最終的に失敗として表面化する。

---

## 3. 対策

### 短期（効果大・変更小）

1. **`verifyCloudKitUpload` のリトライ枠を初回向けに広げる**
   現状 `0 / 0.3 / 1秒`（計 1.3秒）を、指数バックオフで **`0.5 / 1 / 2 / 4秒`程度（計 7〜8秒）** に拡張する。初回書き込みの伝播待ちに耐えられるようにする。あわせて `recordNotFound` を明示的にリトライ対象として継続させる（現状も `shouldRetryCloudKitUploadVerification` で対象だが、回数が足りていない）。

2. **`modify` の部分失敗を握りつぶさない**
   `perRecordSaveBlock` の `.failure` を収集し、保存対象件数と保存成功件数が一致しない場合は**実際の `CKError` を含めて throw / ログ出力**する。これで「recordNotFound」ではなく真の原因（quota / schema / partialFailure 等）が分かるようになる。少なくとも `verifyCloudKitUpload` 失敗時の診断に部分失敗内容を残す。

3. **`verifyCloudKitUpload` を missing record type 耐性にする**
   `fetchRecord` 直叩きではなく、`fetchRemoteZoneState` と同じ missing-record-type 吸収（`shouldTreatMissingRecordTypeAsEmptyResult`）を通すか、Production スキーマ未デプロイ時は検証を「警告付きで通す」フォールバックにする（リリース前デプロイ前提を崩さない範囲で）。

4. **検証対象とアップロード対象を揃える**
   verify は「今回 `modify` で実際に保存に成功した record ID」を対象にする。`syncFamilyDataToCloudKit` の `modify` が返す `savedRecords` の ID を verify に引き継げば、timestamp スキップやズレで「送っていないものを検証する」事故を防げる。

### 中期（構造改善）

5. **初回は deferred（検証後回し）を実機でも許可する**
   `cloudKitHasRemoteBaseline == false`（= 未確立）の初回は、CKShare 保存と URL 取得が成功した時点でリンクを返し、`scheduleDeferredSharePreparationCompletion` でバックグラウンド検証する選択肢。ただし「Production で未反映のままリンクを配ると参加者側が空データを見る」リスクがあるため、**URL は返すが「同期中」表示を出す**などの UX とセットで設計する。正しさ最優先なら原因1〜4の対策を優先。

6. **リリースフローに CloudKit スキーマ deploy を組み込む**
   TestFlight / App Store 提出前に CloudKit Console の `Deploy Schema Changes` を必須手順化し、原因3を恒久的に潰す。

7. **アカウント未ログイン・ネットワーク不可を事前判定して明確に案内**
   準備開始前に `accountStatus` と簡易疎通を確認し、recordNotFound に化ける前に「iCloud にサインインしてください」等の的確なメッセージを出す（一部は実装済み = `ensureCloudKitAccountAvailable`）。

---

## 4. 切り分け方法（実機）

`CloudKitSharingDiagnostics` のログを使い、初回失敗時に以下を確認する。

1. `共有ゾーン保存検証失敗`（FamilySharingService.swift:1472）の `description` / `errorType` を見る
   - `recordNotFound` のみ → 原因1（反映遅延）が濃厚 → 対策1。
   - `CKError` が出ている → 原因2/3/5 → コード番号で切り分け（`unknownItem`=スキーマ/未反映、`notAuthenticated`=アカウント、`requestRateLimited`=原因6）。
2. CloudKit Console の Production スキーマに `Family`/`Bag`/`Item` と `recordName` index が存在するか → 原因3。
3. 同じ家族で2回目以降は成功するか → 成功するなら反映遅延（原因1）の裏付け。

---

## 5. 期待効果

| 対策 | 効果 |
|---|---|
| 1（リトライ枠拡張） | 初回の反映遅延による recordNotFound を大幅に削減 |
| 2（部分失敗を可視化） | 「原因不明の recordNotFound」が真の原因付きログになり、再発時の特定が即可能 |
| 3（missing type 耐性） | Production スキーマ過渡期の初回失敗を回避 |
| 4（検証対象を揃える） | timestamp スキップ起因の誤検証失敗を解消 |

---

## 6. 関連

- [issues-report.md](issues-report.md) — Production schema 未展開対応、`fetchExistingShare` の一時エラー誤判定など共有まわりの既修正点。
- [share-link-performance-report.md](share-link-performance-report.md) — 同じ準備フローの「遅さ」の分析。初回失敗（本レポート）と遅延は、いずれも「保存直後にフル同期＋検証を直列実行する」設計に起因する。
