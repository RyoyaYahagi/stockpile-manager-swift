# stockpile-manager-swift

## Configuration

- iOS app に秘密情報を bundle しない運用へ変更しています
- `BackendBaseURL` は公開設定として app bundle に含めてもよい値で、既定では `https://stockpile-rakuten-proxy.vercel.app` を使用します
- 必要に応じて `Info.plist` かビルド環境変数 `BACKEND_BASE_URL` で専用 backend URL に上書きできます
- `RAKUTEN_APP_ID` / `RAKUTEN_ACCESS_KEY` / `YAHOO_CLIENT_ID` は backend 側の環境変数を優先し、配布物には含めません
- `YAHOO_CLIENT_ID` のローカル環境変数は backend なしで Yahoo API を直接確認したい場合の開発用フォールバックです

## Security Notes

- `Secrets.plist` は配布用 bundle に含めません
- バーコード検索は backend 経由で Yahoo API / 楽天 API を利用します
- バックアップ export は平文 JSON なので、安全な保存先で管理してください
