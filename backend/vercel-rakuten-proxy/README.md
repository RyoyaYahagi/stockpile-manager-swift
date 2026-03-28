# Stockpile Rakuten Proxy

Stockpile iOS の「楽天市場で購入」ボタン用 Vercel バックエンドです。

## 役割

- iOS アプリから受け取った `jan` を元に楽天 API を検索する
- 楽天キーと `affiliateId` はサーバー側の環境変数で管理する
- 見つかった商品ページへ `307` リダイレクトする

## エンドポイント

- `GET /health`
- `GET /v1/rakuten/redirect?jan=4901777300445`

`/v1/*` は `vercel.json` で `/api/v1/*` に rewrite しています。

## 必要な環境変数

- `RAKUTEN_APP_ID`
- `RAKUTEN_ACCESS_KEY`
- `RAKUTEN_AFFILIATE_ID` 任意
  設定するとアフィリエイトURLへ誘導します。未設定時は通常の楽天URLへフォールバックします。

## デプロイ手順

1. Vercel で新規 Project を作成する
2. Root Directory を `backend/vercel-rakuten-proxy` に設定する
3. 上記 3 つの環境変数を登録する
4. Deploy する
5. 発行された URL を iOS 側の `BackendBaseURL` に設定する

## ローカル確認

```bash
cd backend/vercel-rakuten-proxy
npm run check
```

## iOS 側設定

`Secrets.plist` か環境変数に `BackendBaseURL` を設定します。

例:

```xml
<key>BackendBaseURL</key>
<string>https://your-project.vercel.app</string>
```
