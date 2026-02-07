import SwiftUI

/// 招待コード表示ビュー
struct InviteCodeView: View {
    @Environment(\.dismiss) private var dismiss
    
    let code: String
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Image(systemName: "person.3.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(.blue)
                
                VStack(spacing: 8) {
                    Text("招待コード")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    
                    Text(code)
                        .font(.system(size: 48, weight: .bold, design: .monospaced))
                        .tracking(8)
                }
                
                Text("このコードを家族に共有して、\n同じグループに参加してもらいましょう")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                
                ShareLink(item: "備蓄品管理アプリに参加しよう！招待コード: \(code)") {
                    Label("コードを共有", systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(.blue, in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 32)
                
                Button {
                    UIPasteboard.general.string = code
                } label: {
                    Label("コードをコピー", systemImage: "doc.on.doc")
                }
                
                Spacer()
            }
            .padding(.top, 60)
            .navigationTitle("招待コード")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

#Preview {
    InviteCodeView(code: "ABC123")
}
