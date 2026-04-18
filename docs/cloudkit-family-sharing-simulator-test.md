# CloudKit 家族共有テストガイド

このガイドは `Stockpile` の CloudKit 家族共有を、2 台の iOS Simulator で検証するための手順です。

## 前提

- 対象機能は App Store の購入共有ではなく、CloudKit を使った家族共有です
- このアプリは共有リンクで招待し、参加側がリンクを開くと共有を受理する構成です
- Simulator 上の CloudKit は Development 環境のみです。最終判定は実機 2 台で行ってください
- Apple Account は App Store Connect の Sandbox Tester ではなく、通常の Apple Account を使ってください
- Apple ID ログインと 2FA 入力は手動です

## 事前確認

- Bundle ID: `com.stockpile-manager.app`
- `CKSharingSupported`: `YES`
- 共有画面の主要導線:
  - `共有リンクを作成`
  - `共有リンクを再送`
  - `共有設定を管理`
  - `iCloudに保存`
  - `iCloudから最新化`

## 最短手順

リポジトリ直下で次を実行します。

```bash
./scripts/run_two_simulators_family_share.sh
```

デフォルトでは、この Mac で見つかった `iPhone 17` と `iPhone 17 Pro Max` を使います。別の端末を使いたい場合は、端末名または UDID を渡してください。

```bash
./scripts/run_two_simulators_family_share.sh "iPhone 17 Pro" "iPhone 16e"
```

## 手動セットアップ

### 1. Owner 側シミュレーター

1. `Settings` を開く
2. `Apple Account` にサインインする
3. `iCloud Drive` が ON であることを確認する
4. `Stockpile` を起動する
5. `設定` → `家族共有設定` を開く
6. 家族名が空なら先に入力する
7. `共有リンクを作成` を押す
8. 共有シートで `Copy` を選び、共有 URL をクリップボードに入れる

### 2. Participant 側シミュレーター

1. `Settings` を開く
2. Owner とは別の `Apple Account` にサインインする
3. `iCloud Drive` が ON であることを確認する
4. `Safari` を開く
5. Owner 側でコピーした共有 URL を貼り付けて開く
6. システムの共有受理フローを進め、`Stockpile` が開くことを確認する

## 検証シナリオ

### シナリオ A: 共有作成

期待結果:

- Owner 側で `共有リンクを作成` が成功する
- エラー `共有リンクの取得に失敗しました` が出ない
- 共有 URL をコピーできる

### シナリオ B: 共有受理

期待結果:

- Participant 側で共有リンクから `Stockpile` が起動する
- 共有受理後、家族が local only ではない状態になる
- 家族共有画面で `iCloud同期` セクションが表示される

### シナリオ C: 参加者表示

Owner 側で `家族共有設定` を開き、必要なら `iCloudから最新化` を押します。

期待結果:

- `メンバー` セクションに参加者が表示される
- `iCloud共有の参加者を表示しています` が出る
- 必要なら `共有設定を管理` で参加状態を確認できる

### シナリオ D: データ同期

1. Owner 側でアイテムを 1 件追加する
2. Owner 側で `iCloudに保存` を押す
3. Participant 側で `iCloudから最新化` を押す

期待結果:

- Participant 側に同じアイテムが現れる
- 収納場所や件数が一致する
- `iCloud同期に失敗しました` が出ない

### シナリオ E: Participant からの更新

1. Participant 側で共有済みアイテムを編集する
2. Participant 側で `iCloudに保存` を押す
3. Owner 側で `iCloudから最新化` を押す

期待結果:

- Owner 側へ変更が反映される
- 双方向更新が成立する

## 失敗時の見方

### 共有リンクは作れるが参加できない

優先確認:

- 両方の Simulator で iCloud サインイン済みか
- `iCloud Drive` が有効か
- 開いたリンクが古い private share URL ではないか
- Owner 側で `共有設定を管理` から再招待し直す必要がないか

### 参加はできるが同期しない

優先確認:

- 両側で `iCloudに保存` / `iCloudから最新化` を明示的に押したか
- Simulator では silent push が不安定なので、前面復帰や手動同期で追従するか
- Owner 側で保存後に件数が維持されているか

### Simulator 特有の注意

- Simulator は Development 環境専用です
- CloudKit push は実機より不安定です
- 「リンク受理」と「最終的な準リアルタイム同期」は分けて評価してください
- 家族共有の最終合否は、実機 2 台で再確認するのが安全です

## この Mac で確認したこと

- `Stockpile.xcodeproj` の `Stockpile` scheme で Simulator build が成功する
- 利用可能な iPhone Simulator が複数ある
- 少なくとも 2 台を boot できる
- build 成果物を 1 台へ install し、アプリ起動まで確認済み

## 追加コマンド

ビルド成果物:

```bash
ls /tmp/Stockpile-DD/Build/Products/Debug-iphonesimulator/Stockpile.app
```

利用可能な端末一覧:

```bash
xcrun simctl list devices available
```

手動で片方だけ起動:

```bash
xcrun simctl boot "<UDID>"
xcrun simctl bootstatus "<UDID>" -b
```
