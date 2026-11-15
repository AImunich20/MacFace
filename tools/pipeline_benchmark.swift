//
//  pipeline_benchmark.swift
//  MacFace (tools)
//
//  Measures what an unlock scan spends its time on, against the real app files and the real camera:
//    1. camera startup (startRunning → first frame) and delivered fps, old format rule vs. CameraFormatSelector
//    2. per-frame pipeline stages on live frames: detect, align, ArcFace embed, native crop, bezel, glare
//    3. scan-loop throughput: frames analysed per second by the 1.x polling loop vs. the 2.0 frame hand-off
//
//  Build and run from the repo root (needs Xcode for coremlcompiler; the terminal needs camera access):
//
//      tools/run_pipeline_benchmark.sh            # live camera, look at it while it runs
//      tools/run_pipeline_benchmark.sh face.jpg   # a still photo instead of the camera (pipeline stages only)
//

import AVFoundation
import CoreImage
import Foundation

// MARK: - Frame source (mirrors CameraManager.FramePublisher)

nonisolated final class Grabber: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let box = LatestFrameBox()
    private let ciContext = CIContext()
    private let maxLongEdge: CGFloat = 640
    private let lock = NSLock()
    private var nextID: UInt64 = 0
    private(set) var firstFrameAt: Date?
    private(set) var frameCount = 0
    private(set) var downscaleMillis: [Double] = []

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let started = Date()
        let source = CIImage(cvPixelBuffer: pixelBuffer)
        var image = source
        let longEdge = max(image.extent.width, image.extent.height)
        if longEdge > maxLongEdge {
            let scale = maxLongEdge / longEdge
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        guard let cgImage = ciContext.createCGImage(image, from: image.extent) else { return }
        let elapsed = Date().timeIntervalSince(started) * 1000

        lock.lock()
        if firstFrameAt == nil { firstFrameAt = Date() }
        frameCount += 1
        nextID &+= 1
        let id = nextID
        downscaleMillis.append(elapsed)
        lock.unlock()

        box.publish(CameraFrame(id: id, image: cgImage, source: source, sourceSize: source.extent.size))
    }

    func snapshot() -> (Date?, Int) {
        lock.lock(); defer { lock.unlock() }
        return (firstFrameAt, frameCount)
    }
}

nonisolated struct CameraRun {
    let session: AVCaptureSession
    let grabber: Grabber
    let startupSeconds: Double?
    let fps: Double
    let description: String
}

nonisolated func openCamera(device: AVCaptureDevice, label: String, configure: (AVCaptureDevice) throws -> String) -> CameraRun? {
    let session = AVCaptureSession()
    let output = AVCaptureVideoDataOutput()
    let grabber = Grabber()
    let queue = DispatchQueue(label: "bench.camera")
    session.beginConfiguration()
    session.sessionPreset = .high
    output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    output.alwaysDiscardsLateVideoFrames = true
    output.setSampleBufferDelegate(grabber, queue: queue)
    guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input), session.canAddOutput(output) else {
        print("  [\(label)] couldn't open \(device.localizedName)")
        return nil
    }
    session.addInput(input)
    session.addOutput(output)
    let description: String
    do { description = try configure(device) } catch {
        print("  [\(label)] format error: \(error)")
        return nil
    }
    session.commitConfiguration()

    let startedAt = Date()
    session.startRunning()
    // Wait up to 5s for the first frame.
    while grabber.snapshot().0 == nil, Date().timeIntervalSince(startedAt) < 5 { Thread.sleep(forTimeInterval: 0.005) }
    guard let first = grabber.snapshot().0 else {
        print("  [\(label)] no frames — does the terminal have camera access?")
        session.stopRunning()
        return nil
    }
    let startup = first.timeIntervalSince(startedAt)
    let countAtStart = grabber.snapshot().1
    Thread.sleep(forTimeInterval: 3)
    let fps = Double(grabber.snapshot().1 - countAtStart) / 3
    return CameraRun(session: session, grabber: grabber, startupSeconds: startup, fps: fps, description: description)
}

// MARK: - Stats

nonisolated func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return .nan }
    let sorted = values.sorted()
    let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * p).rounded())))
    return sorted[index]
}

nonisolated func row(_ name: String, _ values: [Double]) -> String {
    let median = String(format: "%7.1f", percentile(values, 0.5))
    let p90 = String(format: "%7.1f", percentile(values, 0.9))
    return "  \(name.padding(toLength: 26, withPad: " ", startingAt: 0)) median \(median) ms   p90 \(p90) ms   (n=\(values.count))"
}

// MARK: - Pipeline stages

nonisolated struct StageTimes {
    var detect: [Double] = []
    var align: [Double] = []
    var embed: [Double] = []
    var crop: [Double] = []
    var bezel: [Double] = []
    var glare: [Double] = []
    var total: [Double] = []
    var framesWithoutFace = 0
}

nonisolated func millis(_ body: () throws -> Void) rethrows -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    try body()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
}

nonisolated func measure(frame: CameraFrame, embedder: FaceEmbedder, into times: inout StageTimes) {
    var faces: [DetectedFace] = []
    let detect = millis { faces = (try? FaceDetector.detectFaces(in: frame.image)) ?? [] }
    guard let face = faces.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }) else {
        times.framesWithoutFace += 1
        return
    }
    var aligned: AlignedFace?
    let align = millis { aligned = FaceAligner.align(face, from: frame.image) }
    var embed = 0.0
    if let aligned { embed = millis { _ = try? embedder.embedding(for: aligned.image) } }
    var crop: CGImage?
    let cropTime = millis { crop = FrameCropper.renderCrop(from: frame, imageRect: face.boundingBox) }
    let bezel = millis { _ = DeviceBezelDetector.detect(in: frame.image, faceBoundingBox: face.boundingBox) }
    let glare = millis { if let crop { _ = GlareCueExtractor.extract(faceCrop: crop) } }

    times.detect.append(detect)
    times.align.append(align)
    times.embed.append(embed)
    times.crop.append(cropTime)
    times.bezel.append(bezel)
    times.glare.append(glare)
    times.total.append(detect + align + embed + cropTime + bezel + glare)
}

nonisolated func report(_ times: StageTimes) {
    print(row("detect (Vision ×2)", times.detect))
    print(row("align", times.align))
    print(row("embed (ArcFace)", times.embed))
    print(row("native crop", times.crop))
    print(row("bezel (rectangles)", times.bezel))
    print(row("glare (pixel loop)", times.glare))
    print(row("TOTAL per frame", times.total))
    if times.framesWithoutFace > 0 { print("  frames with no face: \(times.framesWithoutFace)") }
}

// MARK: - Main

let embedder: FaceEmbedder
do {
    embedder = try ArcFaceEmbedder()
} catch {
    print("ArcFace failed to load (\(error.localizedDescription)); falling back to Vision feature prints.")
    embedder = VisionFeaturePrintEmbedder()
}
print("Embedder: \(embedder.name)")

let arguments = CommandLine.arguments.dropFirst()
if let path = arguments.first {
    guard let source = CIImage(contentsOf: URL(fileURLWithPath: path)) else {
        print("Couldn't read \(path)")
        exit(1)
    }
    let context = CIContext()
    let longEdge = max(source.extent.width, source.extent.height)
    let scale = min(1, 640 / longEdge)
    let working = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    guard let cgImage = context.createCGImage(working, from: working.extent) else { exit(1) }
    let frame = CameraFrame(id: 1, image: cgImage, source: source, sourceSize: source.extent.size)
    var times = StageTimes()
    for _ in 0..<5 { measure(frame: frame, embedder: embedder, into: &times) }   // warm-up
    times = StageTimes()
    for _ in 0..<40 { measure(frame: frame, embedder: embedder, into: &times) }
    print("\nPipeline stages on \(path):")
    report(times)
    exit(0)
}

guard let device = AVCaptureDevice.default(for: .video) else {
    print("No camera found.")
    exit(1)
}
print("Camera: \(device.localizedName)")

func describe(_ format: AVCaptureDevice.Format) -> String {
    let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
    let fps = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
    return "\(d.width)x\(d.height) up to \(Int(fps)) fps"
}

print("\n1) Camera startup and frame rate")
let legacy = openCamera(device: device, label: "1.x") { device in
    guard let format = CameraFormatSelector.legacyHighestResolution(of: device.formats) else { return "default" }
    try device.lockForConfiguration()
    device.activeFormat = format
    device.unlockForConfiguration()
    return describe(format)
}
if let legacy {
    print(String(format: "  1.x format  %@ → startup %.0f ms, %.1f fps delivered", legacy.description, (legacy.startupSeconds ?? 0) * 1000, legacy.fps))
    legacy.session.stopRunning()
}
Thread.sleep(forTimeInterval: 1)
guard let current = openCamera(device: device, label: "2.0", configure: { device in
    guard let choice = CameraFormatSelector.bestFormat(for: device) else { return "default" }
    try CameraFormatSelector.apply(choice, to: device)
    return describe(choice.format)
}) else { exit(1) }
print(String(format: "  2.0 format  %@ → startup %.0f ms, %.1f fps delivered", current.description, (current.startupSeconds ?? 0) * 1000, current.fps))
print(row("downscale to 640px", current.grabber.downscaleMillis))

print("\n2) Pipeline stages on live frames — look at the camera…")
let deadline = Date().addingTimeInterval(20)
let semaphore = DispatchSemaphore(value: 0)
nonisolated(unsafe) var collected = StageTimes()
Task.detached {
    var times = StageTimes()
    var lastID: UInt64?
    var warmup = 5
    while times.total.count < 60, Date() < deadline {
        guard let frame = await current.grabber.box.next(after: lastID, timeout: .milliseconds(200)) else { continue }
        lastID = frame.id
        if warmup > 0 {
            warmup -= 1
            var scratch = StageTimes()
            measure(frame: frame, embedder: embedder, into: &scratch)
            continue
        }
        measure(frame: frame, embedder: embedder, into: &times)
    }
    collected = times
    semaphore.signal()
}
semaphore.wait()
report(collected)

// 3) Scan-loop throughput: the 1.x loop (poll every 20ms for a new frame, sleep 20ms after each one) against the 2.0
// loop (wait on LatestFrameBox). Same real stages per frame; counts frames actually analysed in 5 seconds.
nonisolated func analyse(_ frame: CameraFrame) {
    var scratch = StageTimes()
    measure(frame: frame, embedder: embedder, into: &scratch)
}

nonisolated(unsafe) var loopResults: [(String, Double, Double)] = []
let loopSemaphore = DispatchSemaphore(value: 0)
Task.detached {
    let box = current.grabber.box
    for (name, legacy) in [("1.x loop (poll + 20ms sleep)", true), ("2.0 loop (frame hand-off)", false)] {
        var analysed = 0
        var waitMillis: [Double] = []
        var lastID: UInt64?
        let end = Date().addingTimeInterval(5)
        while Date() < end {
            let waitStart = DispatchTime.now().uptimeNanoseconds
            var frame: CameraFrame?
            if legacy {
                while Date() < end {
                    if let latest = box.latest, latest.id != lastID { frame = latest; break }
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
            } else {
                frame = await box.next(after: lastID, timeout: .milliseconds(150))
            }
            guard let frame else { continue }
            waitMillis.append(Double(DispatchTime.now().uptimeNanoseconds - waitStart) / 1_000_000)
            lastID = frame.id
            analyse(frame)
            analysed += 1
            if legacy { try? await Task.sleep(nanoseconds: 20_000_000) }
        }
        loopResults.append((name, Double(analysed) / 5, percentile(waitMillis, 0.5)))
    }
    loopSemaphore.signal()
}
loopSemaphore.wait()
current.session.stopRunning()
print("\n3) Scan loop throughput (camera delivers \(String(format: "%.0f", current.fps)) fps)")
for (name, rate, wait) in loopResults {
    print(String(format: "  %@  %5.1f frames analysed/s   median wait for a frame %5.1f ms", name.padding(toLength: 30, withPad: " ", startingAt: 0), rate, wait))
}
