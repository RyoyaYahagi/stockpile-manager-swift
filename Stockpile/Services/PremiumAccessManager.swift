import Foundation
import Observation
import StoreKit

enum PurchaseState: Equatable {
    case loading
    case free
    case premium
    case purchaseInProgress
    case error(String)
}

enum PremiumEntryPoint: String, Identifiable {
    case bagLimit
    case notificationTimingLimit
    case ocrQuota
    case barcodeQuota

    var id: String { rawValue }

    var headline: String {
        switch self {
        case .bagLimit:
            return L10n.string("収納場所を3件以上作るには有料版が必要です。")
        case .notificationTimingLimit:
            return L10n.string("通知タイミングを2件以上追加するには有料版が必要です。")
        case .ocrQuota:
            return L10n.string("今日のOCR無料枠を使い切りました。")
        case .barcodeQuota:
            return L10n.string("今日のバーコード検索無料枠を使い切りました。")
        }
    }

    var descriptionText: String {
        switch self {
        case .bagLimit:
            return L10n.format(
                "無料版では収納場所は%@件までです。有料版では無制限に追加できます。",
                String(PremiumAccessManager.freeBagLimit)
            )
        case .notificationTimingLimit:
            return L10n.format(
                "無料版では通知タイミングは%@件までです。有料版では最大%@件まで追加できます。0日は当日通知です。",
                String(PremiumAccessManager.freeNotificationTimingLimit),
                String(PremiumAccessManager.maximumNotificationTimingLimit)
            )
        case .ocrQuota:
            return L10n.format(
                "無料版ではOCRは1日%@回までです。有料版では回数制限なく使えます。",
                String(PremiumAccessManager.dailyUsageLimit)
            )
        case .barcodeQuota:
            return L10n.format(
                "無料版ではバーコード検索は1日%@回までです。有料版では回数制限なく使えます。",
                String(PremiumAccessManager.dailyUsageLimit)
            )
        }
    }
}

struct PremiumProductInfo: Equatable {
    let id: String
    let displayName: String
    let description: String
    let displayPrice: String
}

struct PremiumPaywallPresentation: Identifiable {
    let id = UUID()
    let entryPoint: PremiumEntryPoint?
    let onUnlocked: (@MainActor () -> Void)?
}

enum PremiumPurchaseAction: Equatable {
    case purchased
    case userCancelled
    case pending
}

enum PremiumPurchaseError: LocalizedError {
    case productUnavailable
    case failedVerification

    var errorDescription: String? {
        switch self {
        case .productUnavailable:
            return L10n.string("有料プランの商品情報を取得できませんでした。")
        case .failedVerification:
            return L10n.string("購入の確認に失敗しました。")
        }
    }
}

@MainActor
protocol PremiumPurchaseControlling: AnyObject {
    var transactionUpdates: AsyncStream<Void> { get }
    func loadProduct() async throws -> PremiumProductInfo?
    func currentEntitlementIsActive() async -> Bool
    func purchaseProduct() async throws -> PremiumPurchaseAction
    func restorePurchases() async throws -> Bool
}

@MainActor
struct PremiumOverrideConfig {
    let debugOverrideEnabled: Bool
    let internalPremiumEnabled: Bool
    let isTestFlightBuild: Bool

    var grantsPremiumAccess: Bool {
        debugOverrideEnabled || (internalPremiumEnabled && isTestFlightBuild)
    }

    static func live(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> PremiumOverrideConfig {
        #if DEBUG
        let debugOverrideEnabled = environment["DISABLE_DEBUG_PREMIUM_OVERRIDE"] != "1"
        #else
        let debugOverrideEnabled = false
        #endif

        let internalPremiumEnabled =
            (bundle.object(forInfoDictionaryKey: "InternalPremiumEnabled") as? Bool)
            ?? false
        let isTestFlightBuild = bundle.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"

        return PremiumOverrideConfig(
            debugOverrideEnabled: debugOverrideEnabled,
            internalPremiumEnabled: internalPremiumEnabled,
            isTestFlightBuild: isTestFlightBuild
        )
    }

    static let disabled = PremiumOverrideConfig(
        debugOverrideEnabled: false,
        internalPremiumEnabled: false,
        isTestFlightBuild: false
    )
}

final class PremiumDailyQuotaStore {
    enum Kind: String {
        case ocr
        case barcode
    }

    private let defaults: UserDefaults
    private let nowProvider: () -> Date
    private let calendarProvider: () -> Calendar
    private let dailyLimit: Int

    init(
        defaults: UserDefaults = .standard,
        dailyLimit: Int = 10,
        nowProvider: @escaping () -> Date = Date.init,
        calendarProvider: @escaping () -> Calendar = { .autoupdatingCurrent }
    ) {
        self.defaults = defaults
        self.dailyLimit = dailyLimit
        self.nowProvider = nowProvider
        self.calendarProvider = calendarProvider
    }

    func remainingQuota(for kind: Kind, isPremium: Bool) -> Int? {
        guard !isPremium else { return nil }
        let state = normalizedState(for: kind)
        return max(0, dailyLimit - state.count)
    }

    func canUseQuota(for kind: Kind, isPremium: Bool) -> Bool {
        guard !isPremium else { return true }
        return (remainingQuota(for: kind, isPremium: false) ?? 0) > 0
    }

    @discardableResult
    func recordUsageIfNeeded(for kind: Kind, isPremium: Bool) -> Bool {
        guard !isPremium else { return true }

        var state = normalizedState(for: kind)
        guard state.count < dailyLimit else { return false }

        state.count += 1
        persist(state, for: kind)
        return true
    }

    private struct State {
        var dayIdentifier: String
        var count: Int
    }

    private func normalizedState(for kind: Kind) -> State {
        let today = currentDayIdentifier()
        let dateKey = storageKey(for: kind, suffix: "day")
        let countKey = storageKey(for: kind, suffix: "count")

        let storedDayIdentifier = defaults.string(forKey: dateKey) ?? today
        if storedDayIdentifier != today {
            let resetState = State(dayIdentifier: today, count: 0)
            persist(resetState, for: kind)
            return resetState
        }

        return State(
            dayIdentifier: storedDayIdentifier,
            count: defaults.integer(forKey: countKey)
        )
    }

    private func persist(_ state: State, for kind: Kind) {
        defaults.set(state.dayIdentifier, forKey: storageKey(for: kind, suffix: "day"))
        defaults.set(state.count, forKey: storageKey(for: kind, suffix: "count"))
    }

    private func storageKey(for kind: Kind, suffix: String) -> String {
        "premium.quota.\(kind.rawValue).\(suffix)"
    }

    private func currentDayIdentifier() -> String {
        let calendar = calendarProvider()
        let startOfDay = calendar.startOfDay(for: nowProvider())
        return String(Int(startOfDay.timeIntervalSinceReferenceDate))
    }
}

@MainActor
final class StoreKitPremiumPurchaseController: PremiumPurchaseControlling {
    private let productID: String
    private var cachedProduct: Product?

    init(productID: String) {
        self.productID = productID
    }

    var transactionUpdates: AsyncStream<Void> {
        AsyncStream { continuation in
            let task = Task {
                for await result in Transaction.updates {
                    guard case .verified(let transaction) = result,
                          transaction.productID == productID else {
                        continue
                    }

                    await transaction.finish()
                    continuation.yield(())
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func loadProduct() async throws -> PremiumProductInfo? {
        guard let product = try await fetchProduct() else { return nil }
        return PremiumProductInfo(
            id: product.id,
            displayName: product.displayName,
            description: product.description,
            displayPrice: product.displayPrice
        )
    }

    func currentEntitlementIsActive() async -> Bool {
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            guard transaction.productID == productID,
                  transaction.revocationDate == nil else {
                continue
            }
            return true
        }
        return false
    }

    func purchaseProduct() async throws -> PremiumPurchaseAction {
        guard let product = try await fetchProduct() else {
            throw PremiumPurchaseError.productUnavailable
        }

        switch try await product.purchase() {
        case .success(let verification):
            let transaction = try verifiedPayload(from: verification)
            await transaction.finish()
            return .purchased
        case .userCancelled:
            return .userCancelled
        case .pending:
            return .pending
        @unknown default:
            return .pending
        }
    }

    func restorePurchases() async throws -> Bool {
        try await AppStore.sync()
        return await currentEntitlementIsActive()
    }

    private func fetchProduct() async throws -> Product? {
        if let cachedProduct {
            return cachedProduct
        }

        let products = try await Product.products(for: [productID])
        let product = products.first
        cachedProduct = product
        return product
    }

    private func verifiedPayload<T>(from result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let payload):
            return payload
        case .unverified(_, _):
            throw PremiumPurchaseError.failedVerification
        }
    }
}

@MainActor
@Observable
final class PremiumAccessManager {
    static let shared = PremiumAccessManager()
    private static let allFeaturesFree = true

    nonisolated static let productID = "com.stockpile-manager.app.premium.lifetime"
    nonisolated static let freeBagLimit = 2
    nonisolated static let freeNotificationTimingLimit = 1
    nonisolated static let maximumNotificationTimingLimit = 5
    nonisolated static let dailyUsageLimit = 10

    private let controller: PremiumPurchaseControlling
    private let quotaStore: PremiumDailyQuotaStore
    private let overrideConfig: PremiumOverrideConfig
    private var updatesTask: Task<Void, Never>?

    private(set) var purchaseState: PurchaseState = .loading
    private(set) var productInfo: PremiumProductInfo?
    private(set) var hasPremiumAccess = false
    private(set) var remainingOCRQuota: Int?
    private(set) var remainingBarcodeQuota: Int?
    var presentedPaywall: PremiumPaywallPresentation?

    init(
        controller: PremiumPurchaseControlling? = nil,
        quotaStore: PremiumDailyQuotaStore? = nil,
        overrideConfig: PremiumOverrideConfig? = nil
    ) {
        let resolvedOverrideConfig = overrideConfig ?? .live()
        self.controller = controller ?? StoreKitPremiumPurchaseController(productID: Self.productID)
        self.quotaStore = quotaStore ?? PremiumDailyQuotaStore()
        self.overrideConfig = resolvedOverrideConfig
        self.hasPremiumAccess = Self.allFeaturesFree || resolvedOverrideConfig.grantsPremiumAccess
        self.purchaseState = Self.allFeaturesFree ? .free : (resolvedOverrideConfig.grantsPremiumAccess ? .premium : .loading)
        refreshUsageState()
        startObservingTransactions()

        Task { [weak self] in
            await self?.refresh()
        }
    }

    var planStatusLabel: String {
        L10n.string("無料版")
    }

    var purchaseButtonTitle: String {
        L10n.string("無料版")
    }

    func canAddBag(currentCount: Int) -> Bool {
        true
    }

    func canAddNotificationTiming(currentCount: Int) -> Bool {
        true
    }

    func canUseOCR() -> Bool {
        true
    }

    func canUseBarcodeSearch() -> Bool {
        true
    }

    @discardableResult
    func recordOCRUsageIfNeeded() -> Bool {
        refreshUsageState()
        return true
    }

    @discardableResult
    func recordBarcodeUsageIfNeeded() -> Bool {
        refreshUsageState()
        return true
    }

    func refreshUsageState() {
        if Self.allFeaturesFree {
            remainingOCRQuota = nil
            remainingBarcodeQuota = nil
            return
        }

        remainingOCRQuota = quotaStore.remainingQuota(for: .ocr, isPremium: hasPremiumAccess)
        remainingBarcodeQuota = quotaStore.remainingQuota(for: .barcode, isPremium: hasPremiumAccess)
    }

    func refresh() async {
        if Self.allFeaturesFree {
            productInfo = nil
            hasPremiumAccess = true
            purchaseState = .free
            refreshUsageState()
            return
        }

        let loadedProductInfo = try? await controller.loadProduct()
        if let loadedProductInfo {
            productInfo = loadedProductInfo
        }

        let isEntitled: Bool
        if overrideConfig.grantsPremiumAccess {
            isEntitled = true
        } else {
            isEntitled = await controller.currentEntitlementIsActive()
        }
        hasPremiumAccess = isEntitled
        purchaseState = isEntitled ? .premium : .free
        refreshUsageState()
    }

    func presentPaywall(
        for entryPoint: PremiumEntryPoint? = nil,
        onUnlocked: (@MainActor () -> Void)? = nil
    ) {
        guard !Self.allFeaturesFree else {
            onUnlocked?()
            return
        }

        if hasPremiumAccess {
            onUnlocked?()
            return
        }

        presentedPaywall = PremiumPaywallPresentation(
            entryPoint: entryPoint,
            onUnlocked: onUnlocked
        )
    }

    func presentPlanOverview() {
        guard !Self.allFeaturesFree else { return }
        presentedPaywall = PremiumPaywallPresentation(
            entryPoint: nil,
            onUnlocked: nil
        )
    }

    func dismissPaywall() {
        presentedPaywall = nil
    }

    func purchasePremium() async {
        guard !Self.allFeaturesFree else { return }
        if hasPremiumAccess {
            continueUnlockFlowIfNeeded()
            return
        }

        purchaseState = .purchaseInProgress

        do {
            let result = try await controller.purchaseProduct()
            switch result {
            case .purchased:
                await refresh()
                continueUnlockFlowIfNeeded()
            case .userCancelled:
                await refresh()
            case .pending:
                purchaseState = .error(L10n.string("購入処理は保留中です。承認後に自動で反映されます。"))
                refreshUsageState()
            }
        } catch {
            purchaseState = .error(
                L10n.format("購入に失敗しました: %@", error.localizedDescription)
            )
            refreshUsageState()
        }
    }

    func restorePurchases() async {
        guard !Self.allFeaturesFree else { return }
        purchaseState = .purchaseInProgress

        do {
            _ = try await controller.restorePurchases()
            await refresh()
            if hasPremiumAccess {
                continueUnlockFlowIfNeeded()
            }
        } catch {
            purchaseState = .error(
                L10n.format("購入に失敗しました: %@", error.localizedDescription)
            )
            refreshUsageState()
        }
    }

    private func startObservingTransactions() {
        guard !Self.allFeaturesFree else {
            updatesTask?.cancel()
            updatesTask = nil
            return
        }

        updatesTask?.cancel()
        updatesTask = Task { [weak self] in
            guard let self else { return }
            for await _ in controller.transactionUpdates {
                await refresh()
            }
        }
    }

    private func continueUnlockFlowIfNeeded() {
        let continuation = presentedPaywall?.onUnlocked
        presentedPaywall = nil

        guard let continuation else { return }
        DispatchQueue.main.async {
            continuation()
        }
    }
}
