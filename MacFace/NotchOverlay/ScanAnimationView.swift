//
//  ScanAnimationView.swift
//  MacFace
//
//  Plays a scan animation once and holds its final frame — deliberately not
//  looping, since each video ends on a meaningful resolved state.
//

import SwiftUI
import AVFoundation
import AppKit

/// Which media the overlay is showing. `.idle` is a still image (the first
/// frame of the success video) so the transition into a playing video is
/// seamless.
enum ScanMedia: Equatable {
    case idle
    case success
    case failure

    var videoResourceName: String? {
        switch self {
        case .idle: return nil
        case .success: return "unlockanimation"
        case .failure: return "unsuccessfulunlockanimation"
        }
    }
}

struct ScanAnimationView: NSViewRepresentable {
    let media: ScanMedia

    func makeNSView(context: Context) -> ScanAnimationHostView {
        let view = ScanAnimationHostView()
        view.apply(media: media)
        return view
    }

    func updateNSView(_ nsView: ScanAnimationHostView, context: Context) {
        nsView.apply(media: media)
    }
}

/// 2.0: both videos get their own player and layer, created and buffered up front while the overlay is still in
/// `.idle`. Starting one is then a seek + play on an already-decoded layer, instead of building an `AVPlayer` and
/// waiting on decode at the exact moment the result should appear (which showed as a late start or a stutter).
final class ScanAnimationHostView: NSView {
    private struct PreparedVideo {
        let player: AVPlayer
        let layer: AVPlayerLayer
    }

    private var prepared: [ScanMedia: PreparedVideo] = [:]
    private let stillImageLayer = CALayer()
    private var currentMedia: ScanMedia?
    private var readyObservation: NSKeyValueObservation?
    private var fallbackRevealWorkItem: DispatchWorkItem?
    /// Bumped on every `apply`, so a seek completing after the media changed again can't reveal the wrong video.
    private var applyGeneration = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()

        stillImageLayer.contentsGravity = .resizeAspect
        if let still = Self.loadStillFromBundle() {
            stillImageLayer.contents = still
        }
        layer?.addSublayer(stillImageLayer)

        for media in [ScanMedia.success, .failure] {
            guard let resource = media.videoResourceName,
                  let url = Bundle.main.url(forResource: resource, withExtension: "mp4") else {
                assertionFailure("\(media) video missing from bundle — check MacFace/Resources/")
                continue
            }
            let player = AVPlayer(playerItem: AVPlayerItem(url: url))
            // This can play at the lock screen — never make noise.
            player.isMuted = true
            // Leaves the player paused on its final frame rather than rewinding.
            player.actionAtItemEnd = .none
            let playerLayer = AVPlayerLayer(player: player)
            playerLayer.videoGravity = .resizeAspect
            playerLayer.isHidden = true
            layer?.addSublayer(playerLayer)
            prepared[media] = PreparedVideo(player: player, layer: playerLayer)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stillImageLayer.frame = bounds
        for video in prepared.values { video.layer.frame = bounds }
        CATransaction.commit()
    }

    func apply(media: ScanMedia) {
        guard media != currentMedia else { return }
        currentMedia = media
        applyGeneration &+= 1
        let generation = applyGeneration
        readyObservation = nil
        fallbackRevealWorkItem?.cancel()

        // Park every other video on its first frame, hidden, ready for next time.
        for (other, video) in prepared where other != media {
            video.player.pause()
            video.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        }

        guard let video = prepared[media] else {
            show(nil)
            return
        }

        // Swaps instantly — without disabling implicit actions, toggling `isHidden` cross-fades over CALayer's default duration.
        let reveal: () -> Void = { [weak self] in
            guard let self, generation == self.applyGeneration else { return }
            self.fallbackRevealWorkItem?.cancel()
            self.readyObservation = nil
            self.show(video.layer)
        }

        video.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, generation == self.applyGeneration else { return }
                video.player.play()
                if video.layer.isReadyForDisplay {
                    reveal()
                    return
                }
                // First play only: waits for `isReadyForDisplay` rather than a fixed delay, which raced the real decode
                // time and produced a black-frame flash.
                self.readyObservation = video.layer.observe(\.isReadyForDisplay, options: [.new]) { _, change in
                    guard change.newValue == true else { return }
                    DispatchQueue.main.async { reveal() }
                }
                // Safety net only — if isReadyForDisplay never fires, don't get stuck on the still forever.
                let fallback = DispatchWorkItem { reveal() }
                self.fallbackRevealWorkItem = fallback
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: fallback)
            }
        }
    }

    /// Shows exactly one layer: the given video layer, or the still when `nil`.
    private func show(_ visible: AVPlayerLayer?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for video in prepared.values { video.layer.isHidden = video.layer !== visible }
        stillImageLayer.isHidden = visible != nil
        CATransaction.commit()
    }

    /// The asset lives in Resources/ rather than an asset catalog, so
    /// `NSImage(named:)` won't find it — load by URL instead.
    private static func loadStillFromBundle() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "unlockstatic", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }
}
