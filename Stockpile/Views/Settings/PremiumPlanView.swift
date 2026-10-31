import SwiftUI
import Observation

struct PremiumPlanView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(PremiumAccessManager.self) private var premiumAccessManager

    let presentation: PremiumPaywallPresentation

    private var entryPoint: PremiumEntryPoint? {
        presentation.entryPoint
    }

    private var headlineText: String {
        entryPoint?.headline ?? L10n.string("有料版でできること")
    }

    private var planTitleText: String {
        L10n.string("有料プラン")
    }

    private var descriptionText: String {
        entryPoint?.descriptionText
            ?? L10n.string("300円の買い切りで、収納場所・通知・OCR・バーコード検索の制限が外れます。")
    }

    private var featureTexts: [String] {
        [
            L10n.string("収納場所を無制限で追加できます"),
            L10n.format(
                "通知タイミングを最大%@件まで追加できます",
                String(PremiumAccessManager.maximumNotificationTimingLimit)
            ),
            L10n.string("OCRを何度でも使えます"),
            L10n.string("バーコード検索を何度でも使えます")
        ]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Label(planTitleText, systemImage: "crown.fill")
                        .font(.title2.bold())
                        .foregroundStyle(AppTheme.color(for: .imminent))

                    Text(headlineText)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(AppTheme.ink)

                    Text(descriptionText)
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 12) {
                    statusRow(
                        title: L10n.string("現在のプラン"),
                        value: premiumAccessManager.planStatusLabel
                    )

                    if let productInfo = premiumAccessManager.productInfo {
                        statusRow(
                            title: productInfo.displayName,
                            value: productInfo.displayPrice
                        )

                        if !productInfo.description.isEmpty {
                            Text(productInfo.description)
                                .font(.subheadline)
                                .foregroundStyle(AppTheme.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardSurface()

                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.string("有料版でできること"))
                        .font(.headline)
                        .foregroundStyle(AppTheme.ink)

                    ForEach(featureTexts, id: \.self) { text in
                        featureRow(text)
                    }
                }

                if case .error(let message) = premiumAccessManager.purchaseState {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.color(for: .expired))
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(AppTheme.softColor(for: .expired), in: RoundedRectangle(cornerRadius: 12))
                }

                VStack(spacing: 12) {
                    Button {
                        Task {
                            await premiumAccessManager.purchasePremium()
                        }
                    } label: {
                        if premiumAccessManager.purchaseState == .purchaseInProgress {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(.white)
                        } else {
                            Text(
                                premiumAccessManager.hasPremiumAccess
                                    ? L10n.string("有料版")
                                    : premiumAccessManager.purchaseButtonTitle
                            )
                        }
                    }
                    .buttonStyle(PrimaryActionButtonStyle())
                    .disabled(
                        premiumAccessManager.purchaseState == .purchaseInProgress
                            || premiumAccessManager.hasPremiumAccess
                    )

                    Button(L10n.string("購入を復元")) {
                        Task {
                            await premiumAccessManager.restorePurchases()
                        }
                    }
                    .disabled(premiumAccessManager.purchaseState == .purchaseInProgress)
                    .tint(AppTheme.accent)

                    Button(L10n.string("閉じる")) {
                        premiumAccessManager.dismissPaywall()
                        dismiss()
                    }
                    .foregroundStyle(AppTheme.inkSecondary)
                }
            }
            .padding(24)
        }
        .background { AppBackground() }
        .tint(AppTheme.accent)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .navigationTitle(planTitleText)
        .navigationBarTitleDisplayMode(.inline)
        .localizedRefresh()
    }

    @ViewBuilder
    private func featureRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(AppTheme.accent)
                .font(.body)

            Text(text)
                .font(.subheadline)
                .foregroundStyle(AppTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func statusRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(AppTheme.inkSecondary)
        }
        .font(.subheadline)
    }
}

private struct PremiumPaywallSheetModifier: ViewModifier {
    @Environment(PremiumAccessManager.self) private var premiumAccessManager

    func body(content: Content) -> some View {
        @Bindable var premiumAccessManager = premiumAccessManager

        content.sheet(item: $premiumAccessManager.presentedPaywall) { presentation in
            NavigationStack {
                PremiumPlanView(presentation: presentation)
            }
        }
    }
}

extension View {
    func premiumPaywallSheet() -> some View {
        modifier(PremiumPaywallSheetModifier())
    }
}
