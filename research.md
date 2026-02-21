# リサーチ: Firebaseベース家族共有への移行（Stockpile iOS）

## 概要
現行アプリは SwiftData ローカル保存を主軸とし、家族共有の参加/招待フローのみ CloudKit に依存している。  
Firebase は未導入で、初期化処理・認証・同期基盤は存在しない。  
移行先は Spark プラン前提のため、Cloud Functions ではなく Firestore + Security Rules + クライアント側トランザクションで実装する必要がある。

## アーキテクチャ
- 永続化: SwiftData（`Family`, `User`, `Bag`, `Item`, `NotificationSettings`）
- 共有導線:
  - `Stockpile/Services/FamilySharingService.swift`: 共有開始・招待参加・離脱のオーケストレーション
  - `Stockpile/Services/CloudKitSharingService.swift`: CKShare作成、招待コード管理、共有承諾
  - `Stockpile/App/StockpileApp.swift`: CloudKit共有リンク受諾ハンドラ
  - `Stockpile/Views/ContentView.swift`: CloudKit共有受諾通知の監視
- UI:
  - `Stockpile/Views/Auth/FamilySetupView.swift`: 家族作成/参加
  - `Stockpile/Views/Settings/FamilySettingsView.swift`: 招待表示/離脱
  - `Stockpile/Views/Components/InviteCodeView.swift`, `QRScannerView.swift`: 6桁コード + QR導線

## データフロー
- 現行:
  - 家族作成時はローカル `Family` を作成
  - 共有開始時に CloudKit で CKShare + 招待コードレコードを生成
  - 参加時は CloudKit 招待検索→共有承諾→ローカル反映待ち
- 変更後:
  - Firestore を正本、SwiftData をキャッシュとして利用
  - 初回家族作成時にローカル `Family/Bag/Item` を Firestore へ upsert 移行
  - 移行後もローカルは保持し、listener で同期

## 既存の規約・パターン
- モデルIDは `UUID` を保持しているため、Firestore ドキュメントIDに流用可能
- 招待は6桁英数字（`Family.generateInviteCode()`）で実装済み
- QRは `stockpile://join?code=XXXXXX` 形式で実装済み
- 画面は `Router` で遷移管理し、サービスを View 内で都度生成している

## 注意点・制約
- Firebase未導入のため `project.pbxproj` へのパッケージ追加が必要
- Sparkプラン前提のため Cloud Functions を本番デプロイできない
- オフライン編集と同時更新が発生するため、競合は LWW を基本にする
- 家族離脱時はデータ削除せず、権限のみ剥奪する運用にする
- 初回移行で失敗してもローカルは消さない（再試行可能にする）

## 発見事項
- CloudKit依存を除去しない限り、シミュレータ制約やiCloudアカウント依存が残る
- 同期未実装のまま共有導線だけ移行すると、UI表示と実データの整合性が崩れる
- 初回移行は冪等性（同一ID upsert）を担保しないと重複登録リスクがある
