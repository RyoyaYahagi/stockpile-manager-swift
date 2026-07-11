# 共有リンク作成が遅い原因と対策レポート

更新日: 2026-06-13
対象: `FamilySharingService.swift`（`CloudKitFamilySharingService`）、`FamilySettingsView.swift`

---

## TLDR

実機（Debug / TestFlight / App Store）では共有準備の検証ポリシーが `strict` に解決されるため、共有ボタンをタップしてから共有シートが出るまでに **フル同期 → 家族レコード再確認 → CKShare 保存 → フル同期（2回目）→ 家族レコード再確認（2回目）→ アップロード検証 → 診断用リモート件数取得 → one-time URL 用の share 再保存** がすべて直列のネットワーク往復として走る。成功パスでも **約15〜20回のサーバー往復** が直列化されており、1往復 0.3〜1秒の実機 CloudKit では合計 5〜20秒かかる。失敗リトライに入ると固定スリープ（最大 約3〜5秒/回）がさらに加算される。

最も効果が大きい対策は次の3つ。

1. **2回目以降は既存 share のファストパスを実機でも有効にする**（現状 Simulator 限定）
2. **`finalizePreparedShare` 内の重複同期・重複 `ensureFamilyRecordExists` を削減する**
3. **診断用のリモート件数取得（3クエリ）をクリティカルパスから外す**

---

## 1. ユーザー操作から共有シート表示までの流れ

`FamilySettingsView.prepareShareLinkAndPresentActivity()`（FamilySettingsView.swift:412）は、以下が**すべて完了するまで** `isStartingShare` のスピナーを表示し続け、完了後にようやく共有シートを出す。

```
handleShareButtonTap
└─ prepareShare(for:)                          … (A) 共有準備本体
└─ prepareInvitationURL(preparedShare:)        … (B) iOS 26 one-time URL 発行
└─ presentPreparedShare → 共有シート表示
```

### (A) prepareShare の内部（実機 = strict ポリシー時）

| # | 処理 | ネットワーク往復 |
|---|---|---|
| 1 | `ensureCloudKitAccountAvailable`（外側） | accountStatus ×1 |
| 2 | `syncFamilyDataToCloudKit`（1回目） | accountStatus ×1、`ensureZoneExists` ×1、`fetchRemoteZoneState`（Family/Bag/Item/DeletionMarker の4クエリ）、`modify`（差分アップロード）×1 |
| 3 | `ensureFamilyRecordExists`（1回目） | `fetchRemoteZoneState` ×1（また4クエリ）、必要なら `modify` ×1 |
| 4 | `fetchExistingShare` | record fetch ×1 |
| 5 | `CKShare` 保存 | save ×1 |
| 6 | `finalizePreparedShare` → `hydrateShareURLIfNeeded` | URL が無い場合: 固定スリープ 0.25s+1s+2s ＋ fetch ×3 |
| 7 | `finalizePreparedShare` → `syncFamilyDataToCloudKit`（**2回目**） | #2 と同じ一式をもう一度 |
| 8 | `finalizePreparedShare` → `ensureFamilyRecordExists`（**2回目**） | また `fetchRemoteZoneState` 4クエリ |
| 9 | `verifyCloudKitUpload` | 最大3レコードを**直列** fetch（リトライ時はスリープ 0.3s/1s 追加） |
| 10 | `logRemoteCountsForDiagnostics` → `fetchRemoteRecordCounts` | クエリ ×3（診断ログのためだけ） |

### (B) prepareInvitationURL（iOS 26）

| # | 処理 | ネットワーク往復 |
|---|---|---|
| 11 | one-time participant を追加して share を再保存 | save ×1 |
| 12 | participantID が取れない場合 | `fetchZoneWideShare` で再 fetch ×1 |

ローカル処理としても、`syncFamilyDataToCloudKit` のたびに `LocalDataRepairService.repairInvalidAndDuplicateRecordsIfNeeded()` が全 Bag/Item/Family/User を走査して重複マージを行う（1タップで2回実行）。

---

## 2. 遅さの主要因（影響が大きい順）

### 原因1: 実機では常に「フル同期＋検証」が同期実行される

`CloudKitSharePreparationRuntime.shouldAllowDeferredSharePreparationAutomatically`（FamilySharingService.swift:10）は `isSimulatorApp` のみ `true`。つまり実機では常に `strict` に解決され、

- 既存 share のファストパス（`shouldTryExistingShareFastPath`）が**無効**
- 共有 URL を即返して検証を後回しにする deferred パス（`scheduleDeferredSharePreparationCompletion`）も**無効**

になる。結果、**2回目以降のリンク作成でも毎回フルパイプライン**が走る。コメントにある通り「TestFlight は Production CloudKit なので検証前にリンクを返さない」という正しさ優先の設計だが、`cloudKitHasRemoteBaseline == true` で一度検証済みの家族にまで毎回適用されている。

### 原因2: 同じ処理が1タップ内で二重実行される

- `syncFamilyDataToCloudKit` が `prepareShare`（FamilySharingService.swift:269）と `finalizePreparedShare`（同:327）で**2回**実行される。2回目は「参加者から見える状態を強める」ための防衛だが、share 保存の前後で家族データは変わっておらず、`fetchRemoteZoneState` の4クエリ＋修復パスがまるごと重複している。
- `ensureFamilyRecordExists` も2回呼ばれ、しかも**毎回独自に `fetchRemoteZoneState`（4クエリ）を再実行**して timestamp 比較している。直前の `syncFamilyDataToCloudKit` が同じ remoteState を取得済みなのに使い回していない。

→ `fetchRemoteZoneState` は1タップで最大4回（= 最大16クエリ）走る。

### 原因3: 診断ログのためのネットワーククエリがクリティカルパス上にある

`finalizePreparedShare` 成功時の `logRemoteCountsForDiagnostics`（FamilySharingService.swift:2276）は、リモートの Family/Bag/Item 件数を取るためだけに **3クエリを await** している。ユーザー体感には何も寄与しない。

### 原因4: Production スキーマでクエリが失敗すると全件 zone fetch ×4 に退避する

`fetchRecords`（FamilySharingService.swift:2529）はクエリ失敗時に `fetchRecordsByZoneChanges` へフォールバックするが、これは **change token なしの全 zone ダウンロード**で、しかも record type ごとに呼ばれるため、`fetchRemoteZoneState` 1回につき**同じ zone を4回フルダウンロード**する。Production で `recordName` 等の queryable index が未デプロイだと毎回この退避パスに入り、アイテム数に比例して劇的に遅くなる。

### 原因5: 失敗時の固定スリープが積み上がる

一時エラーが1回でも出ると、以下の固定待ちが加算される。

- 外側リトライ間隔: 0.75s / 1.5s / 3s（FamilySharingService.swift:181）
- リトライ前の既存 share 回収: 0.25s + 1s（同:1325）
- `hydrateShareURLIfNeeded`: 0.25s + 1s + 2s（同:397）
- `verifyCloudKitUpload` リトライ: 0.3s + 1s（同:1438）

### 原因6（軽微）: その他の直列往復・ローカルコスト

- `accountStatus` が1タップ内で最大3回呼ばれる（外側＋ sync ×2）。
- `verifyCloudKitUpload` は最大3レコードを**1件ずつ直列に** fetch する（`CKFetchRecordsOperation` は複数 ID を1往復で取れる）。
- `LocalDataRepairService` の全件修復パスが毎回（×2）走る。データ量が増えるとローカル CPU 時間も無視できない。

---

## 3. 対策

### 短期（コード変更小・効果大）

1. **検証済み家族にファストパスを許可する**
   `shouldTryExistingShareFastPath` / `shouldReturnPreparedShareImmediately`（FamilySharingService.swift:360-366）を、`allowPendingUpload` 固定ではなく
   `family.cloudKitHasRemoteBaseline && !family.cloudKitPendingSync` なら実機 strict でも `true` にする。
   → 2回目以降のリンク作成が「既存 share fetch ＋ one-time URL 保存」の約2往復になり、体感が数秒→1秒前後に短縮される。初回共有の正しさ（strict 検証）は維持される。

2. **`logRemoteCountsForDiagnostics` を fire-and-forget にする**
   `await` をやめて `Task { await ... }` に変える。クリティカルパスから3クエリが消える。

3. **`ensureFamilyRecordExists` の重複 fetch を排除する**
   `syncFamilyDataToCloudKit` が取得した `remoteState.familyRecord` の有無を戻り値（または family のフラグ）で伝え、直後の `ensureFamilyRecordExists` 呼び出しを省略する。`finalizePreparedShare` 内の2回目の `syncFamilyDataToCloudKit` も、share 保存によって zone 内データは変化しないため、`verifyCloudKitUpload` のみ残して削除してよい（削除が不安なら「1回目の sync で `recordsToSave` が空だった場合はスキップ」という条件付きでも往復は大きく減る）。

4. **`verifyCloudKitUpload` をバッチ fetch にする**
   backend に複数 recordID 対応の fetch を追加し、`CKFetchRecordsOperation(recordIDs:)` 1往復で3レコードを検証する。

### 中期（構造的な改善）

5. **CloudKit Console で Production スキーマと queryable index を必ずデプロイする**
   リリースフローに `Deploy Schema Changes` を組み込み、`fetchRecordsByZoneChanges` への退避（全件ダウンロード×4）が起きない状態を保つ。退避パスに入った場合は1回の zone fetch で全 record type を仕分けるよう `fetchRemoteZoneState` 側でまとめるのが望ましい。

6. **差分同期への移行**
   `fetchRemoteZoneState` は毎回全レコードをフル取得して timestamp 比較している。`CKFetchRecordZoneChangesOperation` の change token を永続化して差分のみ取得するか、少なくとも `desiredKeys` を `id` / timestamp 系フィールドに絞って転送量を減らす。

7. **`accountStatus` のセッション内キャッシュ**
   短時間（例: 30秒）の結果キャッシュで1タップあたり2往復削減。

8. **`LocalDataRepairService` の実行頻度を下げる**
   毎 sync ではなく、起動時1回＋データ変更時のみに限定する。

### UX 面（時間が残る場合の緩和策）

9. **進捗の可視化**: スピナーだけでなく「データを同期中…」「リンクを検証中…」など段階表示にすると、同じ待ち時間でも体感が改善する。
10. **事前準備**: 家族設定画面を開いた時点でバックグラウンドの `prepareShare` を開始しておけば、ボタンタップ時には既存 share fetch だけで済む（対策1とセットで有効）。

---

## 4. 期待効果の目安

| シナリオ | 現状の往復数（概算） | 対策1〜4適用後 |
|---|---|---|
| 初回共有（実機） | 15〜20往復 | 9〜12往復 |
| 2回目以降のリンク作成（実機） | 15〜20往復 | **2〜3往復** |
| Production index 未デプロイ時 | 上記＋全件 zone fetch ×最大16回 | 対策5で解消 |

---

## 5. 検証方法

- `CloudKitSharingDiagnostics` に各フェーズの開始/終了タイムスタンプを追加し、実機（TestFlight）で「タップ→共有シート表示」の所要時間をフェーズ別に計測する。
- 既存の回帰テスト（`CloudKitFamilySharingServiceTests`）に「baseline 確立済み家族ではフル同期が走らない」ことを backend のモック呼び出し回数で検証するテストを追加する。
- 対策1適用後も、issues-report.md 記載の実機チェックリスト（one-time URL の単回性、失効時の共有管理シートへのフォールバック等）が通ることを確認する。

---

## 6. 関連

- 既存レポート: [issues-report.md](issues-report.md) の「残リスク / 今後の改善 — `prepareShare` の重い同期フロー」を本レポートで具体化した。
