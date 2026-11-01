import SwiftUI
import SwiftData

/// ホーム: 備えの安心度と、いま対応が必要な備蓄
struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(Router.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Query(sort: \Item.expiryDate) private var items: [Item]
    @Query private var bags: [Bag]
    @Query(sort: \Family.createdAt, order: .reverse) private var families: [Family]

    @State private var displayedPercent = 0
    @AppStorage(BagOrderStore.revisionKey) private var bagOrderRevision = 0
    @State private var toastMessage: String?
    @State private var toastToken = UUID()

    private var currentFamily: Family? {
        CurrentFamilyResolver.currentFamily(from: families)
    }

    private var scopedItems: [Item] {
        InventoryStore.scopedItems(items, family: currentFamily)
    }

    private var scopedBags: [Bag] {
        _ = bagOrderRevision
        return BagOrderStore.sorted(InventoryStore.scopedBags(bags, family: currentFamily), family: currentFamily)
    }

    var body: some View {
        let items = scopedItems
        let attention = InventoryStore.attentionItems(in: items)
        let readiness = InventoryStore.readinessPercent(of: items)

        TutorialScrollReader {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header

                if items.isEmpty {
                    emptyState
                        .padding(.top, 20)
                } else {
                    readinessCard(items: items, attentionCount: attention.count)
                        .tutorialTarget(.homeReadiness)
                        .padding(.top, 20)
                        .riseIn()

                    SectionHeading(title: "いま対応が必要", count: attention.count)
                        .tutorialTarget(.homeAttention, isEnabled: !attention.isEmpty, scrollID: true)
                        .padding(.top, 28)
                        .padding(.bottom, 12)

                    if attention.isEmpty {
                        allClearCard
                            .riseIn(index: 1)
                    } else {
                        LazyVStack(spacing: 12) {
                            ForEach(Array(attention.enumerated()), id: \.element.id) { index, item in
                                AttentionCard(
                                    item: item,
                                    onOpen: { router.push(.itemDetail(item)) },
                                    onUseOne: { useOne(item) },
                                    onRenew: { router.present(.renewItem(item)) }
                                )
                                .tutorialTarget(.homeAttention, isEnabled: index == 0)
                                .riseIn(index: index + 1)
                            }
                        }
                    }
                }

                if !scopedBags.isEmpty || !items.isEmpty {
                    SectionHeading(title: "収納場所")
                        .padding(.top, 28)
                        .padding(.bottom, 12)
                    bagGrid(items: items)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        }
        .appScreenBackground()
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .bottom) {
            if let toastMessage {
                ToastView(message: toastMessage)
                    .padding(.bottom, 100)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .task(id: toastToken) {
            guard toastMessage != nil else { return }
            try? await Task.sleep(for: .seconds(2.4))
            withAnimation(AppTheme.popAnimation) { toastMessage = nil }
        }
        .onAppear { animatePercent(to: readiness) }
        .onChange(of: readiness) { _, newValue in animatePercent(to: newValue) }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text(Date.now, format: .dateTime.month().day().weekday(.abbreviated))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AppTheme.inkSecondary)
                Text("わが家の備え")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .foregroundStyle(AppTheme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 12)
            if currentFamily != nil {
                Button {
                    router.select(.family)
                } label: {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(AppTheme.accentInk)
                        .frame(width: 48, height: 48)
                        .contentShape(Circle())
                }
                .buttonStyle(PressableButtonStyle(scale: 0.92))
                .glassSurface(in: Circle(), interactive: true)
                .accessibilityLabel(Text("家族"))
            }
        }
        .padding(.top, 12)
    }

    private func readinessCard(items: [Item], attentionCount: Int) -> some View {
        let readyCount = items.count - attentionCount
        return HStack(spacing: 20) {
            ReadinessRing(percent: displayedPercent)
                .frame(width: 116, height: 116)

            VStack(alignment: .leading, spacing: 6) {
                Text("期限に余裕がある備蓄")
                    .font(.headline)
                    .foregroundStyle(AppTheme.ink)
                Text(L10n.format("%@品目のうち %@品目", String(items.count), String(readyCount)))
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.inkSecondary)
                Text(
                    attentionCount > 0
                        ? L10n.format("期限が近い%@品を入れ替えると、安心度が上がります。", String(attentionCount))
                        : L10n.string("すべての備蓄に余裕があります。")
                )
                .font(.footnote)
                .foregroundStyle(AppTheme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .cardSurface()
        .accessibilityElement(children: .combine)
    }

    private var allClearCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "checkmark")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(AppTheme.accentInk)
                .frame(width: 44, height: 44)
                .background(AppTheme.accentSoft, in: Circle())
            Text("対応が必要な備蓄はありません。")
                .font(.subheadline)
                .foregroundStyle(AppTheme.ink)
            Spacer(minLength: 0)
        }
        .padding(20)
        .cardSurface()
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "shippingbox")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(AppTheme.accentInk)
                .frame(width: 56, height: 56)
                .background(AppTheme.accentSoft, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            Text("備蓄品がありません")
                .font(.headline)
                .foregroundStyle(AppTheme.ink)
            Text("右下の＋から、1件登録してみましょう")
                .font(.subheadline)
                .foregroundStyle(AppTheme.inkSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .cardSurface()
    }

    private func bagGrid(items: [Item]) -> some View {
        let columns = [GridItem(.adaptive(minimum: 100), spacing: 10)]
        var entries: [(id: UUID?, name: String, items: [Item])] = scopedBags.map { bag in
            (bag.id, bag.name, items.filter { $0.bag?.id == bag.id })
        }
        let unassigned = items.filter { $0.bag == nil }
        if !unassigned.isEmpty {
            entries.append((nil, L10n.string("未分類"), unassigned))
        }

        return LazyVGrid(columns: columns, spacing: 10) {
            ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                Button {
                    router.showStock(focusing: entry.id)
                } label: {
                    BagTile(name: entry.name, items: entry.items, isUnassigned: entry.id == nil)
                }
                .buttonStyle(PressableButtonStyle())
                .riseIn(index: index + 2)
            }
        }
    }

    // MARK: - Actions

    private func useOne(_ item: Item) {
        InventoryStore.useOne(of: item)
        InventoryStore.saveAndSync(modelContext, family: currentFamily)
        showToast(L10n.format("「%@」を1つ減らしました", item.name))
    }

    private func showToast(_ message: String) {
        withAnimation(AppTheme.popAnimation) {
            toastMessage = message
        }
        toastToken = UUID()
    }

    private func animatePercent(to target: Int) {
        if reduceMotion {
            displayedPercent = target
        } else {
            withAnimation(AppTheme.countAnimation) {
                displayedPercent = target
            }
        }
    }
}

// MARK: - Components

/// 安心度リング（カウントアップ＋円形進捗）
private struct ReadinessRing: View {
    let percent: Int

    var body: some View {
        ZStack {
            Circle()
                .stroke(AppTheme.ink.opacity(0.07), lineWidth: 12)
            Circle()
                .trim(from: 0, to: CGFloat(percent) / 100)
                .stroke(AppTheme.accent, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(percent)")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(percent)))
                    Text("%")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                }
                .foregroundStyle(AppTheme.ink)
                Text("安心度")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.inkSecondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("安心度"))
        .accessibilityValue(Text("\(percent)%"))
    }
}

/// いま対応が必要な備蓄のカード
private struct AttentionCard: View {
    let item: Item
    let onOpen: () -> Void
    let onUseOne: () -> Void
    let onRenew: () -> Void

    @State private var bounceTrigger = false

    var body: some View {
        let status = item.expiryStatus
        VStack(spacing: 14) {
            Button(action: onOpen) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: AppTheme.symbol(for: status))
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(AppTheme.color(for: status))
                        .frame(width: 44, height: 44)
                        .background(AppTheme.softColor(for: status), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .symbolEffect(.bounce, value: bounceTrigger)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 4) {
                            Text(item.name)
                                .font(.body.weight(.bold))
                                .foregroundStyle(AppTheme.ink)
                                .lineLimit(1)
                            Text(L10n.format("×%@", String(item.quantity)))
                                .font(.subheadline)
                                .foregroundStyle(AppTheme.inkSecondary)
                        }
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(AppTheme.inkSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    StatusPill(text: item.expiryDisplayText, status: status)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle(scale: 0.98))

            HStack(spacing: 8) {
                Button("1つ使った", action: onUseOne)
                    .buttonStyle(SecondaryActionButtonStyle())
                    .disabled(item.quantity == 0)
                Button(action: onRenew) {
                    Label("入れ替えた", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(PrimaryActionButtonStyle())
            }
        }
        .padding(16)
        .cardSurface()
        .onAppear {
            if status == .expired {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                    bounceTrigger.toggle()
                }
            }
        }
    }

    private var subtitle: String {
        let place = item.bag?.name ?? L10n.string("未分類")
        guard let date = item.expiryDate else { return place }
        return "\(place) ・ \(date.formatted(date: .abbreviated, time: .omitted))"
    }
}

/// 収納場所のタイル
private struct BagTile: View {
    let name: String
    let items: [Item]
    let isUnassigned: Bool

    var body: some View {
        let worst = items.map(\.expiryStatus).min()
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: isUnassigned ? "tray" : "bag")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppTheme.ink)
                .frame(width: 34, height: 34)
                .background(AppTheme.softFill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            Spacer(minLength: 0)
            Text(name)
                .font(.footnote.weight(.bold))
                .foregroundStyle(AppTheme.ink)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            HStack(spacing: 5) {
                Circle()
                    .fill(worst.map { AppTheme.color(for: $0) } ?? AppTheme.inkSecondary.opacity(0.5))
                    .frame(width: 8, height: 8)
                Text(L10n.format("%@品目", String(items.count)))
                    .font(.caption)
                    .foregroundStyle(AppTheme.inkSecondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
        .padding(14)
        .cardSurface(radius: 20)
        .accessibilityElement(children: .combine)
    }
}
