# Stockpile

家庭の防災備蓄を管理する iOS アプリです。食料品や日用品の在庫・賞味期限を一元管理し、家族間で共有できます。

## 主な機能

- **備蓄品の管理** — アイテムの登録・保管場所(バッグ)ごとの分類・数量・賞味期限の管理
- **期限トラッキングと通知** — 5段階の期限ステータス表示（期限切れ・間近・接近・安全・期限なし）とプッシュ通知。通知タイミングはカスタマイズ可能
- **バーコードスキャン** — JAN コードを読み取り、Yahoo ショッピング API / Open Food Facts から商品情報を自動取得
- **OCR 賞味期限読み取り** — カメラで撮影したパッケージから Vision フレームワークで賞味期限を認識
- **家族共有** — CloudKit を使った家族間のデータ同期。URL リンクで招待・参加者管理が可能
- **バックアップ** — JSON 形式でのエクスポート / インポートによるデータ移行
- **多言語対応** — 日本語・英語・韓国語・簡体字中国語・繁体字中国語

## 技術スタック

SwiftUI / SwiftData / CloudKit / AVFoundation / Vision / UserNotifications

## Configuration

- iOS app に秘密情報を bundle しない運用へ変更しています
- `BackendBaseURL` は公開設定として app bundle に含めてもよい値で、`https://stockpile-product-search-api.yhgry.workers.dev` を使用します
- 必要に応じて `Info.plist` かビルド環境変数 `BACKEND_BASE_URL` で Worker URL を上書きできます
- `YAHOO_CLIENT_ID` は backend 側の環境変数を優先し、配布物には含めません
- `YAHOO_CLIENT_ID` のローカル環境変数は backend なしで Yahoo API を直接確認したい場合の開発用フォールバックです

## Security Notes

- `Secrets.plist` は配布用 bundle に含めません
- バーコード検索は Cloudflare Workers backend 経由で Yahoo API / Open Food Facts を利用します
- バックアップ export は平文 JSON なので、安全な保存先で管理してください
