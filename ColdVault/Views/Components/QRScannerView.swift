//
//  QRScannerView.swift
//  ColdVault
//
//  Camera QR code scanner. Delivers exactly one result per presentation and
//  explains what to do when camera access is denied or unavailable.
//  Animated multi-part UR codes (`ur:crypto-psbt/1-12/...`) are assembled frame by
//  frame with a progress indicator and delivered as one Base64 PSBT.
//

import SwiftUI
import AVFoundation

public struct QRScannerView: UIViewControllerRepresentable {
    public let didFindCode: (String) -> Void
    @Environment(\.presentationMode) var presentationMode

    public init(didFindCode: @escaping (String) -> Void) {
        self.didFindCode = didFindCode
    }

    public func makeUIViewController(context: Context) -> ScannerViewController {
        let vc = ScannerViewController()
        vc.delegate = context.coordinator
        context.coordinator.controller = vc
        return vc
    }

    public func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {}

    public func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    public final class Coordinator: NSObject, ScannerViewControllerDelegate {
        let parent: QRScannerView
        weak var controller: ScannerViewController?
        private var decoder = URDecoder()
        private var lastFrame: String?

        init(parent: QRScannerView) {
            self.parent = parent
        }

        /// Returns true when scanning is finished (a result or an error was delivered).
        public func didScanCode(_ code: String) -> Bool {
            guard URPSBT.isUR(code) else {
                finish(with: code)
                return true
            }
            // The camera reports the same frame many times per second.
            guard code != lastFrame else { return false }
            lastFrame = code
            decoder.receivePart(code)

            switch decoder.result {
            case .success(let resource):
                do {
                    finish(with: try URPSBT.psbtData(from: resource).base64EncodedString())
                } catch {
                    controller?.showProgress(error.localizedDescription)
                    decoder = URDecoder()
                    return false
                }
                return true
            case .failure(let error):
                controller?.showProgress(error.localizedDescription + "\nVuelve a escanear / Scan again.")
                decoder = URDecoder()
                return false
            case nil:
                let total = decoder.expectedPartCount.map(String.init) ?? "?"
                let percent = Int(decoder.progress * 100)
                controller?.showProgress("QR animado: \(decoder.receivedPartCount)/\(total) · \(percent)%\nMantén la cámara sobre el código / Keep the camera on the code")
                return false
            }
        }

        private func finish(with code: String) {
            parent.didFindCode(code)
            parent.presentationMode.wrappedValue.dismiss()
        }

        public func didCancel() {
            parent.presentationMode.wrappedValue.dismiss()
        }
    }
}

public protocol ScannerViewControllerDelegate: AnyObject {
    /// Return true to stop scanning.
    func didScanCode(_ code: String) -> Bool
    func didCancel()
}

public final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    public weak var delegate: ScannerViewControllerDelegate?
    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var hasDeliveredResult = false
    private let messageLabel = UILabel()
    private let progressLabel = UILabel()

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupMessageLabel()
        setupProgressLabel()
        setupOverlay()

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setupCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.setupCamera()
                    } else {
                        self?.showMessage(denied: true)
                    }
                }
            }
        default:
            showMessage(denied: true)
        }
    }

    private func setupMessageLabel() {
        messageLabel.textColor = .white
        messageLabel.numberOfLines = 0
        messageLabel.textAlignment = .center
        messageLabel.font = UIFont.systemFont(ofSize: 15, weight: .medium)
        messageLabel.isHidden = true
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(messageLabel)
        NSLayoutConstraint.activate([
            messageLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            messageLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            messageLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32)
        ])
    }

    private func setupProgressLabel() {
        progressLabel.textColor = .white
        progressLabel.numberOfLines = 0
        progressLabel.textAlignment = .center
        progressLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        progressLabel.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        progressLabel.layer.cornerRadius = 12
        progressLabel.layer.masksToBounds = true
        progressLabel.isHidden = true
        progressLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(progressLabel)
        NSLayoutConstraint.activate([
            progressLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            progressLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            progressLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24)
        ])
    }

    /// Progress of an animated (multi-part) QR.
    public func showProgress(_ text: String) {
        progressLabel.text = "\n\(text)\n"
        progressLabel.isHidden = false
    }

    private func showMessage(denied: Bool) {
        messageLabel.text = denied
            ? "ColdVault no tiene acceso a la cámara.\nActívalo en Ajustes › ColdVault › Cámara.\n\nCamera access is off. Enable it in Settings › ColdVault › Camera."
            : "No hay una cámara disponible en este dispositivo.\nNo camera is available on this device."
        messageLabel.isHidden = false
    }

    private func setupCamera() {
        let session = AVCaptureSession()
        guard let videoCaptureDevice = AVCaptureDevice.default(for: .video),
              let videoInput = try? AVCaptureDeviceInput(device: videoCaptureDevice),
              session.canAddInput(videoInput) else {
            showMessage(denied: false)
            return
        }
        session.addInput(videoInput)

        let metadataOutput = AVCaptureMetadataOutput()
        guard session.canAddOutput(metadataOutput) else {
            showMessage(denied: false)
            return
        }
        session.addOutput(metadataOutput)

        metadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
        metadataOutput.metadataObjectTypes = [.qr]

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.frame = view.layer.bounds
        preview.videoGravity = .resizeAspectFill
        view.layer.insertSublayer(preview, at: 0)

        self.previewLayer = preview
        self.captureSession = session

        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }
    }

    private func setupOverlay() {
        let cancelButton = UIButton(type: .system)
        cancelButton.setTitle("Cancelar / Cancel", for: .normal)
        cancelButton.setTitleColor(.white, for: .normal)
        cancelButton.titleLabel?.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        cancelButton.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        cancelButton.layer.cornerRadius = 22
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        view.addSubview(cancelButton)

        NSLayoutConstraint.activate([
            cancelButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -30),
            cancelButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            cancelButton.widthAnchor.constraint(equalToConstant: 200),
            cancelButton.heightAnchor.constraint(equalToConstant: 44)
        ])
    }

    @objc private func cancelTapped() {
        delegate?.didCancel()
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.layer.bounds
    }

    public func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        // The delegate keeps firing until the session stops: deliver once.
        guard !hasDeliveredResult,
              let metadataObject = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let stringValue = metadataObject.stringValue,
              delegate?.didScanCode(stringValue) == true else { return }
        hasDeliveredResult = true
        AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))
        let session = captureSession
        DispatchQueue.global(qos: .userInitiated).async {
            session?.stopRunning()
        }
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if let session = captureSession, session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async {
                session.stopRunning()
            }
        }
    }
}
