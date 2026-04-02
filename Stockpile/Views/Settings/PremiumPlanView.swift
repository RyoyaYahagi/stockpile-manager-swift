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

    private var descriptionText: String {
        entryPoint?.descriptionText
            ?? L10n.string("300円の買い切りで、収納場所・通知・OCR・バーコード検索の制限が外れます。")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("有料プラン", systemImage: "crown.fill")
                        .font(.title2.bold())
                        .foregroundStyle(.orange)

                    Text(headlineText)
                        .font(.title3.weight(.semibold))

                    Text(descriptionText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
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
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding()
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))

                VStack(alignment: .leading, spacing: 12) {
                    Text("有料版でできること")
                        .font(.headline)

                    featureRow("収納場所を無制限で追加できます")
                    featureRow(
                        L10n.format(
                            "通知タイミングを最大%@件まで追加できます",
                            String(PremiumAccessManager.maximumNotificationTimingLimit)
                        )
                    )
                    featureRow("OCRを何度でも使えます")
                    featureRow("バーコード検索を何度でも使えます")
                }

                if case .error(let message) = premiumAccessManager.purchaseState {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                }

                VStack(spacing: 12) {
                    Button {
                        Task {
                            await premiumAccessManager.purchasePremium()
                        }
                    } label: {
                        HStack {
                            Spacer()
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
                                    .font(.headline)
                            }
                            Spacer()
                        }
                        .padding()
                        .background(
                            premiumAccessManager.hasPremiumAccess ? Color.green : Color.blue,
                            in: RoundedRectangle(cornerRadius: 14)
                        )
                        .foregroundStyle(.white)
                    }
                    .disabled(
                        premiumAccessManager.purchaseState == .purchaseInProgress
                            || premiumAccessManager.hasPremiumAccess
                    )

                    Button("購入を復元") {
                        Task {
                            await premiumAccessManager.restorePurchases()
                        }
                    }
                    .disabled(premiumAccessManager.purchaseState == .purchaseInProgress)

                    Button("閉じる") {
                        premiumAccessManager.dismissPaywall()
                        dismiss()
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .padding(24)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .navigationTitle("有料プラン")
        .navigationBarTitleDisplayMode(.inline)
        .localizedRefresh()
    }

    @ViewBuilder
    private func featureRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.body)

            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func statusRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
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
