import SwiftUI
@preconcurrency import AVFoundation
import Vision
import ImageIO
import CoreImage
import CoreImage.CIFilterBuiltins

/// OCRカメラビュー（賞味期限読み取り）
struct OCRCameraView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(PremiumAccessManager.self) private var premiumAccessManager
    let onDateDetected: (Date?) -> Void
    
    @State private var viewModel = OCRCameraViewModel()
    
    private var isCameraAvailable: Bool {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                if isCameraAvailable {
                    CameraView(onImageCaptured: { image in
                        processCapturedImage(image)
                    })
                    .ignoresSafeArea()
                } else {
                    // カメラ利用不可（シミュレーター等）
                    VStack(spacing: 16) {
                        Image(systemName: "camera.slash")
                            .font(.system(size: 60))
                            .foregroundStyle(.secondary)
                        Text("カメラを利用できません")
                            .font(.headline)
                        Text("実機でお試しください")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(red: 0.1, green: 0.09, blue: 0.08))
                }
                
                if isCameraAvailable {
                    // 撮影の目安になる枠（タップは下のカメラに通す）
                    VStack(spacing: 18) {
                        ScannerFrame(width: 300, height: 150, isScanning: viewModel.isProcessing)
                        Text("「賞味期限」の数字が枠に収まるように写してください")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .glassSurface(in: Capsule())
                            .padding(.horizontal, 24)
                    }
                    .allowsHitTesting(false)

                    VStack {
                        if let quotaText = ocrQuotaText {
                            Text(quotaText)
                                .font(.caption)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .glassSurface(in: Capsule())
                                .padding(.top, 16)
                        }

                        Spacer()
                        
                        // 検出結果表示
                        VStack(spacing: 12) {
                            if viewModel.isProcessing {
                                ProgressView("読み取り中...")
                                    .padding(20)
                                    .glassSurface(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                            } else if let date = viewModel.detectedDate {
                                VStack(spacing: 8) {
                                    Text("検出された日付")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(date, style: .date)
                                        .font(.title2.bold())
                                }
                                .padding(.horizontal, 28)
                                .padding(.vertical, 18)
                                .glassSurface(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                                
                                Button {
                                    onDateDetected(date)
                                    dismiss()
                                } label: {
                                    Text("この日付を使用")
                                        .font(.headline)
                                        .frame(maxWidth: .infinity, minHeight: 34)
                                }
                                .buttonStyle(PrimaryActionButtonStyle())
                                .padding(.horizontal, 20)
                            } else if !viewModel.detectedText.isEmpty {
                                VStack(spacing: 8) {
                                    Text("日付が検出できませんでした")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    Text("もう一度撮影してください")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(20)
                                .glassSurface(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                            }
                        }
                        .padding(.bottom, 20)
                    }
                }
            }
            .environment(\.colorScheme, .dark)
            .navigationTitle("賞味期限を読み取り")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") {
                        dismiss()
                    }
                }
            }
        }
        .premiumPaywallSheet()
    }

    private var ocrQuotaText: String? {
        guard let remaining = premiumAccessManager.remainingOCRQuota else { return nil }
        return L10n.format("無料版はあと%@回OCRを使えます。", String(remaining))
    }

    private func processCapturedImage(_ image: UIImage) {
        guard premiumAccessManager.canUseOCR() else {
            premiumAccessManager.presentPaywall(for: .ocrQuota)
            return
        }

        viewModel.processImage(image) {
            _ = premiumAccessManager.recordOCRUsageIfNeeded()
        }
    }
}

// MARK: - ViewModel

@Observable
@MainActor
final class OCRCameraViewModel {
    var detectedText = ""
    var detectedDate: Date?
    var isProcessing = false
    
    func processImage(_ image: UIImage, onCompleted: @escaping @MainActor () -> Void) {
        isProcessing = true
        detectedText = ""
        detectedDate = nil

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            let candidates = Self.makeOCRCandidates(from: image)
            var bestText = ""
            var bestDate: Date?

            for candidate in candidates {
                let resultText = Self.recognizeText(from: candidate)
                if bestText.isEmpty && !resultText.isEmpty {
                    bestText = resultText
                }

                if let date = Self.extractDate(from: resultText) {
                    bestText = resultText
                    bestDate = date
                    break
                }
            }
            
            // メインスレッドでUI更新
            Task { @MainActor in
                self.isProcessing = false
                self.detectedText = bestText
                self.detectedDate = bestDate
                onCompleted()
            }
        }
    }

    nonisolated private static func recognizeText(from image: UIImage) -> String {
        guard let cgImage = image.cgImage else { return "" }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ja-JP", "en-US"]
        request.usesLanguageCorrection = true
        request.customWords = ["賞味期限", "消費期限", "期限", "開封前", "EXP", "BEST", "BY", "BB"]

        let handler = VNImageRequestHandler(
            cgImage: cgImage,
            orientation: image.cgImagePropertyOrientation,
            options: [:]
        )

        do {
            try handler.perform([request])
            let observations = request.results ?? []
            return observations
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: " ")
        } catch {
            return ""
        }
    }

    nonisolated private static func makeOCRCandidates(from image: UIImage) -> [UIImage] {
        var candidates: [UIImage] = [image]

        if let cropped = cropExpiryRegion(from: image) {
            candidates.append(cropped)
            if let enhancedCropped = enhancedMonochromeImage(from: cropped) {
                candidates.append(enhancedCropped)
            }
        }

        if let enhanced = enhancedMonochromeImage(from: image) {
            candidates.append(enhanced)
        }

        return candidates
    }

    nonisolated private static func cropExpiryRegion(from image: UIImage) -> UIImage? {
        let scale = image.scale
        let size = image.size
        let rect = CGRect(
            x: size.width * 0.08,
            y: size.height * 0.14,
            width: size.width * 0.52,
            height: size.height * 0.28
        )

        let scaledRect = CGRect(
            x: rect.origin.x * scale,
            y: rect.origin.y * scale,
            width: rect.size.width * scale,
            height: rect.size.height * scale
        ).integral

        guard let cgImage = image.cgImage?.cropping(to: scaledRect) else { return nil }
        return UIImage(cgImage: cgImage, scale: scale, orientation: image.imageOrientation)
    }

    nonisolated private static func enhancedMonochromeImage(from image: UIImage) -> UIImage? {
        guard let inputImage = CIImage(image: image) else { return nil }

        let controls = CIFilter.colorControls()
        controls.inputImage = inputImage
        controls.saturation = 0
        controls.contrast = 1.8
        controls.brightness = 0.1

        guard let controlsOutput = controls.outputImage else { return nil }

        let sharpen = CIFilter.sharpenLuminance()
        sharpen.inputImage = controlsOutput
        sharpen.sharpness = 0.7

        guard let sharpened = sharpen.outputImage else { return nil }
        let ciContext = CIContext()
        guard let cgImage = ciContext.createCGImage(sharpened, from: sharpened.extent) else { return nil }
        return UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
    }
    
    /// テキストから日付を抽出
    nonisolated static func extractDate(from text: String) -> Date? {
        // テキストを正規化
        let normalizedText = normalizeText(text)
        
        // 年月日パターンで候補を探す
        var candidates: [(year: Int, month: Int, day: Int, position: Int)] = []
        candidates.append(contentsOf: findFullDates(in: normalizedText))
        
        // 年月のみパターン（日なし）で候補を探す（月末として扱う）
        candidates.append(contentsOf: findYearMonthDates(in: normalizedText))
        
        // 候補がない場合
        guard !candidates.isEmpty else { return nil }
        
        // 「賞味期限」の位置を探す
        let expiryKeywords = ["賞味期限", "消費期限", "期限", "EXP", "BB"]
        var keywordPosition: Int = Int.max
        
        for keyword in expiryKeywords {
            if let range = normalizedText.range(of: keyword, options: .caseInsensitive) {
                let pos = normalizedText.distance(from: normalizedText.startIndex, to: range.lowerBound)
                keywordPosition = min(keywordPosition, pos)
            }
        }
        
        // キーワードの後にある最も近い日付を選択
        let bestCandidate: (year: Int, month: Int, day: Int, position: Int)
        
        if keywordPosition != Int.max {
            let candidatesAfterKeyword = candidates.filter { $0.position > keywordPosition }
            if let closest = candidatesAfterKeyword.min(by: { $0.position < $1.position }) {
                bestCandidate = closest
            } else {
                bestCandidate = candidates[0]
            }
        } else {
            bestCandidate = candidates[0]
        }
        
        var components = DateComponents()
        components.year = bestCandidate.year
        components.month = bestCandidate.month
        components.day = bestCandidate.day
        
        return Calendar.current.date(from: components)
    }
    
    /// テキストの正規化
    nonisolated private static func normalizeText(_ text: String) -> String {
        var result = text
        
        // 全角数字を半角に
        let fullWidthDigits = ["０", "１", "２", "３", "４", "５", "６", "７", "８", "９"]
        let halfWidthDigits = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"]
        for (full, half) in zip(fullWidthDigits, halfWidthDigits) {
            result = result.replacingOccurrences(of: full, with: half)
        }
        
        // 改行をスペースに
        result = result.replacingOccurrences(of: "\n", with: " ")
        result = result.replacingOccurrences(of: "\r", with: " ")

        result = normalizeOCRConfusions(in: result)
        
        return result
    }

    nonisolated private static func normalizeOCRConfusions(in text: String) -> String {
        let replacements: [String: String] = [
            "O": "0", "o": "0", "D": "0", "Q": "0",
            "I": "1", "l": "1", "|": "1",
            "S": "5", "s": "5",
            "B": "8"
        ]

        return String(text.map { character in
            let scalar = String(character)
            if let replacement = replacements[scalar] {
                return Character(replacement)
            }
            return character
        })
    }
    
    /// 年月日の完全な日付を探す
    nonisolated private static func findFullDates(in text: String) -> [(year: Int, month: Int, day: Int, position: Int)] {
        var results: [(year: Int, month: Int, day: Int, position: Int)] = []
        
        let patterns: [(pattern: String, isReiwa: Bool)] = [
            // YYYYMMDD（連続8桁）
            (#"(?<!\d)(\d{4})(\d{2})(\d{2})(?!\d)"#, false),
            // YYYY MM DD（空白区切り）
            (#"(\d{4})\s+(\d{1,2})\s+(\d{1,2})"#, false),
            // YYYY. M. D（スペースあり）
            (#"(\d{4})\s*[.]\s*(\d{1,2})\s*[.]\s*(\d{1,2})"#, false),
            // YYYY-MM-DD, YYYY/MM/DD, YYYY.MM.DD
            (#"(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})"#, false),
            // YYYY年MM月DD日
            (#"(\d{4})年\s*(\d{1,2})月\s*(\d{1,2})日"#, false),
            // YY-MM-DD, YY.MM.DD
            (#"(\d{2})[-.](\d{1,2})[-.](\d{1,2})"#, false),
            // YY.MM.DD（2桁年）
            (#"(\d{2})[.]\s*(\d{1,2})[.]\s*(\d{1,2})"#, false),
            // YY/MM/DD（2桁年）
            (#"(\d{2})/(\d{1,2})/(\d{1,2})"#, false),
            // 令和YY年MM月DD日
            (#"令和\s*(\d{1,2})年\s*(\d{1,2})月\s*(\d{1,2})日"#, true),
            // R YY.MM.DD or RYY.MM.DD
            (#"[Rr]\s*(\d{1,2})[.\s]+(\d{1,2})[.\s]+(\d{1,2})"#, true),
        ]
        
        for (pattern, isReiwa) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            
            for match in matches {
                guard let yearRange = Range(match.range(at: 1), in: text),
                      let monthRange = Range(match.range(at: 2), in: text),
                      let dayRange = Range(match.range(at: 3), in: text) else {
                    continue
                }
                
                var year = Int(text[yearRange]) ?? 0
                let month = Int(text[monthRange]) ?? 0
                let day = Int(text[dayRange]) ?? 0
                
                // 令和年を西暦に変換
                if isReiwa {
                    year = year + 2018  // 令和1年 = 2019年
                } else if year < 100 {
                    year += 2000
                }
                
                // 妥当性チェック
                guard year >= 2020 && year <= 2040,
                      month >= 1 && month <= 12,
                      day >= 1 && day <= 31 else {
                    continue
                }
                
                results.append((year, month, day, match.range.location))
            }
        }
        
        return results
    }
    
    /// 年月のみの日付を探す（日は月末として扱う）
    nonisolated private static func findYearMonthDates(in text: String) -> [(year: Int, month: Int, day: Int, position: Int)] {
        var results: [(year: Int, month: Int, day: Int, position: Int)] = []
        
        let patterns: [(pattern: String, isReiwa: Bool)] = [
            // YYYYMM（連続6桁）
            (#"(?<!\d)(\d{4})(\d{2})(?!\d)"#, false),
            // YYYY年MM月（日なし）
            (#"(\d{4})年\s*(\d{1,2})月(?!\s*\d)"#, false),
            // YY年MM月（日なし）
            (#"(\d{2})年\s*(\d{1,2})月(?!\s*\d)"#, false),
            // YYYY.MM or YYYY/MM（日なし）
            (#"(\d{4})[./](\d{1,2})(?![./\d])"#, false),
            // YYYY-MM（日なし）
            (#"(\d{4})-(\d{1,2})(?![-\d])"#, false),
            // YY.MM or YY/MM（日なし）
            (#"(\d{2})[./](\d{1,2})(?![./\d])"#, false),
            // YY-MM（日なし）
            (#"(\d{2})-(\d{1,2})(?![-\d])"#, false),
            // 令和YY年MM月（日なし）
            (#"令和\s*(\d{1,2})年\s*(\d{1,2})月(?!\s*\d)"#, true),
            // R YY.MM（日なし）
            (#"[Rr]\s*(\d{1,2})[.\s]+(\d{1,2})(?![.\d])"#, true),
        ]
        
        for (pattern, isReiwa) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            
            for match in matches {
                guard let yearRange = Range(match.range(at: 1), in: text),
                      let monthRange = Range(match.range(at: 2), in: text) else {
                    continue
                }
                
                var year = Int(text[yearRange]) ?? 0
                let month = Int(text[monthRange]) ?? 0
                
                // 令和年を西暦に変換
                if isReiwa {
                    year = year + 2018
                } else if year < 100 {
                    year += 2000
                }
                
                // 妥当性チェック
                guard year >= 2020 && year <= 2040,
                      month >= 1 && month <= 12 else {
                    continue
                }
                
                // 月末日を計算
                let day = lastDayOfMonth(year: year, month: month)
                
                results.append((year, month, day, match.range.location))
            }
        }
        
        return results
    }
    
    /// 月末日を取得
    nonisolated private static func lastDayOfMonth(year: Int, month: Int) -> Int {
        var components = DateComponents()
        components.year = year
        components.month = month + 1
        components.day = 0
        
        if let date = Calendar.current.date(from: components) {
            return Calendar.current.component(.day, from: date)
        }
        
        // フォールバック
        let daysInMonth = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        if month >= 1 && month <= 12 {
            if month == 2 && isLeapYear(year) {
                return 29
            }
            return daysInMonth[month - 1]
        }
        return 28
    }
    
    /// うるう年判定
    nonisolated private static func isLeapYear(_ year: Int) -> Bool {
        return (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0)
    }
}

private extension UIImage {
    var cgImagePropertyOrientation: CGImagePropertyOrientation {
        switch imageOrientation {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}

// MARK: - Camera View (UIViewControllerRepresentable)

struct CameraView: UIViewControllerRepresentable {
    let onImageCaptured: (UIImage) -> Void
    
    func makeUIViewController(context: Context) -> CameraViewController {
        let vc = CameraViewController()
        vc.onImageCaptured = onImageCaptured
        return vc
    }
    
    func updateUIViewController(_ uiViewController: CameraViewController, context: Context) {}
}

// MARK: - Camera ViewController

@MainActor
class CameraViewController: UIViewController {
    var onImageCaptured: ((UIImage) -> Void)?
    
    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private let photoOutput = AVCapturePhotoOutput()
    private var captureButton: UIButton?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        checkCameraPermission()
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
        
        // シャッターボタンの位置更新
        if let button = captureButton {
            button.center = CGPoint(x: view.bounds.midX, y: view.bounds.height - 80)
        }
    }
    
    private func checkCameraPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setupCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.setupCamera()
                    }
                }
            }
        default:
            break
        }
    }
    
    private func setupCamera() {
        let session = AVCaptureSession()
        session.sessionPreset = .photo
        
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else {
            return
        }
        
        if session.canAddInput(input) {
            session.addInput(input)
        }
        
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }
        
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.frame = view.bounds
        view.layer.addSublayer(previewLayer)
        
        self.previewLayer = previewLayer
        self.captureSession = session
        
        // シャッターボタンを追加
        setupCaptureButton()
        
        // セッション開始（メインスレッドでセッションにアクセスするため変数に保存）
        startCameraSession()
    }
    
    private func startCameraSession() {
        guard let session = captureSession else { return }
        Task.detached {
            session.startRunning()
        }
    }
    
    private func setupCaptureButton() {
        let button = UIButton(type: .system)
        button.frame = CGRect(x: 0, y: 0, width: 80, height: 80)
        button.center = CGPoint(x: view.bounds.midX, y: view.bounds.height - 80)
        
        // 外側の円
        let outerCircle = UIView(frame: button.bounds)
        outerCircle.backgroundColor = .clear
        outerCircle.layer.borderColor = UIColor.white.cgColor
        outerCircle.layer.borderWidth = 4
        outerCircle.layer.cornerRadius = 40
        outerCircle.isUserInteractionEnabled = false
        button.addSubview(outerCircle)
        
        // 内側の円
        let innerCircle = UIView(frame: CGRect(x: 5, y: 5, width: 70, height: 70))
        innerCircle.backgroundColor = .white
        innerCircle.layer.cornerRadius = 35
        innerCircle.isUserInteractionEnabled = false
        button.addSubview(innerCircle)
        
        button.addTarget(self, action: #selector(captureButtonTapped), for: .touchUpInside)
        
        view.addSubview(button)
        self.captureButton = button
    }
    
    @objc private func captureButtonTapped() {
        let settings = AVCapturePhotoSettings()
        photoOutput.capturePhoto(with: settings, delegate: self)
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopCameraSession()
    }
    
    private func stopCameraSession() {
        guard let session = captureSession else { return }
        Task.detached {
            session.stopRunning()
        }
    }
}

extension CameraViewController: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else {
            return
        }
        
        Task { @MainActor [weak self] in
            self?.onImageCaptured?(image)
        }
    }
}

#Preview {
    OCRCameraView { _ in
    }
    .environment(PremiumAccessManager.shared)
}
