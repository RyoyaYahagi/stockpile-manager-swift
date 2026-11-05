import SwiftUI

struct LanguageSettingsView: View {
    @Environment(LocalizationController.self) private var localizationController

    var body: some View {
        let selectedLanguage = localizationController.selectedLanguage

        List {
            Section {
                ForEach(AppLanguage.allCases) { language in
                    Button {
                        withAnimation(.snappy(duration: 0.18)) {
                            localizationController.selectLanguage(language)
                        }
                    } label: {
                        HStack {
                            Text(language.displayName)
                                .foregroundStyle(AppTheme.ink)
                            Spacer()
                            if selectedLanguage == language {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(AppTheme.accent)
                                    .fontWeight(.semibold)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(AppTheme.card)
                }
            } header: {
                Text("言語")
            } footer: {
                Text("変更はすぐに反映されます。日付や数値の表示も選択した言語に合わせます。")
            }
        }
        .appScreenBackground()
        .tint(AppTheme.accent)
        .navigationTitle("言語")
        .navigationBarTitleDisplayMode(.inline)
        .localizedRefresh()
    }
}

#Preview {
    NavigationStack {
        LanguageSettingsView()
    }
}
