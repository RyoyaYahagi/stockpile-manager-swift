import SwiftUI
import SwiftData

/// 家族セットアップ画面
struct FamilySetupView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(Router.self) private var router
    
    @State private var familyName = ""
    @State private var errorMessage: String?
    @State private var isCreating = false
    
    private var isValid: Bool {
        !familyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isSubmitting: Bool {
        isCreating
    }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("家族")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .foregroundStyle(AppTheme.ink)
                    .accessibilityAddTraits(.isHeader)

                introCard
                    .padding(.top, 20)
                    .riseIn()

                SectionHeading(title: "家族名")
                    .padding(.top, 28)
                    .padding(.bottom, 12)

                createFamilyCard
                    .tutorialTarget(.familyAction)
                    .riseIn(index: 1)

                if let error = errorMessage {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(AppTheme.color(for: .imminent))
                        Text(error)
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.color(for: .expired))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardSurface()
                    .padding(.top, 12)
                }

                Button(action: submit) {
                    if isSubmitting {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                    } else {
                        Label("家族を作成", systemImage: "plus")
                    }
                }
                .buttonStyle(PrimaryActionButtonStyle())
                .disabled(!isValid || isSubmitting)
                .opacity(isValid && !isSubmitting ? 1 : 0.5)
                .padding(.top, 16)
                .riseIn(index: 2)

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "envelope.open")
                        .foregroundStyle(AppTheme.accentInk)
                        .accessibilityHidden(true)
                    Text("招待を受けた方は、届いた共有リンクを開くと参加できます。")
                        .font(.footnote)
                        .foregroundStyle(AppTheme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardSurface()
                .padding(.top, 28)
                .riseIn(index: 3)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .appScreenBackground()
        .tint(AppTheme.accent)
        .toolbar(.hidden, for: .navigationBar)
        .scrollDismissesKeyboard(.interactively)
        .localizedRefresh()
    }

    private var introCard: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "person.3.sequence")
                .font(.title2)
                .foregroundStyle(AppTheme.accentInk)
                .frame(width: 44, height: 44)
                .background(AppTheme.accentSoft, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text("家族共有はiCloud共有リンクで行われます")
                    .font(.body.weight(.bold))
                    .foregroundStyle(AppTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text("家族を作成したあと、設定画面から共有リンクを送れます。参加側はそのリンクを開くと共有を受理できます。")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private var createFamilyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("家族名", text: $familyName)
                .frame(minHeight: 44)
                .submitLabel(.done)
            Text("家族グループの名前を入力してください（例: 山田家）")
                .font(.footnote)
                .foregroundStyle(AppTheme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 4)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private func submit() {
        Task {
            await createFamily()
        }
    }
    
    private func createFamily() async {
        isCreating = true
        defer { isCreating = false }

        let trimmedName = familyName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        let family = Family(name: trimmedName)
        family.markAsCurrent()
        modelContext.insert(family)
        
        do {
            try modelContext.save()
            router.pop()
            router.push(.familySettings(family))
        } catch {
            errorMessage = L10n.format("家族の作成に失敗しました: %@", error.localizedDescription)
        }
    }
}

#Preview {
    NavigationStack {
        FamilySetupView()
    }
    .environment(Router())
    .modelContainer(for: [Family.self], inMemory: true)
}
