# コマンド受信箱 仕様 v1（W シリーズ）

Muse などの外部 AI がらくストックのデータを書き換えるための仕組みの正式仕様。
Issue W-01〜W-08（#14〜#21）の実装は本書に従う。Issue 本文と食い違う点は本書を正とし、
食い違いの理由は末尾の「Issue からの変更点」に記す。

スナップショット（`docs/snapshot-schema-v1.md`）は変更しない。読み取りは従来どおり
スナップショットで行い、書き込みだけを本書のコマンドで行う。

## 1. 全体の流れ

1. Muse が `commands.json` にコマンドを追記する。
2. アプリは次の時点で `commands.json` を読む（D3: 即時化はしない）。
   - 起動時、フォアグラウンド復帰時、スナップショット送信の成功後
   - 同時に2つ以上の取り込みを走らせない（実行中なら後続はスキップ）
3. 各コマンドを「検証 → 処理済み判定 → 失効判定 → 権限判定 → 適用」の順に処理する。
4. 結果を `command-results.json` に書き戻す。
5. 1件以上を適用したら、スナップショットを送信する（自動送信の設定に関係なく、
   連携が有効なら送る）。結果の書き戻しを先に行う。

アプリは `commands.json` を作成時以外に書き換えない（Muse の書き込みと競合させないため）。
処理済みのコマンドを `commands.json` から消すのは Muse の役目。

## 2. 置き場所

### Google Drive

- アプリ名フォルダ（`GoogleDriveSnapshotWriter.folderName`）直下に置く。
  - `commands.json` … Muse が書く。初期内容 `{"version":1,"commands":[]}`
  - `command-results.json` … アプリが書く。初期内容 `{"version":1,"results":[]}`
- スコープが drive.file のため、アプリは自分で作ったファイルしか読めない。
  そのため Drive 連携のサインイン完了時と、取り込み時にファイルが見つからないときに、
  アプリが2つのファイルを作る。
- **Muse は `commands.json` を削除・作り直ししてはならない**（作り直したファイルは
  アプリから見えない）。内容の上書き更新だけを行う。

### カスタム URL（Worker、W-06）

| メソッドとパス | 認証 | 用途 |
|---|---|---|
| `GET /v1/commands` | `COMMANDS_TOKEN` または `WRITE_TOKEN` | Muse の追記前の読み出し / アプリの取り込み |
| `PUT /v1/commands` | `COMMANDS_TOKEN` | Muse がファイル全体を置き換える |
| `GET /v1/command-results` | `READ_TOKEN` または `COMMANDS_TOKEN` | Muse が結果を読む |
| `PUT /v1/command-results` | `WRITE_TOKEN` | アプリが結果を書く |

- `COMMANDS_TOKEN` が未設定のデプロイでは、上の4つはすべて 404 を返す（機能オフ）。
- まだ保存されていないファイルの GET は、初期内容（空の配列）を 200 で返す。
- 本文の上限は 1MB。形の検証（下記 3 章のトップレベル）だけを行い、中身の意味は検証しない。

## 3. commands.json

```json
{
  "version": 1,
  "commands": [
    {
      "commandId": "6B1F5C1E-1F1A-4C55-9E57-0B3F2F7D9A10",
      "issuedAt": "2026-11-08T10:00:00+09:00",
      "origin": "muse",
      "type": "item.update",
      "baseUpdatedAt": "2026-11-01T10:15:00+09:00",
      "payload": { "id": "3F2504E0-4F89-41D3-9A0C-0305E82C3301", "quantity": 2 }
    }
  ]
}
```

### 封筒（全コマンド共通）

| フィールド | 型 | 必須 | 説明 |
|---|---|---|---|
| commandId | String (UUID) | ○ | 冪等キー。大文字小文字は区別しない |
| issuedAt | String (ISO 8601) | ○ | 発行日時。失効判定に使う |
| origin | String | ○ | 発行元の名前（1〜100文字）。履歴と承認画面に出す |
| type | String | ○ | 4 章のいずれか |
| payload | Object | ○ | type ごとの中身 |
| baseUpdatedAt | String (ISO 8601) | type による | 競合検出用。Muse が読んだスナップショットの `updatedAt` |

- 上限: ファイル 1MB、コマンド 200 件。超えた分は処理せず `invalid` を返す。
- 未知のフィールドは無視する。
- `version` が 1 以外なら、ファイル全体を処理せずファイル単位のエラーを返す（6 章）。

### 競合検出

- `baseUpdatedAt` と対象アイテムの `syncTimestamp`（スナップショットの `updatedAt` と同じ値）を
  **秒単位に切り捨てて**比べる（スナップショットの ISO 8601 は秒までしか持たないため）。
- 異なれば適用せず `conflict` を返す。アプリ側の編集を黙って上書きしない。

## 4. コマンドの種類

項目名と値の制約はスナップショット v1 の検証ルールに合わせる
（name 1〜200文字、janCode 32文字以下、quantity 1〜999,999、expiryDate `yyyy-MM-dd`、
locationNote 2,000文字以下、category はスナップショット v1 の8種のいずれか）。

| type | 権限の能力 | baseUpdatedAt | payload |
|---|---|---|---|
| `item.add` | アイテム追加 | 不要 | `name`（必須）, `janCode`, `quantity`（省略時 1）, `expiryDate`, `bagName`, `locationNote`, `category` |
| `item.update` | アイテム編集 | 必須 | `id`（必須）と、変える項目だけ。省略は「変更なし」、`null` は「空にする」（name / quantity は null 不可） |
| `item.delete` | アイテム削除 | 必須 | `id`（必須） |
| `bag.add` | バッグ操作 | 不要 | `name`（必須） |
| `bag.rename` | バッグ操作 | 不要 | `name`（必須）, `newName`（必須） |
| `bag.delete` | バッグ操作 | 不要 | `name`（必須）。アイテムが入っているバッグは削除しない（`bag_not_empty`） |

- バッグは名前で指定する（スナップショット v1 にバッグ id がないため）。
  同じ名前のバッグが2つ以上あれば `bag_ambiguous`、なければ `bag_not_found`。
  `item.add` / `item.update` の `bagName` も同じ規則で既存のバッグに解決し、バッグは作らない。
  `bag.add` / `bag.rename` で既存と同名になる場合は `bag_exists`。
- `item.add` で作るアイテムの id は commandId と同じ UUID にする。同じ id のアイテムが
  既にあれば（別の端末が先に適用し CloudKit で同期された場合など）、作らずに `applied` を返す。
- 対象の Family は、アプリの画面からアイテム・バッグを追加するときと同じ規則で決める。
- 家族共有データも自分のデータと同じ権限ルールで扱う（D2）。

## 5. 権限（W-02）

- **書き込み連携スイッチ**（既定 OFF）。OFF の間はすべてのコマンドを
  `rejected` / `writes_disabled` にする。ON → OFF にした時点で承認待ちのコマンドも
  すべて `rejected` / `writes_disabled` にする。Issue の「キルスイッチ」はこのスイッチの OFF にあたる。
- 能力ごとの設定（「不可 / 許可 / 承認制」）。

  | 能力 | 既定 |
  |---|---|
  | アイテム追加 | 不可 |
  | アイテム編集 | 不可 |
  | アイテム削除 | 承認制（D1） |
  | バッグ操作 | 不可 |

- 不可 → `rejected` / `permission_denied`。許可 → 適用。承認制 → 承認キューへ（7 章）。
- 送信先の連携を解除したら（Drive のサインアウト、送信先の切り替え、連携そのものの無効化）、
  承認キューを破棄し、適用履歴に `link_removed` として残す（結果ファイルには書けないため）。

## 6. command-results.json

```json
{
  "version": 1,
  "updatedAt": "2026-11-08T10:05:00+09:00",
  "results": [
    {
      "commandId": "6B1F5C1E-1F1A-4C55-9E57-0B3F2F7D9A10",
      "type": "item.update",
      "origin": "muse",
      "status": "applied",
      "reason": null,
      "message": "数量を 1 → 2 に変更しました",
      "itemId": "3F2504E0-4F89-41D3-9A0C-0305E82C3301",
      "processedAt": "2026-11-08T10:05:00+09:00"
    }
  ]
}
```

- 1つの commandId につき1件。`pending_approval` は承認・却下・失効の時点で同じ行を最終結果に置き換える。
- 保持するのは直近 200 件かつ 30 日以内。新しい順に並べる。
- `message` は人が読む日本語の説明。`reason` は機械が読むコード。

| status | 意味 | 主な reason |
|---|---|---|
| `applied` | 適用した | — |
| `pending_approval` | 承認待ち | `approval_required`, `waiting_for_earlier` |
| `rejected` | 適用しなかった | `writes_disabled`, `permission_denied`, `denied_by_user`, `not_found`, `bag_not_found`, `bag_ambiguous`, `bag_exists`, `bag_not_empty` |
| `conflict` | baseUpdatedAt が合わない | `stale_base` |
| `expired` | 発行から7日を超えた | `expired` |
| `invalid` | 封筒・payload の検証失敗 | `invalid_envelope`, `invalid_payload`, `too_many_commands` |
| `unsupported` | 未知の type | `unknown_type` |
| `error` | アプリ内部の失敗 | `internal_error` |

- ファイル単位のエラー（JSON として壊れている、`version` 不一致、1MB 超）は
  `commandId: null`、`status: "invalid"`、`reason: "malformed_file"` の1件で返す。
  同じ内容のファイルで繰り返し追加しない（内容のハッシュで判定）。

## 7. 処理済み・失効・承認キュー

- **処理済み判定**: 端末内に処理済み commandId を処理日時つきで保存し、30 日で消す。
  加えて、結果ファイルに最終状態（`pending_approval` 以外）で載っている commandId も処理済みとして扱う
  （同じ Drive に複数の端末をつないだ場合の二重適用を減らすため）。
- **失効**: 処理時点で `issuedAt` から7日を超えていれば `expired`。承認待ちのまま7日を超えたものも、
  次の取り込み時に `expired` にする。
- **承認キュー**（W-04）: 承認制のコマンドはデータに触れずにキューへ入れ、`pending_approval` を返す。
  - 許可したときは、その時点で検証・競合判定をやり直してから適用する。
  - 却下したときは `rejected` / `denied_by_user`。
  - **順序の保持**: 承認待ちのコマンドと同じ対象（同じアイテム id、または同じバッグ名）を指す後続のコマンドは、
    自分の権限が「許可」でも先に適用せず、`pending_approval` / `waiting_for_earlier` としてキューの後ろに並べる。
    先のコマンドが片付いたら（許可・却下・失効のいずれでも）、権限判定からやり直す。

## 8. 端末内の保存

- 受信箱の状態（処理済み commandId、承認キュー、適用履歴、ファイル単位エラーのハッシュ）は
  Application Support 配下の JSON ファイルに保存する。
- **SwiftData の @Model を追加しない**（CloudKit のスキーマが変わるため）。
- 権限設定は UserDefaults（`SnapshotLinkSettings` と同じ流儀）に保存する。
- 適用履歴は直近 500 件。項目は日時・origin・type・status・reason・message。

## 9. Issue からの変更点

| 点 | Issue | 本書 | 理由 |
|---|---|---|---|
| 既定状態とD1 | 「既定は全て不可」と「削除の初期値は承認制」が並び、受け入れ条件は「既定では全コマンドが権限なし」 | 書き込み連携スイッチ（既定 OFF）を設け、能力別の既定は削除だけ承認制 | 2つの決定を両立させるため。キルスイッチと同じ役割のスイッチを、既定値の置き場所としても使う |
| バッグの指定 | `bag` | `bagName` | スナップショット v1 の項目名に合わせる |
| 競合の比較 | updatedAt の一致 | 秒単位で比較 | スナップショットの日時は秒までしかない |
| item.add の id | 指定なし | commandId と同じ | 複数端末での二重追加を防ぐ |
| Worker の結果 | `/v1/commands` のみ | `/v1/command-results` を追加 | 結果を Muse に返す経路が必要 |
| Drive のファイル | 作成のみ | Muse は作り直し禁止 | drive.file ではアプリが作ったファイルしか読めない |

## 10. 削除方式（W-05）

`item.delete` と `bag.delete` は、画面からの削除と同じ「削除マーカー＋即時削除」にした。
家族共有のデータでは、削除前に `CloudKitDeletionMarker` を作ってから
`modelContext.delete` し、保存と CloudKit 同期は `InventoryStore.saveAndSync` に任せる
（`CloudKitFamilySharingService.deleteItemLocally` / `deleteBagLocally` と同じ経路）。
画面の「元に戻す」はスナックバーが出ている 5 秒間だけで、それを過ぎると戻せない。
コマンド経由の削除もこの既存の挙動に合わせ、独自のゴミ箱（一定期間復元できる仕組み）は
作っていない。

削除の既定は承認制（D1）。Muse からの削除は、W-04 の承認画面で内容を確認してから
許可する。承認画面では `CommandDescriber` の「〜を削除します」を確認ダイアログに出す。
`bag.delete` は空のバッグだけを対象にし、アイテムが 1 件でも入っていれば
`bag_not_empty` で何もしない。

一定期間は削除を取り消せるようにしたい場合は、削除マーカーの保持期間や復元 UI を
別 Issue として提案する（スナップショット v1 と SwiftData のスキーマは変えない）。
