# Stockpile Product Search Worker

Stockpile iOS のバーコード検索、プライバシーポリシー、サポートページを提供する Cloudflare Worker です。

## エンドポイント

- `GET /health`
- `GET /v1/yahoo/search?jan=4901777300445`
- `GET /v1/rakuten/search?jan=4901777300445`
- `GET /v1/rakuten/search?jan=4901777300445&name=水`
- `GET /v1/rakuten/redirect?jan=4901777300445`
- `GET /v1/rakuten/redirect?jan=4901777300445&name=水`
- `GET|HEAD /privacy`
- `GET|HEAD /support`

Worker が各パスを直接処理するため、旧プラットフォームの rewrite 設定は使用しません。

検索 API の失敗レスポンスは既存契約を維持します。

- `404 { "error": "not_found" }`
- `429 { "error": "rate_limited", "retryAfterSeconds": 60 }`
- `503 { "error": "upstream_rate_limited" }`
- `503 { "error": "upstream_unavailable" }`

成功・未検出レスポンスには検索結果用のキャッシュヘッダーを、429・503 には `no-store` を返します。

## Cloudflare 設定

`wrangler.jsonc` の Worker 名は `stockpile-product-search-api` です。`PRODUCT_SEARCH_RATE_LIMITER` binding で、Cloudflare が付与する `CF-Connecting-IP` をキーに全検索系エンドポイントを1 IPあたり60秒30回に制限します。

必須 secrets:

- `YAHOO_CLIENT_ID`
- `RAKUTEN_APP_ID`
- `RAKUTEN_ACCESS_KEY`

任意の設定:

- `RAKUTEN_AFFILIATE_ID`
- `OPERATOR_NAME`
- `SUPPORT_EMAIL`

APIキーと問い合わせ先は Worker secrets として登録し、リポジトリへ保存しません。ローカル開発では `.dev.vars.example` を `.dev.vars` にコピーして値を設定してください。`.dev.vars` はコミットしないでください。

## ローカル確認

```bash
cd backend/cloudflare-product-search-api
npm ci
cp .dev.vars.example .dev.vars
npm run check
npm test
npm run dev
```

ローカル Worker は通常 `http://localhost:8787` で起動します。

```bash
curl -i http://localhost:8787/health
curl -i http://localhost:8787/privacy
curl -I http://localhost:8787/support
curl -i 'http://localhost:8787/v1/yahoo/search?jan=invalid'
```

## デプロイ

Cloudflare にログインした状態で、次を実行します。

```bash
cd backend/cloudflare-product-search-api
npm ci
npx wrangler secret put YAHOO_CLIENT_ID
npx wrangler secret put RAKUTEN_APP_ID
npx wrangler secret put RAKUTEN_ACCESS_KEY
npx wrangler secret put RAKUTEN_AFFILIATE_ID
npx wrangler secret put OPERATOR_NAME
npx wrangler secret put SUPPORT_EMAIL
npm run deploy
```

デプロイ後に表示された `workers.dev` URL で `/health`、`/privacy`、`/support`、`HEAD`、不正JAN、検索、楽天リダイレクト、429レスポンスを確認してください。

確認完了後、iOS の `BackendBaseURL` と App Store Connect の Privacy Policy URL / Support URL を Worker URL に切り替えます。
