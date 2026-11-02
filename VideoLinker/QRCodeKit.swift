import SwiftUI
import UIKit
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins

// MARK: - 生成二维码

enum QRCodeMaker {
    /// CIContext 创建一次就够，反复建会卡
    private static let context = CIContext()

    static func image(_ text: String, size: CGFloat = 220) -> UIImage? {
        guard !text.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }

        let scale = size / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// 二维码视图：文字不变就不重新生成
struct QRCodeView: View {
    let text: String
    var size: CGFloat = 160

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else {
                Color.white
            }
        }
        .frame(width: size, height: size)
        .task(id: text) {
            image = QRCodeMaker.image(text, size: size * 2)
        }
    }
}

// MARK: - 扫码

/// 相机预览 + 识别二维码/条形码
struct QRScannerView: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_ uiViewController: ScannerController, context: Context) {}
}

final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?

    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var handled = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSession()
    }

    private func configureSession() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr, .ean13, .ean8, .code128, .code39, .pdf417]

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        previewLayer = layer
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard !session.isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.startRunning()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning { session.stopRunning() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard !handled,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = object.stringValue,
              !value.isEmpty else { return }

        handled = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onCode?(value)
    }
}

/// 弹出的扫码页，处理权限申请与拒绝提示
struct QRScannerSheet: View {
    var onResult: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var status = AVCaptureDevice.authorizationStatus(for: .video)

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                switch status {
                case .authorized:
                    QRScannerView { code in
                        onResult(code)
                        dismiss()
                    }
                    .ignoresSafeArea()

                    // 取景框
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(.white.opacity(0.9), lineWidth: 2)
                        .frame(width: 220, height: 220)
                        .allowsHitTesting(false)

                    VStack {
                        Spacer()
                        Text("把二维码放进取景框")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.bottom, 60)
                    }
                    .allowsHitTesting(false)

                case .notDetermined:
                    ProgressView("正在请求相机权限…")
                        .tint(.white)
                        .foregroundStyle(.white)
                        .task {
                            let granted = await AVCaptureDevice.requestAccess(for: .video)
                            status = granted ? .authorized : .denied
                        }

                default:
                    VStack(spacing: 14) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(.white.opacity(0.7))
                        Text("没有相机权限")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                        Text("到 设置 → 工具箱 → 相机 打开权限，再回来扫")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.65))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                }
            }
            .navigationTitle("扫一扫")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }
}
