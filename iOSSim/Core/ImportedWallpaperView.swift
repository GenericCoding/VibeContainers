import AVFoundation
import ImageIO
import SwiftUI
import UIKit

@_silgen_name("IOSSimCreateTendiesLayer")
private func IOSSimCreateTendiesLayer(_ path: UnsafePointer<CChar>) -> UnsafeMutableRawPointer?

@_silgen_name("IOSSimSetTendiesLayerState")
private func IOSSimSetTendiesLayerState(
    _ layer: UnsafeMutableRawPointer?,
    _ state: UnsafePointer<CChar>,
    _ animated: Int32
)

struct ImportedWallpaperView: View {
    let item: ImportedWallpaper
    let url: URL
    let animates: Bool

    var body: some View {
        switch item.renderer {
        case .image:
            WallpaperImageView(url: url)
        case .gif:
            GIFWallpaperView(url: url, animates: animates)
        case .video:
            VideoWallpaperView(url: url, plays: animates)
        case .tendiesLayers:
            TendiesWallpaperView(packageRoot: url, animates: animates)
        }
    }
}

private struct WallpaperImageView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
        view.image = UIImage(contentsOfFile: url.path)
        return view
    }

    func updateUIView(_ view: UIImageView, context: Context) {
        if context.coordinator.url != url {
            context.coordinator.url = url
            view.image = UIImage(contentsOfFile: url.path)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator {
        var url: URL
        init(url: URL) { self.url = url }
    }
}

private struct GIFWallpaperView: UIViewRepresentable {
    let url: URL
    let animates: Bool

    func makeUIView(context: Context) -> AnimatedGIFImageView {
        let view = AnimatedGIFImageView(frame: .zero)
        view.load(url)
        view.setPlaying(animates)
        return view
    }

    func updateUIView(_ view: AnimatedGIFImageView, context: Context) {
        if view.url != url { view.load(url) }
        view.setPlaying(animates)
    }
}

/// Decodes one GIF frame at a time. A wallpaper can have hundreds of full-
/// screen frames, so retaining a `[UIImage]` for the whole animation can use
/// gigabytes even when the source file itself is small.
private final class AnimatedGIFImageView: UIImageView {
    private var source: CGImageSource?
    private var frameCount = 0
    private var frameIndex = 0
    private var timer: Timer?
    private var isPlaying = false
    private(set) var url: URL?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentMode = .scaleAspectFill
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { nil }

    deinit { timer?.invalidate() }

    func load(_ url: URL) {
        timer?.invalidate()
        self.url = url
        source = CGImageSourceCreateWithURL(url as CFURL, nil)
        frameCount = source.map { CGImageSourceGetCount($0) } ?? 0
        frameIndex = 0
        showFrame(0)
        if isPlaying { scheduleNextFrame() }
    }

    func setPlaying(_ shouldPlay: Bool) {
        guard isPlaying != shouldPlay else { return }
        isPlaying = shouldPlay
        timer?.invalidate()
        timer = nil
        if shouldPlay { scheduleNextFrame() }
        else {
            frameIndex = 0
            showFrame(0)
        }
    }

    private func scheduleNextFrame() {
        guard isPlaying, frameCount > 1, let source else { return }
        let timer = Timer(timeInterval: Self.frameDelay(source: source, index: frameIndex),
                          repeats: false) { [weak self] _ in
            guard let self else { return }
            self.frameIndex = (self.frameIndex + 1) % self.frameCount
            self.showFrame(self.frameIndex)
            self.scheduleNextFrame()
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func showFrame(_ index: Int) {
        guard let source,
              index < frameCount,
              let frame = CGImageSourceCreateImageAtIndex(source, index, nil) else { return }
        image = UIImage(cgImage: frame)
    }

    private static func frameDelay(source: CGImageSource, index: Int) -> TimeInterval {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any] else {
            return 0.1
        }
        let unclamped = gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double
        let clamped = gif[kCGImagePropertyGIFDelayTime] as? Double
        return max(unclamped ?? clamped ?? 0.1, 0.02)
    }
}

private struct VideoWallpaperView: UIViewRepresentable {
    let url: URL
    let plays: Bool

    func makeUIView(context: Context) -> LoopingVideoView {
        let view = LoopingVideoView()
        view.load(url)
        view.setPlaying(plays)
        return view
    }

    func updateUIView(_ view: LoopingVideoView, context: Context) {
        if view.url != url { view.load(url) }
        view.setPlaying(plays)
    }
}

private final class LoopingVideoView: UIView {
    private let playerLayer = AVPlayerLayer()
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private(set) var url: URL?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        playerLayer.videoGravity = .resizeAspectFill
        layer.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
    }

    func load(_ url: URL) {
        self.url = url
        let player = AVQueuePlayer()
        player.isMuted = true
        player.actionAtItemEnd = .none
        let item = AVPlayerItem(url: url)
        self.player = player
        looper = AVPlayerLooper(player: player, templateItem: item)
        playerLayer.player = player
    }

    func setPlaying(_ shouldPlay: Bool) {
        if shouldPlay { player?.play() } else { player?.pause() }
    }
}

private struct TendiesWallpaperView: UIViewRepresentable {
    let packageRoot: URL
    let animates: Bool

    func makeUIView(context: Context) -> TendiesHostView {
        let view = TendiesHostView()
        view.load(packageRoot, animates: animates)
        return view
    }

    func updateUIView(_ view: TendiesHostView, context: Context) {
        if view.packageRoot != packageRoot {
            view.load(packageRoot, animates: animates)
        } else {
            view.setAnimates(animates)
        }
    }
}

private final class TendiesHostView: UIView {
    private var packageLayers: [CALayer] = []
    private var fallbackImageView: UIImageView?
    private var shouldAnimate = true
    private(set) var packageRoot: URL?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { nil }

    func load(_ packageRoot: URL, animates: Bool) {
        packageLayers.forEach { $0.removeFromSuperlayer() }
        packageLayers.removeAll()
        fallbackImageView?.removeFromSuperview()
        fallbackImageView = nil
        self.packageRoot = packageRoot
        shouldAnimate = animates

        for package in Self.animationPackages(in: packageRoot) {
            let pointer = package.path.withCString { IOSSimCreateTendiesLayer($0) }
            guard let pointer else { continue }
            let packageLayer = Unmanaged<CALayer>.fromOpaque(pointer).takeRetainedValue()
            packageLayers.append(packageLayer)
            layer.addSublayer(packageLayer)
        }

        if packageLayers.isEmpty, let imageURL = Self.largestImage(in: packageRoot) {
            let imageView = UIImageView(image: UIImage(contentsOfFile: imageURL.path))
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            addSubview(imageView)
            fallbackImageView = imageView
        }

        setNeedsLayout()
        setState("Locked", animated: false)
        if !animates { packageLayers.forEach(Self.pause) }
    }

    func setAnimates(_ animates: Bool) {
        guard shouldAnimate != animates else { return }
        shouldAnimate = animates
        packageLayers.forEach(animates ? Self.resume : Self.pause)
        setState("Locked", animated: false)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        fallbackImageView?.frame = bounds

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for packageLayer in packageLayers {
            let designSize = packageLayer.bounds.size
            guard designSize.width > 0, designSize.height > 0 else {
                packageLayer.frame = bounds
                continue
            }
            let scale = max(bounds.width / designSize.width, bounds.height / designSize.height)
            packageLayer.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
            packageLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        }
        CATransaction.commit()
    }

    private func setState(_ name: String, animated: Bool) {
        for root in packageLayers {
            name.withCString {
                IOSSimSetTendiesLayerState(
                    Unmanaged.passUnretained(root).toOpaque(),
                    $0,
                    animated ? 1 : 0
                )
            }
        }
    }

    private static func pause(_ layer: CALayer) {
        guard layer.speed != 0 else { return }
        let pausedTime = layer.convertTime(CACurrentMediaTime(), from: nil)
        layer.speed = 0
        layer.timeOffset = pausedTime
    }

    private static func resume(_ layer: CALayer) {
        guard layer.speed == 0 else { return }
        let pausedTime = layer.timeOffset
        layer.speed = 1
        layer.timeOffset = 0
        layer.beginTime = 0
        layer.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - pausedTime
    }

    private static func animationPackages(in root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var packages: [URL] = []
        for case let url as URL in enumerator where url.lastPathComponent == "main.caml" {
            packages.append(url.deletingLastPathComponent())
        }
        return packages.sorted { packageOrder($0) < packageOrder($1) }
    }

    private static func packageOrder(_ url: URL) -> Int {
        let name = url.lastPathComponent.lowercased()
        if name.contains("background") { return 0 }
        if name.contains("floating") { return 1 }
        if name.contains("foreground") { return 2 }
        return 1
    }

    private static func largestImage(in root: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let extensions = Set(["png", "jpg", "jpeg", "heic", "heif", "webp"])
        var result: URL?
        var resultSize = 0
        for case let url as URL in enumerator where extensions.contains(url.pathExtension.lowercased()) {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > resultSize {
                result = url
                resultSize = size
            }
        }
        return result
    }
}
