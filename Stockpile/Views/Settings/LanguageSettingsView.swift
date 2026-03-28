import SwiftUI

struct LanguageSettingsView: View {
    @AppStorage(AppLanguage.storageKey)
    private var selectedLanguageRawValue = AppLanguage.system.rawValue

    private var selectedLanguage: AppLanguage {
        get { AppLanguage(rawValue: selectedLanguageRawValue) ?? .system }
        nonmutating set { selectedLanguageRawValue = newValue.rawValue }
    }

    var body: some View {
        List {
            Section {
                ForEach(AppLanguage.allCases) { language in
                    Button {
                        selectedLanguage = language
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
    }
}

#Preview {
    NavigationStack {
        LanguageSettingsView()
    }
}
