# App Store / TestFlight Release Automation

このリポジトリでは `fastlane` を使って TestFlight 配布と App Store 提出を自動化できます。

## 追加したもの

- `fastlane/Appfile`
- `fastlane/Fastfile`
- `fastlane/Matchfile`
- `.env.fastlane.example`
- `.github/workflows/ios-release.yml`

## 現在の前提

- Project: `Stockpile.xcodeproj`
- Scheme: `Stockpile`
- Bundle ID: `com.stockpile-manager.app`
- Apple Developer Team ID: `2L6CD9CNHL`

## 推奨構成

1. App Store Connect API key を使う
2. 署名は `match` で管理する
3. CI では `MATCH_READONLY=true` で実行する

`MATCH_GIT_URL` が未設定のときは、`fastlane` は現在の Xcode 自動署名を使う構成です。  
ただし CI で安定運用するなら `match` の設定を強く推奨します。

## 必要な secrets / env

必須:

- `ASC_KEY_ID`
- `ASC_ISSUER_ID`
- `ASC_KEY_CONTENT` または `ASC_KEY_FILEPATH`

任意:

- `ASC_KEY_CONTENT_BASE64`
- `APPLE_TEAM_ID`  
  未指定時は `2L6CD9CNHL`
- `ASC_TEAM_ID`
- `MATCH_GIT_URL`
- `MATCH_PASSWORD`
- `MATCH_READONLY`
- `BUILD_NUMBER`
- `VERSION_NUMBER`
- `TESTFLIGHT_CHANGELOG`
- `TESTFLIGHT_GROUPS`
- `TESTFLIGHT_DISTRIBUTE_EXTERNAL`
- `APPSTORE_SKIP_METADATA`
- `APPSTORE_SKIP_SCREENSHOTS`
- `APPSTORE_SUBMIT_FOR_REVIEW`
- `APPSTORE_AUTOMATIC_RELEASE`
- `APPSTORE_PHASED_RELEASE`

## ローカル実行例

```bash
bundle install
cp .env.fastlane.example .env.fastlane
bundle exec fastlane ios beta
```

App Store へアップロードだけ行う:

```bash
bundle exec fastlane ios release
```

審査提出まで行う:

```bash
APPSTORE_SUBMIT_FOR_REVIEW=true bundle exec fastlane ios release
```

審査通過後に自動公開する:

```bash
APPSTORE_SUBMIT_FOR_REVIEW=true APPSTORE_AUTOMATIC_RELEASE=true bundle exec fastlane ios release
```

## GitHub Actions

`/.github/workflows/ios-release.yml` から `beta` または `release` を手動実行できます。

最低限入れておきたい GitHub Secrets:

- `ASC_KEY_ID`
- `ASC_ISSUER_ID`
- `ASC_KEY_CONTENT`
- `MATCH_GIT_URL`
- `MATCH_PASSWORD`

`ASC_KEY_CONTENT` には `.p8` の中身そのものを入れられます。  
Base64 で保存する場合は `ASC_KEY_CONTENT_BASE64=true` も合わせて設定してください。
`APPLE_TEAM_ID` はこのリポジトリでは未指定でも `2L6CD9CNHL` を使います。

## build / version policy

- `BUILD_NUMBER` が設定されていれば、その値を `CURRENT_PROJECT_VERSION` に適用します
- `BUILD_NUMBER` が空で GitHub Actions 上なら `GITHUB_RUN_NUMBER` を使います
- `VERSION_NUMBER` が設定されていれば、その値を `MARKETING_VERSION` に適用します

## 注意点

- 現在の Xcode プロジェクトは自動署名です
- `match` を使う場合は、対象 App ID 用の App Store 用証明書・プロビジョニングプロファイルを先に用意してください
- App Store のメタデータやスクリーンショットは、この構成では既定でスキップします
- メタデータやスクリーンショットも `fastlane deliver` で管理したい場合は、`fastlane/metadata` の追加運用が必要です
