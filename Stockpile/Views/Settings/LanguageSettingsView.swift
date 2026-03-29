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
                                .foregroundStyle(.primary)
                            Spacer()
                            if selectedLanguage == language {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.blue)
                                    .fontWeight(.semibold)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("言語")
            } footer: {
                Text("変更はすぐに反映されます。日付や数値の表示も選択した言語に合わせます。")
            }
        }
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
