//
//  CameraFrame.swift
//  MacFace
//
//  The camera frame value, the native-resolution crop used by spoof cues, and `LatestFrameBox`, which hands
//  the newest frame to background consumers straight from the capture queue (no main-actor hop per frame).
//  Kept free of main-actor and Observation dependencies so tools/pipeline_benchmark.swift can compile it.
//

import CoreImage
import Foundation

/// `source` is a `CIImage` — a lazy recipe, not rendered pixels — so holding onto it costs nothing until `renderCrop` uses it.
/// `@unchecked Sendable`: every field is immutable, and `CGImage`/`CIImage` are immutable, thread-safe types.
nonisolated struct CameraFrame: @unchecked Sendable {
    let id: UInt64
    let image: CGImage
    let source: CIImage
    let sourceSize: CGSize
}

nonisolated enum FrameCropper {
    /// Renders a native-resolution crop of `imageRect` from `frame.source`, for spoof-cue extraction which
    /// needs pixel detail (screen texture, moiré, gloss) the downscaled working frame throws away.
    static func renderCrop(from frame: CameraFrame, imageRect: CGRect, maxEdge: CGFloat = 448) -> CGImage? {
        let workingWidth = CGFloat(frame.image.width)
        let workingHeight = CGFloat(frame.image.height)
        guard workingWidth > 0, workingHeight > 0 else { return nil }
        let scaleX = frame.sourceSize.width / workingWidth
        let scaleY = frame.sourceSize.height / workingHeight

        // Expand ~1.3x so device edges/bezels are captured for texture/moiré cues.
        let expanded = imageRect.insetBy(dx: -imageRect.width * 0.15, dy: -imageRect.height * 0.15)

        // Flip from `imageRect`'s top-left/y-down space to Core Image's bottom-left/y-up (reverse of FaceDetector.convertToImageSpace).
        let nativeX = expanded.origin.x * scaleX
        let nativeWidth = expanded.width * scaleX
        let nativeHeight = expanded.height * scaleY
        let nativeY = frame.sourceSize.height - (expanded.origin.y + expanded.height) * scaleY
        var nativeRect = CGRect(x: nativeX, y: nativeY, width: nativeWidth, height: nativeHeight)

        let sourceExtent = CGRect(origin: .zero, size: frame.sourceSize)
        nativeRect = nativeRect.intersection(sourceExtent)
        guard !nativeRect.isEmpty else { return nil }

        var cropped = frame.source.cropped(to: nativeRect)
            .transformed(by: CGAffineTransform(translationX: -nativeRect.minX, y: -nativeRect.minY))
        let longEdge = max(nativeRect.width, nativeRect.height)
        if longEdge > maxEdge {
            let scale = maxEdge / longEdge
            cropped = cropped.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }

        return renderContext.createCGImage(cropped, from: cropped.extent)
    }

    /// `CIContext` is expensive to create and safe to reuse concurrently.
    private static let renderContext = CIContext()
}

/// Holds the newest camera frame and wakes anyone waiting for a newer one. Written from the capture queue, read from
/// background tasks — so the unlock loop never polls, and never waits on the main actor to see a frame.
nonisolated final class LatestFrameBox: @unchecked Sendable {
    private let lock = NSLock()
    private var frame: CameraFrame?
    private var waiters: [UInt64: CheckedContinuation<CameraFrame?, Never>] = [:]
    private var nextWaiterID: UInt64 = 0

    var latest: CameraFrame? {
        lock.lock(); defer { lock.unlock() }
        return frame
    }

    func publish(_ newFrame: CameraFrame) {
        lock.lock()
        frame = newFrame
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for continuation in pending.values { continuation.resume(returning: newFrame) }
    }

    /// Drops the stored frame (camera stopped) and releases every waiter with `nil`.
    func reset() {
        lock.lock()
        frame = nil
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for continuation in pending.values { continuation.resume(returning: nil) }
    }

    /// Returns a frame whose id differs from `previousID` — immediately if one is already stored, otherwise as soon as
    /// the camera delivers one. Returns `nil` after `timeout` or on cancellation, so callers can re-check their deadline.
    func next(after previousID: UInt64?, timeout: Duration) async -> CameraFrame? {
        let waiterID: UInt64 = {
            lock.lock(); defer { lock.unlock() }
            nextWaiterID &+= 1
            return nextWaiterID
        }()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<CameraFrame?, Never>) in
                lock.lock()
                if let frame, frame.id != previousID {
                    lock.unlock()
                    continuation.resume(returning: frame)
                    return
                }
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(returning: nil)
                    return
                }
                waiters[waiterID] = continuation
                lock.unlock()

                Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    self?.resumeWaiter(waiterID)
                }
            }
        } onCancel: {
            resumeWaiter(waiterID)
        }
    }

    private func resumeWaiter(_ waiterID: UInt64) {
        lock.lock()
        let continuation = waiters.removeValue(forKey: waiterID)
        lock.unlock()
        continuation?.resume(returning: nil)
    }
}
