import SwiftUI

/// 招待コード表示ビュー
struct InviteCodeView: View {
    @Environment(\.dismiss) private var dismiss

    let code: String

    private var qrCodeImage: UIImage? {
        QRCodeGenerator.generateInviteQR(inviteCode: code, size: CGSize(width: 200, height: 200))
    }

    private var shareMessage: String {
        L10n.format(
            "備蓄管理アプリ「らくストック」に参加しよう！\n招待コード: %@\nまたはこちらのリンクから: stockpile://join?code=%@",
            code,
            code
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    VStack(spacing: 20) {
                        if let qrImage = qrCodeImage {
                            Image(uiImage: qrImage)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 200, height: 200)
                                .padding(16)
                                .background(Color.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                                .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 4)
                        }

                        VStack(spacing: 8) {
                            Text("招待コード")
                                .font(.headline)
                                .foregroundStyle(AppTheme.inkSecondary)

                            Text(code)
                                .font(.system(size: 36, weight: .bold, design: .monospaced))
                                .tracking(6)
                                .foregroundStyle(AppTheme.ink)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                        }

                        Text("QRコードをスキャンするか、\n6桁のコードを入力して参加できます")
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.inkSecondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(20)
                    .cardSurface()

                    ShareLink(item: shareMessage) {
                        Label("招待を共有", systemImage: "square.and.arrow.up")
                            .font(.headline)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(PrimaryActionButtonStyle())

                    Button {
                        UIPasteboard.general.string = code
                    } label: {
                        Label("コードをコピー", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(SecondaryActionButtonStyle())
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
            .appScreenBackground()
            .tint(AppTheme.accent)
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
