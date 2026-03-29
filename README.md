# stockpile-manager-swift

## Configuration

- iOS app に秘密情報を bundle しない運用へ変更しています
- `BackendBaseURL` は公開設定として `Info.plist` かビルド環境変数 `BACKEND_BASE_URL` に設定してください
- `RAKUTEN_APP_ID` / `RAKUTEN_ACCESS_KEY` / `YAHOO_CLIENT_ID` はローカル検証用の環境変数のみを想定し、配布物には含めません

## Security Notes

- `Secrets.plist` は配布用 bundle に含めません
- バックアップ export は平文 JSON なので、安全な保存先で管理してください
