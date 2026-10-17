// MioMacRecorder.swift — CI 冒烟用的「动画证据」：
//   - 屏幕区域截图（含子窗口：弹出面板、地址栏下拉、拖出的缩略图）——CGWindowListCreateImage（macOS 15 SDK 里已弃用，用 dlsym 调；
//     CI 机器有屏幕录制权限，本机没有权限时返回 nil，调用方退回 cacheDisplay）
//   - 录屏：定时抓帧写 H.264 .mov（AVAssetWriter）
//   - 连拍：动画进行中每隔 N 毫秒抓一帧，拼成一张「帧条」PNG（PR 里直接看动画中间态）

import AppKit
import AVFoundation
import CoreVideo

@MainActor
final class MioMacRecorder {
    private typealias CreateImageFn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    private static let createImage: CreateImageFn? = {
        guard let h = dlopen(nil, RTLD_NOW), let sym = dlsym(h, "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(sym, to: CreateImageFn.self)
    }()

    /// 屏幕区域（AppKit 屏幕坐标，原点左下）→ CGImage（逻辑分辨率）
    static func capture(screenRect r: NSRect) -> CGImage? {
        guard let fn = createImage, let primary = NSScreen.screens.first else { return nil }
        let cg = CGRect(x: r.minX, y: primary.frame.height - r.maxY, width: r.width, height: r.height)
        // kCGWindowListOptionOnScreenOnly = 1, kCGNullWindowID = 0, kCGWindowImageNominalResolution = 1 << 4
        return fn(cg, 1, 0, 1 << 4)?.takeRetainedValue()
    }

    static func capture(window: NSWindow?, margin: CGFloat = 0) -> CGImage? {
        guard let w = window else { return nil }
        return capture(screenRect: w.frame.insetBy(dx: -margin, dy: -margin))
    }

    @discardableResult
    static func savePNG(_ img: CGImage?, to path: String) -> Bool {
        guard let img else { return false }
        let rep = NSBitmapImageRep(cgImage: img)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }

    // MARK: 录屏

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var timer: Timer?
    private var started: CFTimeInterval = 0
    private(set) var frames = 0
    private(set) var dropped = 0
    private var size = CGSize.zero
    private var rect: () -> NSRect = { .zero }
    private(set) var path: String?
    private var lastTime: CMTime = .invalid

    func start(path: String, fps: Double = 20, rect: @escaping () -> NSRect) {
        self.rect = rect
        let r = rect()
        let w = Int(r.width) / 2 * 2
        let h = Int(r.height) / 2 * 2
        guard w > 0, h > 0, Self.capture(screenRect: r) != nil else { return }
        try? FileManager.default.removeItem(atPath: path)
        guard let wr = try? AVAssetWriter(outputURL: URL(fileURLWithPath: path), fileType: .mov) else { return }
        let settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
                                       AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 4_000_000]]
        let inp = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        inp.expectsMediaDataInRealTime = true
        let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: inp, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        guard wr.canAdd(inp) else { return }
        wr.add(inp)
        guard wr.startWriting() else { return }
        wr.startSession(atSourceTime: .zero)
        writer = wr; input = inp; adaptor = ad
        size = CGSize(width: w, height: h)
        self.path = path
        started = CACurrentMediaTime()
        let t = Timer(timeInterval: 1 / fps, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    private func tick() {
        guard let inp = input, let ad = adaptor, inp.isReadyForMoreMediaData, let img = Self.capture(screenRect: rect()),
              let pool = ad.pixelBufferPool else { dropped += 1; return }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        guard let buf = pb else { dropped += 1; return }
        CVPixelBufferLockBaseAddress(buf, [])
        if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buf), width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                               bytesPerRow: CVPixelBufferGetBytesPerRow(buf), space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
            ctx.interpolationQuality = .medium
            ctx.draw(img, in: CGRect(origin: .zero, size: size))
        }
        CVPixelBufferUnlockBaseAddress(buf, [])
        let t = CMTime(seconds: CACurrentMediaTime() - started, preferredTimescale: 600)
        if lastTime.isValid && CMTimeCompare(t, lastTime) <= 0 { return }
        if ad.append(buf, withPresentationTime: t) { frames += 1; lastTime = t } else { dropped += 1 }
    }

    func stop() async -> [String: Any] {
        timer?.invalidate()
        timer = nil
        guard let wr = writer, let inp = input else { return ["recorded": false] }
        inp.markAsFinished()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in wr.finishWriting { c.resume() } }
        let ok = wr.status == .completed
        writer = nil; input = nil; adaptor = nil
        let secs = CACurrentMediaTime() - started
        return ["recorded": ok, "path": path ?? "", "frames": frames, "dropped": dropped, "seconds": (secs * 10).rounded() / 10,
                "error": wr.error.map { "\($0)" as Any } ?? NSNull()]
    }

    // MARK: 连拍 → 帧条

    /// 每 intervalMs 毫秒抓一次 rect（屏幕坐标），共 count 帧
    static func burst(count: Int, intervalMs: UInt64, rect: @escaping () -> NSRect) async -> [(image: CGImage, ms: Int)] {
        var out: [(image: CGImage, ms: Int)] = []
        let t0 = CACurrentMediaTime()
        for _ in 0..<count {
            if let img = capture(screenRect: rect()) { out.append((img, Int((CACurrentMediaTime() - t0) * 1000))) }
            try? await Task.sleep(nanoseconds: intervalMs * 1_000_000)
        }
        return out
    }

    /// 帧条：竖排（每帧一行，左侧标时间）
    @discardableResult
    static func saveStrip(_ frames: [CGImage], times: [Int], title: String, to path: String) -> Bool {
        guard let first = frames.first else { return false }
        let w = CGFloat(first.width), h = CGFloat(first.height)
        let label: CGFloat = 70
        let header: CGFloat = 28
        let total = NSSize(width: w + label, height: header + h * CGFloat(frames.count))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(total.width), pixelsHigh: Int(total.height), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return false }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        NSColor.white.setFill()
        NSRect(origin: .zero, size: total).fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.darkGray]
        (title as NSString).draw(at: NSPoint(x: 8, y: total.height - header + 7), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: NSColor.black])
        for (i, f) in frames.enumerated() {
            let y = total.height - header - h * CGFloat(i + 1)
            ctx.cgContext.draw(f, in: CGRect(x: label, y: y, width: w, height: h))
            ("+\(i < times.count ? times[i] : 0)ms" as NSString).draw(at: NSPoint(x: 6, y: y + h / 2 - 7), withAttributes: attrs)
            NSColor(white: 0.85, alpha: 1).setFill()
            NSRect(x: 0, y: y, width: total.width, height: 1).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }

    /// 两帧是否不同（证明动画期间画面在变）
    static func differs(_ a: CGImage, _ b: CGImage) -> Bool {
        guard a.width == b.width, a.height == b.height,
              let da = a.dataProvider?.data, let db = b.dataProvider?.data else { return true }
        return da as Data != db as Data
    }
}
