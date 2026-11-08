# Stockpile スナップショット Worker（テンプレート）

Stockpile の AI 連携で、**利用者ごとに1つ立てる**受け口です。
開発者のサーバーに他の利用者のデータは集めません。各利用者が自分の
Cloudflare アカウントにこの Worker をデプロイし、自分のデータだけを置きます。

- 形式: `docs/snapshot-schema-v1.md`（スキーマ v1）
- 保存はドキュメントごとに最新1件のみ（履歴なし）
- トークンは用途ごとに3種類に分離します
  - 書き込み用（WRITE_TOKEN）: アプリの Keychain の中だけに置く。スナップショットの保存とコマンド結果の書き込みに使う
  - 読み取り用（READ_TOKEN）: 自分の AI アシスタント（Muse 等）に渡す。スナップショットとコマンド結果の読み取りに使う
  - コマンド用（COMMANDS_TOKEN）: 自分の AI アシスタント（Muse 等）に渡す。コマンドの読み書きに使う
- **Muse には READ_TOKEN と COMMANDS_TOKEN を渡し、WRITE_TOKEN はアプリだけが持ちます**
- `COMMANDS_TOKEN` を設定しないデプロイでは、コマンド受信箱の4つの端点は 404 になります（スナップショットは従来どおり動きます）

## エンドポイント

| メソッド | パス | 認証 | 内容 |
|---|---|---|---|
| GET | `/v1/health` | なし | 疎通確認 `{ "ok": true }` |
| PUT | `/v1/snapshot` | Bearer WRITE_TOKEN | スナップショット保存（スキーマ検証つき、5MB / 5,000件まで） |
| GET | `/v1/snapshot` | Bearer READ_TOKEN | 最新スナップショット取得 |
| GET | `/v1/commands` | Bearer COMMANDS_TOKEN または WRITE_TOKEN | コマンドの取得（未保存なら初期内容） |
| PUT | `/v1/commands` | Bearer COMMANDS_TOKEN | コマンドの保存（1MB / 200件まで） |
| GET | `/v1/command-results` | Bearer READ_TOKEN または COMMANDS_TOKEN | コマンド結果の取得（未保存なら初期内容） |
| PUT | `/v1/command-results` | Bearer WRITE_TOKEN | コマンド結果の保存（1MBまで） |

コマンド受信箱の形式は `docs/command-inbox-v1.md` です。Worker はトップレベルの形
（オブジェクト、`version: 1`、`commands` / `results` が配列、`commands` は200件以下）だけを検証し、
壊れた JSON は 400、1MB を超える本文は 413 を返します。

## デプロイ手順

前提: Cloudflare アカウント（無料枠で十分）と Node.js。

```bash
cd templates/snapshot-worker

# 1. KV を作り、表示された id を wrangler.toml の REPLACE_WITH_YOUR_KV_NAMESPACE_ID に貼る
npx wrangler kv namespace create SNAPSHOTS

# 2. トークンを3本作る（控えは安全な場所に。WRITE はアプリ用、READ と COMMANDS は AI 用）
openssl rand -hex 32   # WRITE_TOKEN 用
openssl rand -hex 32   # READ_TOKEN 用
openssl rand -hex 32   # COMMANDS_TOKEN 用（コマンド受信箱を使う場合）

# 3. シークレットとして登録する（値はコマンド履歴に残さない）
npx wrangler secret put WRITE_TOKEN
npx wrangler secret put READ_TOKEN
npx wrangler secret put COMMANDS_TOKEN

# 4. デプロイ
npx wrangler deploy
```

デプロイ後に表示される URL（例: `https://stockpile-snapshot.<you>.workers.dev`）が送信先です。

## アプリ側の設定

1. Stockpile の「設定 → AI連携」で、送信先 URL に
   `https://stockpile-snapshot.<you>.workers.dev/v1/snapshot` を入れ、
   トークン欄に WRITE_TOKEN を貼る
2. 「今すぐ送信」でテスト送信する
3. AI 側には READ_TOKEN と COMMANDS_TOKEN を安全な方法で別途渡す
   （WRITE_TOKEN はアプリだけに置き、AI には渡さない）

## 動作確認（curl）

```bash
curl https://stockpile-snapshot.<you>.workers.dev/v1/health
curl -H "Authorization: Bearer <READ_TOKEN>" \
  https://stockpile-snapshot.<you>.workers.dev/v1/snapshot

# コマンド受信箱（Muse 用）
curl -H "Authorization: Bearer <COMMANDS_TOKEN>" \
  https://stockpile-snapshot.<you>.workers.dev/v1/commands
curl -X PUT -H "Authorization: Bearer <COMMANDS_TOKEN>" \
  -H "Content-Type: application/json" \
  --data-binary @commands.json \
  https://stockpile-snapshot.<you>.workers.dev/v1/commands
```

## トークンの失効・再発行

漏れた疑いがある場合は、該当トークンだけを再設定すれば失効します
（読み取り用だけを変えてもアプリ側の送信は止まりません）。

```bash
npx wrangler secret put READ_TOKEN      # 新しい値を設定すると旧値は無効になる
npx wrangler secret put COMMANDS_TOKEN  # コマンド受信箱を使う場合
```

コマンド受信箱を無効にする場合は、`COMMANDS_TOKEN` を削除します（4つの端点が 404 に戻ります）。

```bash
npx wrangler secret delete COMMANDS_TOKEN
```

## テスト

```bash
npm test   # Node だけで動く簡易テスト（KV はインメモリの偽物）
```
