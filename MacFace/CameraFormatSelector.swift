//
//  CameraFormatSelector.swift
//  MacFace
//
//  Picks the capture format. The old rule took the largest resolution regardless of frame rate, which on some
//  cameras lands on a 15–30 fps format (or the 30 fps twin of a 60 fps one) — fewer, staler frames for detection
//  and liveness. Resolution still matters (FrameCropper reads native pixels for spoof cues), so this keeps the
//  largest format among the ones fast enough, then prefers the higher frame rate.
//

@preconcurrency import AVFoundation

nonisolated enum CameraFormatSelector {
    /// Formats below this are only used when a camera offers nothing faster.
    static let minimumUsefulFrameRate: Double = 30
    /// Faster than this adds frames the pipeline can't process anyway.
    static let maximumFrameRate: Double = 60

    struct Choice {
        let format: AVCaptureDevice.Format
        let frameRate: Double
        let width: Int32
        let height: Int32
    }

    static func bestFormat(for device: AVCaptureDevice) -> Choice? {
        best(of: device.formats)
    }

    static func best(of formats: [AVCaptureDevice.Format]) -> Choice? {
        let choices = formats.map { format -> Choice in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let maxRate = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            return Choice(format: format, frameRate: min(maxRate, maximumFrameRate),
                          width: dimensions.width, height: dimensions.height)
        }
        let fastEnough = choices.filter { $0.frameRate >= minimumUsefulFrameRate }
        let pool = fastEnough.isEmpty ? choices : fastEnough
        return pool.max { lhs, rhs in
            let lhsArea = Int(lhs.width) * Int(lhs.height)
            let rhsArea = Int(rhs.width) * Int(rhs.height)
            if lhsArea != rhsArea { return lhsArea < rhsArea }
            return lhs.frameRate < rhs.frameRate
        }
    }

    /// The pre-2.0 rule, kept for tools/pipeline_benchmark.swift comparisons.
    static func legacyHighestResolution(of formats: [AVCaptureDevice.Format]) -> AVCaptureDevice.Format? {
        formats.max { lhs, rhs in
            let l = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let r = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
            return Int(l.width) * Int(l.height) < Int(r.width) * Int(r.height)
        }
    }

    /// Applies `choice` and pins the frame rate to its fastest supported value. Caller holds no configuration lock.
    static func apply(_ choice: Choice, to device: AVCaptureDevice) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.activeFormat = choice.format
        if let range = choice.format.videoSupportedFrameRateRanges.first(where: { $0.maxFrameRate >= choice.frameRate }) {
            let duration = CMTime(value: 1, timescale: CMTimeScale(choice.frameRate.rounded()))
            // Only the minimum duration (= max fps) is pinned. The maximum is left to the camera so it can still
            // lengthen exposure in dim light instead of producing dark, noisy frames recognition would struggle with.
            if CMTimeCompare(duration, range.minFrameDuration) >= 0 {
                device.activeVideoMinFrameDuration = duration
            }
        }
    }
}
