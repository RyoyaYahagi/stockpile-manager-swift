# stockpile-manager-swift

## Configuration

- iOS app に秘密情報を bundle しない運用へ変更しています
- `BackendBaseURL` は公開設定として app bundle に含めてもよい値ですが、共有 URL は使わず専用の Vercel URL を設定してください
- `Info.plist` の `YOUR_BACKEND_BASE_URL_HERE` を専用 backend URL に置き換えるか、ビルド環境変数 `BACKEND_BASE_URL` で上書きできます
- `RAKUTEN_APP_ID` / `RAKUTEN_ACCESS_KEY` / `YAHOO_CLIENT_ID` はローカル検証用の環境変数のみを想定し、配布物には含めません

## Security Notes

- `Secrets.plist` は配布用 bundle に含めません
- バーコード検索と「楽天市場で購入」は backend 経由で楽天 API / 楽天 URL を利用します
- バックアップ export は平文 JSON なので、安全な保存先で管理してください
