import SwiftUI
@preconcurrency import AVFoundation

/// QRコードスキャナービュー
struct QRScannerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var scannedCode: String?
    @State private var showManualEntry = false
    @State private var manualCode = ""
    @State private var hasPermission = false
    @State private var showPermissionAlert = false
    
    let onCodeScanned: (String) -> Void
    
    var body: some View {
        NavigationStack {
            ZStack {
                if hasPermission {
                    QRCodeScannerRepresentable(scannedCode: $scannedCode)
                        .ignoresSafeArea()
                    
                    // スキャンフレームオーバーレイ
                    VStack {
                        Spacer()
                        
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.white, lineWidth: 3)
                            .frame(width: 250, height: 250)
                            .background(Color.clear)
                        
                        Spacer()
                        
                        VStack(spacing: 16) {
                            Text("QRコードをフレーム内に合わせてください")
                                .font(.subheadline)
                                .foregroundStyle(.white)
                            
                            Button {
                                showManualEntry = true
                            } label: {
                                Label("手動で入力", systemImage: "keyboard")
                                    .foregroundStyle(.white)
                            }
                        }
                        .padding(.bottom, 60)
                    }
                } else {
                    VStack(spacing: 20) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 60))
                            .foregroundStyle(.secondary)
                        
                        Text("カメラへのアクセスが必要です")
                            .font(.headline)
                        
                        Text("QRコードをスキャンするには\nカメラへのアクセスを許可してください")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        
                        Button("設定を開く") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        
                        Button("手動で入力") {
                            showManualEntry = true
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("QRスキャン")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") {
                        dismiss()
                    }
                }
            }
            .onChange(of: scannedCode) { _, newValue in
                if let code = newValue {
                    handleScannedCode(code)
                }
            }
            .sheet(isPresented: $showManualEntry) {
                ManualCodeEntryView(code: $manualCode) { enteredCode in
                    onCodeScanned(enteredCode)
                    dismiss()
                }
            }
            .onAppear {
                checkCameraPermission()
            }
        }
    }
    
    private func checkCameraPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            hasPermission = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    hasPermission = granted
                }
            }
        default:
            hasPermission = false
        }
    }
    
    private func handleScannedCode(_ urlString: String) {
        // stockpile://join?code=XXXXXX 形式のURLを解析
        if let url = URL(string: urlString),
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           components.scheme == "stockpile",
           let code = components.queryItems?.first(where: { $0.name == "code" })?.value {
            onCodeScanned(code)
            dismiss()
        } else if urlString.count == 6 && urlString.allSatisfy({ $0.isLetter || $0.isNumber }) {
            // 6桁のコードが直接スキャンされた場合
            onCodeScanned(urlString.uppercased())
            dismiss()
        }
    }
}

// MARK: - カメラプレビュー

struct QRCodeScannerRepresentable: UIViewControllerRepresentable {
    @Binding var scannedCode: String?
    
    func makeUIViewController(context: Context) -> QRScannerViewController {
        let controller = QRScannerViewController()
        controller.delegate = context.coordinator
        return controller
    }
    
    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    @MainActor
    class Coordinator: NSObject, QRScannerDelegate {
        let parent: QRCodeScannerRepresentable
        
        init(_ parent: QRCodeScannerRepresentable) {
            self.parent = parent
        }
        
        nonisolated func didScanCode(_ code: String) {
            Task { @MainActor in
                self.parent.scannedCode = code
            }
        }
    }
}

protocol QRScannerDelegate: AnyObject {
    nonisolated func didScanCode(_ code: String)
}

class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    weak var delegate: QRScannerDelegate?
    
    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupCamera()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startScanning()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopScanning()
    }
    
    private func setupCamera() {
        let session = AVCaptureSession()
        
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            return
        }
        
        if session.canAddInput(input) {
            session.addInput(input)
        }
        
        let output = AVCaptureMetadataOutput()
        if session.canAddOutput(output) {
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
        }
        
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.frame = view.bounds
        view.layer.addSublayer(previewLayer)
        
        self.captureSession = session
        self.previewLayer = previewLayer
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }
    
    private func startScanning() {
        guard let session = captureSession else { return }
        Task.detached {
            session.startRunning()
        }
    }
    
    private func stopScanning() {
        captureSession?.stopRunning()
    }
    
    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard let metadataObject = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let stringValue = metadataObject.stringValue else {
            return
        }
        
        // 振動フィードバック
        AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))
        
        Task { @MainActor [weak self] in
            self?.stopScanning()
            self?.delegate?.didScanCode(stringValue)
        }
    }
}

// MARK: - 手動入力ビュー

struct ManualCodeEntryView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var code: String
    let onSubmit: (String) -> Void
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("招待コード（6桁）", text: $code)
                        .textInputAutocapitalization(.characters)
                        .onChange(of: code) { _, newValue in
                            code = String(newValue.prefix(6)).uppercased()
                        }
                } footer: {
                    Text("家族から共有された6桁の招待コードを入力してください")
                }
                
                Section {
                    Button {
                        onSubmit(code)
                        dismiss()
                    } label: {
                        HStack {
                            Spacer()
                            Text("参加")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(code.count != 6)
                }
            }
            .navigationTitle("招待コード入力")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

#Preview {
    QRScannerView { _ in
    }
}
