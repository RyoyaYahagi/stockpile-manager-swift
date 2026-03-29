# Stockpile Rakuten Proxy

Stockpile iOS の「楽天市場で購入」ボタン用 Vercel バックエンドです。

## 役割

- iOS アプリから受け取った `jan` と任意の `name` を元に楽天 API を検索する
- 楽天キーと `affiliateId` はサーバー側の環境変数で管理する
- 見つかった商品ページへ `307` リダイレクトする
- 該当商品が見つからない場合は楽天市場の検索結果ページへフォールバックする

## エンドポイント

- `GET /health`
- `GET /v1/rakuten/redirect?jan=4901777300445`
- `GET /v1/rakuten/redirect?jan=4901777300445&name=%E6%B0%B4`

`/v1/*` は `vercel.json` で `/api/v1/*` に rewrite しています。

## 必要な環境変数

- `RAKUTEN_APP_ID`
- `RAKUTEN_ACCESS_KEY`
- `RAKUTEN_AFFILIATE_ID` 任意
  設定するとアフィリエイトURLへ誘導します。未設定時は通常の楽天URLへフォールバックします。
- `RATE_LIMIT_MAX_REQUESTS_PER_MINUTE` 任意
  1 IP あたりの 1 分間の上限回数です。未設定時は `30` を使用します。

## セキュリティ前提

- この endpoint は code 側で 1 IP あたりの簡易レート制限を行います
- redirect 先は `https://*.rakuten.co.jp` に限定します
- 商用公開時は、上記に加えて Vercel Firewall / WAF / 監視の有効化を推奨します

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

`BackendBaseURL` は公開してよい設定として iOS の `Info.plist` かビルド環境変数に設定します。アプリ bundle に秘密情報は同梱しません。

例:

```xml
<key>BackendBaseURL</key>
<string>https://your-project.vercel.app</string>
```
