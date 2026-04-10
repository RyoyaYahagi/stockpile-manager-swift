# 実装計画: Firebase家族共有 + Item/Bag同期（Sparkプラン）

## 前提（確定）
- Firebaseプロジェクト名: `stockpile`（未作成）
- プラン: Spark（無料）
- リージョン: `asia-northeast1`
- 認証: 匿名認証のみ（将来Apple連携）
- 招待: 6桁英数字 + QR（24時間有効）
- 初回移行: ローカルデータを Firebase に移行して開始
- 移行後ローカル: 保持（キャッシュ運用）
- 競合解決: LWW（必要箇所のみトランザクション）
- 離脱時: 家族データ保持、当該ユーザーのアクセス権のみ剥奪

## アプローチ
1. Firebase導入と匿名認証の土台を先に作る。
2. Firestoreを正本にする共有サービス層を追加し、既存 `FamilySharingService` の CloudKit 依存を置換する。
3. 初回家族作成時にローカル `Family/Bag/Item` を同一IDで upsert 移行する。
4. `Item/Bag` は Firestore listener と SwiftData 更新で双方向同期する。
5. CloudKit導線を削除して実装を一本化する。

## 変更対象ファイル
- `Stockpile/App/StockpileApp.swift`
- `Stockpile/Services/FamilySharingService.swift`
- `Stockpile/Views/Auth/FamilySetupView.swift`
- `Stockpile/Views/Settings/FamilySettingsView.swift`
- `Stockpile/Views/ContentView.swift`
- `Stockpile/Models/Family.swift`
- `Stockpile/Models/Bag.swift`
- `Stockpile/Models/Item.swift`
- `Stockpile/Stockpile.entitlements`
- `Stockpile.xcodeproj/project.pbxproj`

新規追加（予定）
- `Stockpile/Services/FirebaseBootstrapService.swift`
- `Stockpile/Services/FirebaseAuthService.swift`
- `Stockpile/Services/FirebaseFamilyRepository.swift`
- `Stockpile/Services/FirebaseSyncService.swift`
- `Stockpile/Models/DTO/FirebaseFamilyDTO.swift`
- `Stockpile/Models/DTO/FirebaseBagDTO.swift`
- `Stockpile/Models/DTO/FirebaseItemDTO.swift`
- `Stockpile/Config/FirebaseConfig.example.plist`（運用補助）

## 変更内容

### 1) Firebase初期化 + 匿名認証
`Stockpile/App/StockpileApp.swift` の起動時に Firebase 初期化と匿名認証の開始を追加する。

```swift
import FirebaseCore

@main
struct StockpileApp: App {
    init() {
        FirebaseBootstrapService.configureIfNeeded()
    }
}
```

```swift
@MainActor
final class FirebaseAuthService {
    func ensureAnonymousSignIn() async throws -> String {
        if let uid = Auth.auth().currentUser?.uid { return uid }
        let result = try await Auth.auth().signInAnonymously()
        return result.user.uid
    }
}
```

### 2) Firestoreスキーマと招待
Cloud Functionsは使わず、クライアントトランザクションで招待参加を整合化する。

```swift
// invites/{inviteCode}
// { familyId, familyName, expiresAt, createdBy, createdAt }

func joinByInviteCode(_ code: String, uid: String) async throws {
    try await db.runTransaction { tx, _ in
        let inviteRef = db.collection("invites").document(code)
        let invite = try tx.getDocument(inviteRef)
        // expiresAt 検証 / familyId 解決 / members/{uid} upsert
        // families/{familyId}.memberCount 更新
        return nil
    }
}
```

### 3) 初回家族作成時のローカル→Firebase移行
家族作成成功後にローカルデータを同一IDで upsert 移行し、再実行しても壊れないようにする。

```swift
func migrateLocalDataOnFirstFamilyCreate(family: Family) async throws {
    let marker = UserDefaults.standard.bool(forKey: "firebase.initialMigration.completed")
    guard !marker else { return }

    try await repository.upsertFamily(family)
    try await repository.bulkUpsertBags(family.bags)
    try await repository.bulkUpsertItems(family.items)

    UserDefaults.standard.set(true, forKey: "firebase.initialMigration.completed")
}
```

### 4) Item/Bag同期（Firestore正本、SwiftDataキャッシュ）
Firestore listener を購読し、差分をローカルに反映する。ローカル更新時はFirestoreへ write-through する。

```swift
func startSync(familyId: UUID) {
    bagsListener = db.collection("families/\(familyId)/bags")
        .addSnapshotListener { [weak self] snapshot, _ in
            self?.applyBagChanges(snapshot)
        }

    itemsListener = db.collection("families/\(familyId)/items")
        .addSnapshotListener { [weak self] snapshot, _ in
            self?.applyItemChanges(snapshot)
        }
}
```

### 5) CloudKit導線の削除
CloudKit共有受諾通知と `CloudKitSharingService` 依存を段階的に除去する。

```swift
// remove
import CloudKit
func application(_:userDidAcceptCloudKitShareWith:){}
```

## 考慮事項
- Spark制約でサーバーサイド関数を使わないため、Security Rulesの厳密化が品質の要点
- listener反映時に自己更新ループを避けるため、`updatedAt` 比較または書き込み元タグを導入する
- 既存ローカルデータ保持方針のため、初回移行後に重複作成しないようID upsertを徹底する
- 移行失敗時はローカル維持 + 再試行可能にし、データ消失を防ぐ

## Todo List

### Phase A: 基盤準備
- [ ] Firebaseプロジェクト `stockpile` を作成（iOSアプリ登録含む）
- [ ] `GoogleService-Info.plist` を追加
- [ ] SPMで Firebase SDK（Core/Auth/Firestore）を導入
- [ ] 起動時 `FirebaseApp.configure()` と匿名認証を実装

### Phase B: Firestoreモデル・リポジトリ
- [ ] Firestoreコレクション設計をコードへ反映（DTO/Mapper作成）
- [ ] `FirebaseFamilyRepository` を実装（family/member/invite CRUD）
- [ ] 招待コード24時間期限ロジックを実装
- [ ] 参加処理をトランザクション化（期限検証・重複参加防止）

### Phase C: 初回移行
- [ ] 初回家族作成フローに移行処理を接続
- [ ] `Family/Bag/Item` upsert移行を実装
- [ ] 移行完了フラグと再試行導線を実装
- [ ] 失敗時のUIエラー表示を実装

### Phase D: 同期
- [ ] `FirebaseSyncService` を実装（bags/items listener）
- [ ] ローカル更新の write-through を実装
- [ ] 同期反映ループ防止の制御を実装
- [ ] 画面再入場時の listener 開始/停止を実装

### Phase E: 既存機能の置換
- [ ] `FamilySharingService` を Firebase 実装へ差し替え
- [ ] `FamilySetupView` / `FamilySettingsView` を新サービス接続へ更新
- [ ] 招待QR・6桁コード導線の動作確認
- [ ] CloudKit関連コード・entitlementを削除

### Phase F: 検証
- [ ] `swift build` 実行
- [ ] Firebase Emulator で招待/参加/期限切れを検証
- [ ] 2端末（または2セッション）で Item/Bag 同期を検証
- [ ] 競合更新（LWW）挙動を検証
- [ ] リグレッション（通知・一覧・編集導線）を確認
