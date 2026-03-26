import SwiftUI
@preconcurrency import AVFoundation
import AudioToolbox

/// バーコード（JAN）スキャナービュー
struct BarcodeScannerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var scannedCode: String?
    @State private var searchState: SearchState = .idle
    @State private var productInfo: ProductInfo?
    @State private var hasPermission = false
    @State private var showPermissionAlert = false
    @State private var showManualEntry = false
    @State private var manualCode = ""
    @State private var scannerSessionID = UUID()
    
    let onProductSelected: (ProductInfo) -> Void
    
    enum SearchState: Equatable {
        case idle
        case searching
        case found
        case notFound
        case error(String)
        
        static func == (lhs: SearchState, rhs: SearchState) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.searching, .searching), (.found, .found), (.notFound, .notFound):
                return true
            case (.error(let l), .error(let r)):
                return l == r
            default:
                return false
            }
        }
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                if hasPermission {
                    BarcodeScannerRepresentable(scannedCode: $scannedCode)
                        .id(scannerSessionID)
                        .ignoresSafeArea()
                    
                    // オーバーレイUI
                    VStack {
                        Spacer()
                        
                        // スキャン枠ガイド
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white, lineWidth: 3)
                            .frame(width: 280, height: 150)
                            .overlay {
                                if searchState == .searching {
                                    ProgressView()
                                        .scaleEffect(1.5)
                                        .tint(.white)
                                }
                            }
                        
                        Text("バーコードを枠内に合わせてください")
                            .font(.subheadline)
                            .foregroundStyle(.white)
                            .padding(.top, 8)
                        
                        Spacer()
                        
                        // 検索結果表示
                        if let product = productInfo, searchState == .found {
                            productResultCard(product)
                        } else if searchState == .notFound {
                            notFoundCard
                        } else if case .error(let message) = searchState {
                            errorCard(message)
                        }
                        
                        // 手動入力ボタン
                        Button {
                            showManualEntry = true
                        } label: {
                            Label("手動でJANコードを入力", systemImage: "keyboard")
                                .font(.footnote)
                                .foregroundStyle(.white.opacity(0.8))
                        }
                        .padding(.bottom, 40)
                    }
                } else {
                    VStack(spacing: 20) {
                        Image(systemName: "barcode.viewfinder")
                            .font(.system(size: 60))
                            .foregroundStyle(.secondary)
                        
                        Text("カメラへのアクセスが必要です")
                            .font(.headline)
                        
                        Text("バーコードをスキャンするには\nカメラへのアクセスを許可してください")
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
            .navigationTitle("バーコードスキャン")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showManualEntry) {
                ManualJANEntryView(code: $manualCode) { enteredCode in
                    Task {
                        await searchProduct(janCode: enteredCode)
                    }
                }
            }
            .onAppear {
                checkCameraPermission()
            }
            .onChange(of: scannedCode) { _, newValue in
                if let code = newValue, searchState != .searching {
                    Task {
                        await searchProduct(janCode: code)
                    }
                }
            }
        }
    }
    
    // MARK: - 検索結果カード
    
    private func productResultCard(_ product: ProductInfo) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                // 商品画像
                if let imageURL = product.imageURL {
                    AsyncImage(url: imageURL) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                        case .empty, .failure:
                            Rectangle()
                                .fill(Color.gray.opacity(0.3))
                        @unknown default:
                            Rectangle()
                                .fill(Color.gray.opacity(0.3))
                        }
                    }
                    .frame(width: 60, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(product.name)
                        .font(.headline)
                        .lineLimit(2)
                    
                    if let category = product.category {
                        Text(category)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    Text(product.source.localizedDisplayName + "で検索")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                
                Spacer()
            }
            
            HStack(spacing: 12) {
                Button("採用") {
                    onProductSelected(product)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                
                Button("再スキャン") {
                    resetState()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
    
    private var notFoundCard: some View {
        VStack(spacing: 12) {
            Text("商品が見つかりませんでした")
                .font(.headline)
            
            if let code = scannedCode ?? (manualCode.isEmpty ? nil : manualCode) {
                Text("JANコード: \(code)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            HStack(spacing: 12) {
                Button("手動で入力") {
                    showManualEntry = true
                }
                .buttonStyle(.borderedProminent)
                
                Button("再スキャン") {
                    resetState()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
    
    private func errorCard(_ message: String) -> some View {
        VStack(spacing: 12) {
            Text("エラーが発生しました")
                .font(.headline)
            
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
            
            Button("再スキャン") {
                resetState()
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
    
    // MARK: - Helper Methods
    
    private func checkCameraPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            hasPermission = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in
                    hasPermission = granted
                }
            }
        case .denied, .restricted:
            hasPermission = false
            showPermissionAlert = true
        @unknown default:
            hasPermission = false
        }
    }
    
    private func searchProduct(janCode: String) async {
        searchState = .searching
        
        do {
            let product = try await ProductSearchService.shared.search(janCode: janCode)
            productInfo = product
            searchState = .found
        } catch ProductSearchError.notFound {
            searchState = .notFound
        } catch {
            searchState = .error(error.localizedDescription)
        }
    }
    
    private func resetState() {
        scannedCode = nil
        productInfo = nil
        searchState = .idle
        manualCode = ""
        scannerSessionID = UUID()
    }
}

// MARK: - バーコードスキャナー UIKit表現

struct BarcodeScannerRepresentable: UIViewControllerRepresentable {
    @Binding var scannedCode: String?
    
    func makeUIViewController(context: Context) -> BarcodeScannerViewController {
        let controller = BarcodeScannerViewController()
        controller.delegate = context.coordinator
        return controller
    }
    
    func updateUIViewController(_ uiViewController: BarcodeScannerViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(scannedCode: $scannedCode)
    }
    
    @MainActor
    class Coordinator: NSObject, BarcodeScannerDelegate {
        private var scannedCode: Binding<String?>
        
        init(scannedCode: Binding<String?>) {
            self.scannedCode = scannedCode
        }
        
        nonisolated func didScanBarcode(_ code: String) {
            Task { @MainActor in
                self.scannedCode.wrappedValue = code
            }
        }
    }
}

protocol BarcodeScannerDelegate: AnyObject {
    nonisolated func didScanBarcode(_ code: String)
}

class BarcodeScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    weak var delegate: BarcodeScannerDelegate?
    
    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var hasScanned = false
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupCamera()
    }
    
    private func setupCamera() {
        let session = AVCaptureSession()
        
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            return
        }
        
        session.addInput(input)
        
        let output = AVCaptureMetadataOutput()
        session.addOutput(output)
        
        output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
        // JANコード（EAN-8, EAN-13）をサポート
        output.metadataObjectTypes = [.ean8, .ean13]
        
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
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startScanning()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopScanning()
    }
    
    private func startScanning() {
        guard let session = captureSession else { return }
        hasScanned = false
        Task.detached {
            session.startRunning()
        }
    }
    
    private func stopScanning() {
        guard let session = captureSession else { return }
        Task.detached {
            session.stopRunning()
        }
    }
    
    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let stringValue = object.stringValue else {
            return
        }
        
        // 重複スキャン防止
        Task { @MainActor [weak self] in
            guard let self = self, !self.hasScanned else { return }
            self.hasScanned = true
            
            // 振動フィードバック
            AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))
            
            self.stopScanning()
            self.delegate?.didScanBarcode(stringValue)
        }
    }
    
    func resetScanning() {
        hasScanned = false
        startScanning()
    }
}

// MARK: - 手動JANコード入力

struct ManualJANEntryView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var code: String
    let onSubmit: (String) -> Void
    
    private var isValidCode: Bool {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.count == 8 || trimmed.count == 13) && trimmed.allSatisfy { $0.isNumber }
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("JANコード（8桁または13桁）", text: $code)
                        .keyboardType(.numberPad)
                } header: {
                    Text("JANコード")
                } footer: {
                    Text("商品パッケージのバーコード下に記載されている数字を入力してください")
                }
            }
            .navigationTitle("JANコード入力")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("検索") {
                        onSubmit(code)
                        dismiss()
                    }
                    .disabled(!isValidCode)
                }
                
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
    BarcodeScannerView { _ in
    }
}
