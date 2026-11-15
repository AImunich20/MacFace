//
//  CameraManager.swift
//  MacFace
//
//  Owns the AVCaptureSession and publishes the newest camera frame as a CGImage. Runs entirely on-device.
//
//  2.0 changes:
//  - All session configuration (input swap, format selection, start/stop) runs on the capture queue, never the main
//    thread, so starting the camera can't stall the notch animation.
//  - Frames go to `frames` (a `LatestFrameBox`) straight from the capture queue. `currentFrame` — the observable,
//    main-actor copy used by onboarding and Face Lab — is only published when `publishesObservableFrames` is true.
//  - Recovers by itself after a capture-session runtime error or a camera disconnect (sleep, dock, monitor switch),
//    and `restart()` lets callers rebuild a session that went silent.
//  - `stop(after:)` keeps the camera warm briefly so a retry right after a scan doesn't pay the startup cost again.
//

@preconcurrency import AVFoundation
import CoreImage
import Observation

enum CameraPermission {
    case notDetermined
    case granted
    case denied
}

@Observable
@MainActor
final class CameraManager: NSObject {
    private(set) var permission: CameraPermission = .notDetermined
    private(set) var isRunning: Bool = false
    private(set) var currentFrame: CameraFrame?
    private(set) var errorMessage: String?

    /// Newest frame, readable from any task without touching the main actor.
    nonisolated var frames: LatestFrameBox { capture.frames }

    /// Exposed read-only so `CameraPreviewView` can attach a preview layer to the same session.
    nonisolated var session: AVCaptureSession { capture.session }

    @ObservationIgnored private nonisolated let capture: CaptureController
    @ObservationIgnored private var pendingStop: Task<Void, Never>?

    /// `publishesObservableFrames: false` skips the per-frame main-actor hop for owners that read `frames` instead.
    init(publishesObservableFrames: Bool = true) {
        capture = CaptureController(publishesObservableFrames: publishesObservableFrames)
        super.init()
        capture.onFrame = { [weak self] frame in
            Task { @MainActor [weak self] in self?.currentFrame = frame }
        }
        capture.onError = { [weak self] message in
            Task { @MainActor [weak self] in self?.errorMessage = message }
        }
        capture.onDeviceLost = { [weak self] in
            Task { @MainActor [weak self] in self?.handleDeviceLost() }
        }
    }

    func start() async {
        pendingStop?.cancel()
        pendingStop = nil

        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            permission = .granted
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            permission = granted ? .granted : .denied
        default:
            permission = .denied
        }

        guard permission == .granted else {
            errorMessage = "Camera access not granted (status: \(describe(status))). " +
                (status == .restricted
                    ? "macOS reports this as *restricted* — not a simple user denial. This usually means Screen Time content restrictions or an MDM/profile policy is blocking camera access for this app; toggling it in System Settings > Privacy & Security > Camera won't help until that restriction is lifted."
                    : "Enable it in System Settings > Privacy & Security > Camera. If MacFace isn't listed there, quit the app, run `tccutil reset Camera com.aimunich20.macface` in Terminal, then relaunch so macOS asks again.")
            return
        }

        // Resolved here because the camera preference lives in main-actor settings; everything after is off-main.
        guard let device = CameraDeviceCatalog.resolvedDevice() else {
            errorMessage = "No camera device found."
            return
        }
        errorMessage = nil
        capture.start(with: device)
        isRunning = true
    }

    /// Starts the camera ahead of a likely scan (e.g. the lock screen just woke) without prompting for permission,
    /// and lets it stop by itself after `duration` unless a scan's `start()` claims it first.
    func prewarm(for duration: Duration) {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized, !isRunning else { return }
        Task { [weak self] in
            await self?.start()
            self?.stop(after: duration)
        }
    }

    func stop() {
        pendingStop?.cancel()
        pendingStop = nil
        capture.stop()
        isRunning = false
        currentFrame = nil
    }

    /// Keeps the session running for `delay`, so an immediate retry starts with a hot camera. A `start()` in the
    /// meantime cancels the stop.
    func stop(after delay: Duration) {
        pendingStop?.cancel()
        pendingStop = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    /// Tears the input down and rebuilds it — for a session that is "running" but has stopped delivering frames.
    func restart() {
        guard isRunning, let device = CameraDeviceCatalog.resolvedDevice() else { return }
        capture.restart(with: device)
    }

    private func handleDeviceLost() {
        guard isRunning else { return }
        if let device = CameraDeviceCatalog.resolvedDevice() {
            capture.restart(with: device)
        } else {
            errorMessage = "No camera device found."
        }
    }

    private func describe(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "authorized"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }

    /// Kept here for existing callers; the implementation lives in `CameraFrame.swift` so it has no main-actor dependencies.
    nonisolated static func renderCrop(from frame: CameraFrame, imageRect: CGRect, maxEdge: CGFloat = 448) -> CGImage? {
        FrameCropper.renderCrop(from: frame, imageRect: imageRect, maxEdge: maxEdge)
    }
}

/// Everything that touches the capture session. All mutable state is confined to `queue`.
private nonisolated final class CaptureController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    let frames = LatestFrameBox()

    var onFrame: (@Sendable (CameraFrame) -> Void)?
    var onError: (@Sendable (String) -> Void)?
    var onDeviceLost: (@Sendable () -> Void)?

    private let queue = DispatchQueue(label: "com.aimunich20.macface.camera.session")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let publishesObservableFrames: Bool

    // Confined to `queue`.
    private var isConfigured = false
    private var currentInput: AVCaptureDeviceInput?
    private var wantsRunning = false
    private var observers: [NSObjectProtocol] = []

    // Confined to `queue` (the sample-buffer callback runs there too).
    private let ciContext = CIContext()
    /// Detection only needs a modest resolution; the live preview renders from the capture session directly and
    /// is unaffected. The undownscaled `source` is kept alongside for callers needing native pixels (`renderCrop`).
    private let maxLongEdge: CGFloat = 640
    private var nextFrameID: UInt64 = 0

    init(publishesObservableFrames: Bool) {
        self.publishesObservableFrames = publishesObservableFrames
        super.init()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] _ in
            self?.queue.async { self?.recoverFromRuntimeError() }
        })
        observers.append(center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil) { [weak self] note in
            guard let device = note.object as? AVCaptureDevice else { return }
            let uniqueID = device.uniqueID
            self?.queue.async { self?.handleDisconnect(of: uniqueID) }
        })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func start(with device: AVCaptureDevice) {
        queue.async { [self] in
            wantsRunning = true
            configureIfNeeded()
            reconcile(with: device, force: false)
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        queue.async { [self] in
            wantsRunning = false
            if session.isRunning { session.stopRunning() }
            frames.reset()
        }
    }

    func restart(with device: AVCaptureDevice) {
        queue.async { [self] in
            guard wantsRunning else { return }
            if session.isRunning { session.stopRunning() }
            reconcile(with: device, force: true)
            session.startRunning()
        }
    }

    private func configureIfNeeded() {
        guard !isConfigured else { return }
        isConfigured = true

        session.beginConfiguration()
        // `.high` doesn't guarantee the sensor's max resolution; macOS (unlike iOS) doesn't fight an explicitly-set
        // `activeFormat`, so leaving this at `.high` and locking the format separately is sufficient.
        session.sessionPreset = .high
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }
        session.commitConfiguration()
    }

    /// Swaps the input when the preferred camera changed, the old one went away (sleep, unplug), or `force` is set.
    private func reconcile(with device: AVCaptureDevice, force: Bool) {
        if !force, let currentInput, currentInput.device.uniqueID == device.uniqueID, currentInput.device.isConnected {
            return
        }

        session.beginConfiguration()
        if let currentInput {
            session.removeInput(currentInput)
        }
        if let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
            session.addInput(input)
            currentInput = input
            if let choice = CameraFormatSelector.bestFormat(for: device) {
                do {
                    try CameraFormatSelector.apply(choice, to: device)
                } catch {
                    onError?("Couldn't select the camera format: \(error.localizedDescription)")
                }
            }
        } else {
            currentInput = nil
            onError?("No camera device found.")
        }
        session.commitConfiguration()
    }

    private func recoverFromRuntimeError() {
        guard wantsRunning, let device = currentInput?.device else { return }
        if session.isRunning { session.stopRunning() }
        reconcile(with: device, force: true)
        session.startRunning()
    }

    private func handleDisconnect(of uniqueID: String) {
        guard currentInput?.device.uniqueID == uniqueID else { return }
        session.beginConfiguration()
        if let currentInput { session.removeInput(currentInput) }
        session.commitConfiguration()
        currentInput = nil
        if wantsRunning { onDeviceLost?() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let sourceImage = CIImage(cvPixelBuffer: pixelBuffer)
        let sourceExtent = sourceImage.extent
        var ciImage = sourceImage
        let longEdge = max(ciImage.extent.width, ciImage.extent.height)
        if longEdge > maxLongEdge {
            let scale = maxLongEdge / longEdge
            ciImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }

        nextFrameID &+= 1
        let frame = CameraFrame(id: nextFrameID, image: cgImage, source: sourceImage, sourceSize: sourceExtent.size)
        frames.publish(frame)
        if publishesObservableFrames {
            onFrame?(frame)
        }
    }
}
