import AVFoundation
import Photos
import SwiftUI
import UserNotifications

// Camera remote: the watch's "Remote shutter" app takes photos with the iPhone (Gadgetbridge packets/CameraRemote.java:
// watch -> phone 0x01/0x29 with 1 = open, 2 = take picture, 3 = close, each acknowledged with 7F=0x186A0;
// phone -> watch 0x01/0x2A with 0 = enable, 1 = camera started, 2 = camera stopped).
// iOS only lets an app use the camera in the foreground: with HuaSideload in the background a notification asks to open it.
@MainActor
final class CameraRemote: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    static let shared = CameraRemote()

    @Published var showing = false
    @Published private(set) var lastSaved: String?
    let captureSession = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private var configured = false
    private var pendingOpen = false
    private weak var session: HuaweiSession?

    func attach(_ session: HuaweiSession) {
        self.session = session
        session.send(0x01, 0x2A, HuaweiTLV().with(0x01, [0x00]))   // enable the remote shutter on the watch
    }

    func handle(_ packet: HuaweiPacket, session: HuaweiSession) {
        self.session = session
        session.send(0x01, 0x29, HuaweiTLV().with(0x7F, [0x00, 0x01, 0x86, 0xA0]))
        switch packet.tlv?.value(0x01)?.first {
        case 1: open()
        case 2: takePicture()
        case 3: close(notifyWatch: false)
        default: break
        }
    }

    private func open() {
        guard UIApplication.shared.applicationState == .active else {
            pendingOpen = true
            let content = UNMutableNotificationContent()
            content.title = L("Remote shutter", "Uzaktan deklanşör")
            content.body = L("Open HuaSideload to use the iPhone camera from the watch.", "Saatten kamera için HuaSideload'u aç.")
            content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "camera-remote", content: content, trigger: nil))
            return
        }
        showing = true
    }

    /// Called when the app becomes active: opens the camera if the watch asked while the app was in the background.
    func appBecameActive() {
        if pendingOpen { pendingOpen = false; showing = true }
    }

    /// The camera sheet appeared: start the camera and tell the watch.
    func start() {
        Task {
            guard await AVCaptureDevice.requestAccess(for: .video) else { lastSaved = L("No camera access.", "Kamera izni yok."); return }
            if !configured {
                captureSession.beginConfiguration()
                captureSession.sessionPreset = .photo
                if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                   let input = try? AVCaptureDeviceInput(device: device), captureSession.canAddInput(input) {
                    captureSession.addInput(input)
                }
                if captureSession.canAddOutput(output) { captureSession.addOutput(output) }
                captureSession.commitConfiguration()
                configured = true
            }
            let running = captureSession
            await Task.detached { running.startRunning() }.value
            // Gadgetbridge waits a moment before "camera started"
            try? await Task.sleep(for: .seconds(1))
            session?.send(0x01, 0x2A, HuaweiTLV().with(0x01, [0x01]))
        }
    }

    func close(notifyWatch: Bool) {
        showing = false
        let running = captureSession
        Task.detached { running.stopRunning() }
        if notifyWatch { session?.send(0x01, 0x2A, HuaweiTLV().with(0x01, [0x02])) }
    }

    func takePicture() {
        guard showing, captureSession.isRunning else { return }
        output.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
    }

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else { return }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                Task { @MainActor in CameraRemote.shared.lastSaved = L("No access to Photos.", "Fotoğraflar izni yok.") }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            }) { ok, _ in
                Task { @MainActor in
                    CameraRemote.shared.lastSaved = ok ? L("Photo saved", "Fotoğraf kaydedildi") + " " + Date().formatted(date: .omitted, time: .standard)
                                                       : L("Could not save the photo.", "Fotoğraf kaydedilemedi.")
                }
            }
        }
    }
}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.preview.session = session
        view.preview.videoGravity = .resizeAspectFill
        return view
    }
    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

struct CameraRemoteView: View {
    @ObservedObject private var camera = CameraRemote.shared

    var body: some View {
        ZStack(alignment: .bottom) {
            CameraPreview(session: camera.captureSession).ignoresSafeArea()
            VStack(spacing: 12) {
                if let saved = camera.lastSaved {
                    Text(saved).font(.caption).padding(8).background(.ultraThinMaterial, in: Capsule())
                }
                HStack(spacing: 40) {
                    Button(L("Close", "Kapat")) { camera.close(notifyWatch: true) }
                        .buttonStyle(.bordered)
                    Button { camera.takePicture() } label: {
                        Circle().fill(.white).frame(width: 70, height: 70).overlay(Circle().stroke(.gray, lineWidth: 3))
                    }
                }
                Text(L("Or press the shutter on the watch", "Ya da saatteki deklanşöre bas")).font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.bottom, 30)
        }
        .onAppear { camera.start() }
        .onDisappear { camera.close(notifyWatch: true) }
    }
}
