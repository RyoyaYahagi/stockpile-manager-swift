import UIKit
import CoreImage.CIFilterBuiltins

/// QRコード生成ユーティリティ
enum QRCodeGenerator {
    /// 文字列からQRコード画像を生成
    /// - Parameters:
    ///   - string: QRコードに埋め込む文字列
    ///   - size: 生成する画像のサイズ
    /// - Returns: QRコード画像（生成失敗時はnil）
    static func generate(from string: String, size: CGSize = CGSize(width: 200, height: 200)) -> UIImage? {
        guard let data = string.data(using: .utf8) else { return nil }
        
        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "M" // エラー訂正レベル: L, M, Q, H
        
        guard let ciImage = filter.outputImage else { return nil }
        
        // スケールアップ（QRコードは小さく生成されるため）
        let scaleX = size.width / ciImage.extent.width
        let scaleY = size.height / ciImage.extent.height
        let scaledImage = ciImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else { return nil }
        
        return UIImage(cgImage: cgImage)
    }
    
    /// 招待URL用のQRコードを生成
    /// - Parameter inviteCode: 招待コード
    /// - Returns: QRコード画像
    static func generateInviteQR(inviteCode: String, size: CGSize = CGSize(width: 200, height: 200)) -> UIImage? {
        // カスタムURLスキームを使用
        let urlString = "stockpile://join?code=\(inviteCode)"
        return generate(from: urlString, size: size)
    }
}
