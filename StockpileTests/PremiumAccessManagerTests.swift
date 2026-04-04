import XCTest
@testable import Stockpile

@MainActor
final class PremiumAccessManagerTests: XCTestCase {
    private var defaultsSuiteName: String!
    private var userDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaultsSuiteName = "PremiumAccessManagerTests.\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: defaultsSuiteName)
        userDefaults.removePersistentDomain(forName: defaultsSuiteName)
    }

    override func tearDown() {
        userDefaults.removePersistentDomain(forName: defaultsSuiteName)
        userDefaults = nil
        defaultsSuiteName = nil
        super.tearDown()
    }

    func testAllUsersHaveUnlimitedAccessWhenEverythingIsFree() async {
        let controller = FakePremiumPurchaseController(entitlementActive: false)
        let manager = makeManager(
            controller: controller,
            now: Date(timeIntervalSinceReferenceDate: 0)
        )

        await manager.refresh()

        XCTAssertEqual(manager.purchaseState, .free)
        XCTAssertTrue(manager.hasPremiumAccess)
        XCTAssertTrue(manager.canAddBag(currentCount: 0))
        XCTAssertTrue(manager.canAddBag(currentCount: PremiumAccessManager.freeBagLimit))
        XCTAssertTrue(manager.canAddBag(currentCount: 999))
        XCTAssertTrue(manager.canAddNotificationTiming(currentCount: 0))
        XCTAssertTrue(manager.canAddNotificationTiming(currentCount: NotificationSettings.freeTimingRulesLimit))
    }

    func testRemainingQuotasStayHiddenWhenEverythingIsFree() async {
        let controller = FakePremiumPurchaseController(entitlementActive: true)
        let manager = makeManager(
            controller: controller,
            now: Date(timeIntervalSinceReferenceDate: 0)
        )

        await manager.refresh()

        XCTAssertEqual(manager.purchaseState, .free)
        XCTAssertTrue(manager.hasPremiumAccess)
        XCTAssertTrue(manager.canUseOCR())
        XCTAssertTrue(manager.canUseBarcodeSearch())
        XCTAssertNil(manager.remainingOCRQuota)
        XCTAssertNil(manager.remainingBarcodeQuota)
        XCTAssertTrue(manager.recordOCRUsageIfNeeded())
        XCTAssertTrue(manager.recordBarcodeUsageIfNeeded())
        XCTAssertNil(manager.remainingOCRQuota)
        XCTAssertNil(manager.remainingBarcodeQuota)
    }

    func testPurchasePremiumDoesNothingWhenEverythingIsFree() async {
        let controller = FakePremiumPurchaseController(entitlementActive: false)
        controller.purchaseResult = .purchased
        let manager = makeManager(
            controller: controller,
            now: Date(timeIntervalSinceReferenceDate: 0)
        )

        await manager.refresh()
        await manager.purchasePremium()

        XCTAssertFalse(controller.purchaseCalled)
        XCTAssertTrue(manager.hasPremiumAccess)
        XCTAssertEqual(manager.purchaseState, .free)
    }

    func testRestorePurchasesDoesNothingWhenEverythingIsFree() async {
        let controller = FakePremiumPurchaseController(entitlementActive: false)
        controller.restoreResult = true
        let manager = makeManager(
            controller: controller,
            now: Date(timeIntervalSinceReferenceDate: 0)
        )

        await manager.refresh()
        await manager.restorePurchases()

        XCTAssertFalse(controller.restoreCalled)
        XCTAssertTrue(manager.hasPremiumAccess)
        XCTAssertEqual(manager.purchaseState, .free)
    }

    func testInternalOverrideGrantsPremiumWithoutEntitlement() async {
        let controller = FakePremiumPurchaseController(entitlementActive: false)
        let manager = PremiumAccessManager(
            controller: controller,
            quotaStore: PremiumDailyQuotaStore(
                defaults: userDefaults,
                nowProvider: { Date(timeIntervalSinceReferenceDate: 0) },
                calendarProvider: {
                    var calendar = Calendar(identifier: .gregorian)
                    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
                    return calendar
                }
            ),
            overrideConfig: PremiumOverrideConfig(
                debugOverrideEnabled: false,
                internalPremiumEnabled: true,
                isTestFlightBuild: true
            )
        )

        await manager.refresh()

        XCTAssertTrue(manager.hasPremiumAccess)
        XCTAssertEqual(manager.purchaseState, .free)
    }

    func testLiveOverrideCanDisableDebugPremiumForAutomation() {
        let overrideConfig = PremiumOverrideConfig.live(
            bundle: .main,
            environment: ["DISABLE_DEBUG_PREMIUM_OVERRIDE": "1"]
        )

        XCTAssertFalse(overrideConfig.debugOverrideEnabled)
        XCTAssertFalse(overrideConfig.grantsPremiumAccess)
    }

    func testNotificationDefaultsRespectPremiumState() {
        let freeSettings = NotificationSettings.createDefault(isPremium: false)
        XCTAssertEqual(
            freeSettings.notificationTimingRules,
            [NotificationTimingRule(amount: 0, unit: .day)]
        )

        let premiumSettings = NotificationSettings.createDefault(isPremium: true)
        XCTAssertEqual(
            premiumSettings.notificationTimingRules,
            [
                NotificationTimingRule(amount: 0, unit: .day),
                NotificationTimingRule(amount: 1, unit: .week),
                NotificationTimingRule(amount: 1, unit: .month)
            ]
        )
    }

    private func makeManager(
        controller: FakePremiumPurchaseController,
        now: Date
    ) -> PremiumAccessManager {
        makeManager(controller: controller, clock: TestClock(date: now))
    }

    private func makeManager(
        controller: FakePremiumPurchaseController,
        clock: TestClock
    ) -> PremiumAccessManager {
        PremiumAccessManager(
            controller: controller,
            quotaStore: PremiumDailyQuotaStore(
                defaults: userDefaults,
                nowProvider: { clock.date },
                calendarProvider: {
                    var calendar = Calendar(identifier: .gregorian)
                    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
                    return calendar
                }
            ),
            overrideConfig: .disabled
        )
    }
}

@MainActor
private final class FakePremiumPurchaseController: PremiumPurchaseControlling {
    var entitlementActive: Bool
    var purchaseResult: PremiumPurchaseAction = .userCancelled
    var restoreResult = false
    var purchaseCalled = false
    var restoreCalled = false

    init(entitlementActive: Bool) {
        self.entitlementActive = entitlementActive
    }

    var transactionUpdates: AsyncStream<Void> {
        AsyncStream { _ in }
    }

    func loadProduct() async throws -> PremiumProductInfo? {
        PremiumProductInfo(
            id: PremiumAccessManager.productID,
            displayName: "Stockpile Premium",
            description: "Unlocks all premium features.",
            displayPrice: "¥300"
        )
    }

    func currentEntitlementIsActive() async -> Bool {
        entitlementActive
    }

    func purchaseProduct() async throws -> PremiumPurchaseAction {
        purchaseCalled = true
        if purchaseResult == .purchased {
            entitlementActive = true
        }
        return purchaseResult
    }

    func restorePurchases() async throws -> Bool {
        restoreCalled = true
        if restoreResult {
            entitlementActive = true
        }
        return restoreResult
    }
}

private final class TestClock {
    var date: Date

    init(date: Date) {
        self.date = date
    }
}
