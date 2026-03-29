# stockpile-manager-swift

## Configuration

- iOS app に秘密情報を bundle しない運用へ変更しています
- `BackendBaseURL` は公開設定として app bundle に含めてもよい値で、既定では `https://stockpile-rakuten-proxy.vercel.app` を使用します
- 必要に応じて `Info.plist` かビルド環境変数 `BACKEND_BASE_URL` で上書きできます
- `RAKUTEN_APP_ID` / `RAKUTEN_ACCESS_KEY` / `YAHOO_CLIENT_ID` はローカル検証用の環境変数のみを想定し、配布物には含めません

## Security Notes

- `Secrets.plist` は配布用 bundle に含めません
- バーコード検索と「楽天市場で購入」は backend 経由で楽天 API / 楽天 URL を利用します
- バックアップ export は平文 JSON なので、安全な保存先で管理してください
