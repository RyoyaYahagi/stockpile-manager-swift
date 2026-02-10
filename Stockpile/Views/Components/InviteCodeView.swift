import SwiftUI

/// 招待コード表示ビュー
struct InviteCodeView: View {
    @Environment(\.dismiss) private var dismiss
    
    let code: String
    
    private var qrCodeImage: UIImage? {
        QRCodeGenerator.generateInviteQR(inviteCode: code, size: CGSize(width: 200, height: 200))
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    if let qrImage = qrCodeImage {
                        Image(uiImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 200, height: 200)
                            .padding()
                            .background(Color.white)
                            .cornerRadius(16)
                            .shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 4)
                    }
                    
                    VStack(spacing: 8) {
                        Text("招待コード")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        
                        Text(code)
                            .font(.system(size: 36, weight: .bold, design: .monospaced))
                            .tracking(6)
                    }
                    
                    Text("QRコードをスキャンするか、\n6桁のコードを入力して参加できます")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    
                    ShareLink(item: "備蓄品管理アプリ「Stockpile」に参加しよう！\n招待コード: \(code)\nまたはこちらのリンクから: stockpile://join?code=\(code)") {
                        Label("招待を共有", systemImage: "square.and.arrow.up")
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
                }
                .padding(.top, 32)
                .padding(.bottom, 20)
            }
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
        .presentationDetents([.large])
    }
}

#Preview {
    InviteCodeView(code: "ABC123")
}
