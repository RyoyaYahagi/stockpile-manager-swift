import SwiftUI

/// ＋ボタンから開く「どうやって追加しますか？」
struct AddMethodSheet: View {
    @Environment(Router.self) private var router
    @Environment(PremiumAccessManager.self) private var premiumAccessManager

    let bagId: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("どうやって追加しますか？")
                .font(.system(.title2, design: .rounded, weight: .bold))
                .foregroundStyle(AppTheme.ink)
            Text("読み取ると、品名や賞味期限が自動で入ります。")
                .font(.subheadline)
                .foregroundStyle(AppTheme.inkSecondary)
                .padding(.top, 4)

            VStack(spacing: 10) {
                option(
                    title: "バーコードを読み取る",
                    detail: barcodeDetail,
                    symbol: "barcode.viewfinder",
                    tint: AppTheme.accent,
                    isRecommended: true,
                    index: 0
                ) {
                    router.present(.scanBarcode(bagId: bagId))
                }
                option(
                    title: "賞味期限を撮影する",
                    detail: ocrDetail,
                    symbol: "camera",
                    tint: AppTheme.color(for: .imminent),
                    isRecommended: false,
                    index: 1
                ) {
                    openExpiryScanner()
                }
                option(
                    title: "手で入力する",
                    detail: L10n.string("読み取れないものはこちら"),
                    symbol: "pencil",
                    tint: AppTheme.ink,
                    isRecommended: false,
                    index: 2
                ) {
                    router.present(.addItem(bagId: bagId))
                }
            }
            .padding(.top, 20)
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .localizedRefresh()
    }

    private func openExpiryScanner() {
        if premiumAccessManager.canUseOCR() {
            router.present(.scanExpiry(bagId: bagId))
            return
        }
        premiumAccessManager.presentPaywall(for: .ocrQuota) {
            router.present(.scanExpiry(bagId: bagId))
        }
    }

    private var barcodeDetail: String {
        if let remaining = premiumAccessManager.remainingBarcodeQuota {
            return L10n.format("無料版はあと%@回バーコード検索できます。", String(remaining))
        }
        return L10n.string("品名を自動で入れます")
    }

    private var ocrDetail: String {
        if let remaining = premiumAccessManager.remainingOCRQuota {
            return L10n.format("無料版はあと%@回OCRを使えます。", String(remaining))
        }
        return L10n.string("パッケージの日付を読み取ります")
    }

    private func option(
        title: LocalizedStringKey,
        detail: String,
        symbol: String,
        tint: Color,
        isRecommended: Bool,
        index: Int,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 48, height: 48)
                    .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    if isRecommended {
                        Text("おすすめ")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(AppTheme.accentInk)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(AppTheme.accentSoft, in: Capsule())
                    }
                    Text(title)
                        .font(.body.weight(.bold))
                        .foregroundStyle(AppTheme.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(AppTheme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppTheme.inkSecondary)
            }
            .padding(16)
            .cardSurface(radius: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .riseIn(index: index)
    }
}
