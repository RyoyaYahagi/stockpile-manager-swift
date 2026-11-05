# Stockpile スナップショット Worker（テンプレート）

Stockpile の AI 連携（読み取り専用）で、**利用者ごとに1つ立てる**受け口です。
開発者のサーバーに他の利用者のデータは集めません。各利用者が自分の
Cloudflare アカウントにこの Worker をデプロイし、自分のスナップショットだけを置きます。

- 形式: `docs/snapshot-schema-v1.md`（スキーマ v1）
- 保存は最新1件のみ（履歴なし）
- トークンは読み取り用と書き込み用で分離します
  - 書き込み用（WRITE_TOKEN）: アプリの Keychain の中だけに置く
  - 読み取り用（READ_TOKEN）: 自分の AI アシスタント（Muse 等）にだけ渡す

## エンドポイント

| メソッド | パス | 認証 | 内容 |
|---|---|---|---|
| GET | `/v1/health` | なし | 疎通確認 `{ "ok": true }` |
| PUT | `/v1/snapshot` | Bearer WRITE_TOKEN | スナップショット保存（スキーマ検証つき、5MB / 5,000件まで） |
| GET | `/v1/snapshot` | Bearer READ_TOKEN | 最新スナップショット取得 |

## デプロイ手順

前提: Cloudflare アカウント（無料枠で十分）と Node.js。

```bash
cd templates/snapshot-worker

# 1. KV を作り、表示された id を wrangler.toml の REPLACE_WITH_YOUR_KV_NAMESPACE_ID に貼る
npx wrangler kv namespace create SNAPSHOTS

# 2. トークンを2本作る（控えは安全な場所に。WRITE はアプリ用、READ は AI 用）
openssl rand -hex 32   # WRITE_TOKEN 用
openssl rand -hex 32   # READ_TOKEN 用

# 3. シークレットとして登録する（値はコマンド履歴に残さない）
npx wrangler secret put WRITE_TOKEN
npx wrangler secret put READ_TOKEN

# 4. デプロイ
npx wrangler deploy
```

デプロイ後に表示される URL（例: `https://stockpile-snapshot.<you>.workers.dev`）が送信先です。

## アプリ側の設定

1. Stockpile の「設定 → AI連携」で、送信先 URL に
   `https://stockpile-snapshot.<you>.workers.dev/v1/snapshot` を入れ、
   トークン欄に WRITE_TOKEN を貼る
2. 「今すぐ送信」でテスト送信する
3. AI 側には、同じ画面の「セットアッププロンプトをコピー」から、
   READ_TOKEN を安全な方法で別途渡す（プロンプト本文にトークンは含まれない）

## 動作確認（curl）

```bash
curl https://stockpile-snapshot.<you>.workers.dev/v1/health
curl -H "Authorization: Bearer <READ_TOKEN>" \
  https://stockpile-snapshot.<you>.workers.dev/v1/snapshot
```

## トークンの失効・再発行

漏れた疑いがある場合は、該当トークンだけを再設定すれば失効します
（読み取り用だけを変えてもアプリ側の送信は止まりません）。

```bash
npx wrangler secret put READ_TOKEN   # 新しい値を設定すると旧値は無効になる
```

## テスト

```bash
npm test   # Node だけで動く簡易テスト（KV はインメモリの偽物）
```
