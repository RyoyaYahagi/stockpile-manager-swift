import SwiftUI
import AVFoundation
import Vision

/// OCRカメラビュー（賞味期限読み取り）
struct OCRCameraView: View {
    @Environment(\.dismiss) private var dismiss
    let onDateDetected: (Date?) -> Void
    
    @State private var detectedText = ""
    @State private var detectedDate: Date?
    @State private var isProcessing = false
    
    var body: some View {
        NavigationStack {
            ZStack {
                CameraPreview(onImageCaptured: processImage)
                
                VStack {
                    Spacer()
                    
                    // 検出結果表示
                    VStack(spacing: 12) {
                        if isProcessing {
                            ProgressView("読み取り中...")
                                .padding()
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        } else if let date = detectedDate {
                            VStack(spacing: 8) {
                                Text("検出された日付")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(date, style: .date)
                                    .font(.title2.bold())
                            }
                            .padding()
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                            
                            Button {
                                onDateDetected(date)
                                dismiss()
                            } label: {
                                Text("この日付を使用")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(.blue, in: RoundedRectangle(cornerRadius: 12))
                                    .foregroundStyle(.white)
                            }
                            .padding(.horizontal)
                        } else if !detectedText.isEmpty {
                            Text("日付が検出できませんでした")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .padding()
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    .padding(.bottom, 40)
                }
            }
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
    }
    
    private func processImage(_ image: UIImage) {
        isProcessing = true
        
        guard let cgImage = image.cgImage else {
            isProcessing = false
            return
        }
        
        let request = VNRecognizeTextRequest { request, error in
            DispatchQueue.main.async {
                isProcessing = false
                
                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    return
                }
                
                let text = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                detectedText = text
                detectedDate = extractDate(from: text)
            }
        }
        
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ja-JP", "en-US"]
        
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        
        DispatchQueue.global(qos: .userInitiated).async {
            try? handler.perform([request])
        }
    }
    
    /// テキストから日付を抽出
    private func extractDate(from text: String) -> Date? {
        let patterns = [
            // YYYY-MM-DD, YYYY/MM/DD, YYYY.MM.DD
            #"(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})"#,
            // YYYY年MM月DD日
            #"(\d{4})年(\d{1,2})月(\d{1,2})日"#,
            // YY.MM.DD
            #"(\d{2})\.(\d{1,2})\.(\d{1,2})"#,
        ]
        
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
                
                let yearRange = Range(match.range(at: 1), in: text)!
                let monthRange = Range(match.range(at: 2), in: text)!
                let dayRange = Range(match.range(at: 3), in: text)!
                
                var year = Int(text[yearRange]) ?? 0
                let month = Int(text[monthRange]) ?? 0
                let day = Int(text[dayRange]) ?? 0
                
                // 2桁年を4桁に変換
                if year < 100 {
                    year += 2000
                }
                
                var components = DateComponents()
                components.year = year
                components.month = month
                components.day = day
                
                return Calendar.current.date(from: components)
            }
        }
        
        return nil
    }
}

/// カメラプレビュー
struct CameraPreview: UIViewRepresentable {
    let onImageCaptured: (UIImage) -> Void
    
    func makeUIView(context: Context) -> CameraPreviewView {
        let view = CameraPreviewView()
        view.onImageCaptured = onImageCaptured
        return view
    }
    
    func updateUIView(_ uiView: CameraPreviewView, context: Context) {}
}

class CameraPreviewView: UIView {
    var onImageCaptured: ((UIImage) -> Void)?
    
    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private let output = AVCapturePhotoOutput()
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupCamera()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupCamera()
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
        
        if session.canAddOutput(output) {
            session.addOutput(output)
        }
        
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        layer.addSublayer(previewLayer)
        
        self.previewLayer = previewLayer
        self.captureSession = session
        
        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }
        
        // 3秒後に自動撮影
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.capturePhoto()
        }
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer?.frame = bounds
    }
    
    func capturePhoto() {
        let settings = AVCapturePhotoSettings()
        output.capturePhoto(with: settings, delegate: self)
    }
}

@MainActor
extension CameraPreviewView: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else {
            return
        }
        
        Task { @MainActor in
            self.onImageCaptured?(image)
        }
    }
}

#Preview {
    OCRCameraView { date in
        print("Detected: \(String(describing: date))")
    }
}
