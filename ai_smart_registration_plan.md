# Stockpile AIスマート登録 v1

## Summary

- このアプリで最初に入れるべきAIは、汎用チャットエージェントではなく「追加フォームのスマート登録」。
- 既存のバーコード検索、OCR、SwiftData保存、CloudKit共有の流れはそのまま活かし、AIは入力補完レイヤーとして挟む。
- 実行方式はハイブリッド。端末内で取れる情報は端末で処理し、難しい推論だけ既存Vercelバックエンド経由でLLMに渡す。
- 保存・更新・削除をAIが勝手に実行することはしない。AIは提案のみ、最終確定はユーザー。

## Key Changes

- iOS追加導線:
  [ItemFormSheet](/Users/yappa/code/app/stockpile_ios/Stockpile/Views/Items/ItemFormSheet.swift) に `AIで補完` の提案UIを追加し、バーコード採用後またはOCR後に自動で補完候補を表示する。
- OCR連携:
  [OCRCameraView](/Users/yappa/code/app/stockpile_ios/Stockpile/Views/Components/OCRCameraView.swift) の戻り値を `Date?` から `OCRCaptureResult` に拡張し、抽出日付に加えて認識テキストと必要時のみ圧縮画像を返せるようにする。
- 新規アプリ内型:
  `SmartRegistrationEvidence`、`SmartRegistrationSuggestion`、`SmartRegistrationService` を追加する。候補は `name` `quantity` `expiryDate` `bagSuggestion` `confidence` `reason` を持つ。
- バックエンド:
  [backend/vercel-rakuten-proxy](/Users/yappa/code/app/stockpile_ios/backend/vercel-rakuten-proxy) に `POST /v1/ai/smart-register` を追加し、JAN・商品名・OCRテキスト・必要時のみ画像を受けて、JSON schema固定の構造化レスポンスを返す。
- UX仕様:
  候補はフォームへ即保存せず、フィールドごとに `適用` できるカードで表示する。信頼度が低い場合は「確認が必要」を明示する。
- 既存互換:
  AI失敗時・オフライン時・レート制限時は現行の手入力フローへ即フォールバックし、保存処理・通知再スケジュール・CloudKit同期は現状維持。
- エージェント化の位置づけ:
  会話型エージェントは v2。v1の `SmartRegistrationService` と証拠データを再利用して後から載せる。

## Public Interfaces / Types

- `OCRCaptureResult`
  `detectedDate: Date?`
  `recognizedText: String`
  `imageJPEGData: Data?`
- `SmartRegistrationRequest`
  `janCode: String?`
  `productName: String?`
  `productCategory: String?`
  `ocrText: String?`
  `imageBase64: String?`
  `locale: String`
- `SmartRegistrationResponse`
  `suggestedName: String?`
  `suggestedQuantity: Int?`
  `suggestedExpiryDate: String?`
  `suggestedBagName: String?`
  `confidence: high|medium|low`
  `reasons: [String]`
  `needsUserConfirmation: Bool`

## Test Plan

- バーコードのみで商品名候補が高信頼で入ること。
- OCRのみで日本語の期限表記から日付候補が返ること。
- バーコード結果とOCR結果が矛盾したとき、自動適用せず低信頼表示になること。
- AI API失敗時も追加フォームが壊れず、手入力で保存できること。
- 既存の保存後処理で通知再スケジュールとCloudKit同期が回帰しないこと。
- 既存の収納場所に一致する場合だけ `bagSuggestion` を適用し、未知の収納場所は新規作成しないこと。
- 多言語UIでも提案表示が崩れず、レスポンスは現在ロケールに従って生成されること。

## Assumptions

- v1の対象は追加フォームのみ。編集画面、ダッシュボード提案、家族向け要約は次フェーズ。
- v1ではSwiftDataの永続スキーマは増やさず、AI提案は画面内の一時状態として扱う。
- APIキーやモデル設定はすべてサーバー環境変数で管理し、iOSアプリには持ち込まない。
- 画像は必要時のみ送信し、サーバーには保存しない。
- 初期公開は feature flag 前提で、課金連携は後段。価値検証後に既存プレミアム導線へ統合する。
