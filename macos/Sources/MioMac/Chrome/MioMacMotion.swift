// MioMacMotion.swift — 动画与配色的公共小工具：
//   - MioMotion：统一时长 / 曲线；系统「减少动态效果」打开时时长变 0（只保留淡入淡出或直接到位）
//   - MioTheme：Firefox Proton 配色（浅色 / 深色自动切换），给 CALayer 用的颜色要在当前外观下解析
//   - MioFrameMeter：CADisplayLink 计帧（CI 里证明动画期间的帧率 / 最长一帧）
//   - MioTrafficLights：把红绿灯按钮垂直居中到 40pt 高的标签条（Firefox 在 macOS 上的样子）

import AppKit
import QuartzCore

@MainActor
enum MioMotion {
    /// 测试 / CI 可强制（MIO_REDUCE_MOTION=1）
    static var forceReduce: Bool? = ProcessInfo.processInfo.environment["MIO_REDUCE_MOTION"].map { $0 == "1" }

    static var reduce: Bool { forceReduce ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    // Firefox 的节奏：标签开 / 关约 200ms，悬停 100–150ms，面板 150–200ms
    static let fast: TimeInterval = 0.12
    static let normal: TimeInterval = 0.2
    static let slow: TimeInterval = 0.28

    static func duration(_ d: TimeInterval) -> TimeInterval { reduce ? 0 : d }

    static let easeOut = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)   // 进入：快起慢收
    static let easeInOut = CAMediaTimingFunction(name: .easeInEaseOut)
    static let easeIn = CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)

    /// NSAnimationContext 包装：allowsImplicitAnimation 让 layout()/resizeSubviews 里的子视图位移一起动
    static func animate(_ d: TimeInterval = normal, timing: CAMediaTimingFunction = easeOut,
                        _ changes: @escaping () -> Void, completion: (() -> Void)? = nil) {
        let dur = duration(d)
        if dur == 0 {
            changes()
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = dur
            ctx.timingFunction = timing
            ctx.allowsImplicitAnimation = true
            changes()
        }, completionHandler: {
            MainActor.assumeIsolated { completion?() }
        })
    }

    /// CALayer 属性的显式动画（不经过 NSView）
    static func layer(_ layer: CALayer, _ key: String, from: Any?, to: Any, duration d: TimeInterval = fast,
                      timing: CAMediaTimingFunction = easeOut) {
        let dur = duration(d)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(to, forKeyPath: key)
        CATransaction.commit()
        guard dur > 0 else { return }
        let a = CABasicAnimation(keyPath: key)
        a.fromValue = from ?? layer.presentation()?.value(forKeyPath: key)
        a.toValue = to
        a.duration = dur
        a.timingFunction = timing
        layer.add(a, forKey: key)
    }
}

// MARK: - 配色（Firefox Proton）

@MainActor
enum MioTheme {
    static func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: a)
    }

    static func dyn(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { ap in ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
    }

    static let frame = dyn(hex(0xF0F0F4), hex(0x1C1B22))            // 标签条底色
    static let frameInactive = dyn(hex(0xE7E7EB), hex(0x232229))
    static let selectedTab = dyn(hex(0xFFFFFF), hex(0x42414D))
    static let hoverTab = dyn(hex(0x15141A, 0.08), hex(0xFBFBFE, 0.10))
    static let pressedTab = dyn(hex(0x15141A, 0.14), hex(0xFBFBFE, 0.16))
    static let toolbar = dyn(hex(0xF9F9FB), hex(0x2B2A33))          // 导航栏
    static let urlbar = dyn(hex(0xF0F0F4), hex(0x1C1B22))
    static let urlbarFocused = dyn(hex(0xFFFFFF), hex(0x42414D))
    static let accent = dyn(hex(0x0061E0), hex(0x00DDFF))
    static let accentText = dyn(hex(0xFFFFFF), hex(0x15141A))
    static let separator = dyn(hex(0x15141A, 0.10), hex(0xFBFBFE, 0.10))
    static let buttonHover = dyn(hex(0x15141A, 0.08), hex(0xFBFBFE, 0.10))
    static let buttonPressed = dyn(hex(0x15141A, 0.16), hex(0xFBFBFE, 0.18))
    static let panel = dyn(hex(0xFFFFFF), hex(0x42414D))
    static let panelBorder = dyn(hex(0x15141A, 0.12), hex(0xFBFBFE, 0.14))
    static let text = dyn(hex(0x15141A), hex(0xFBFBFE))
    static let secondaryText = dyn(hex(0x5B5B66), hex(0xCFCFD8))
    static let throbber = dyn(hex(0x0061E0), hex(0x00DDFF))
    static let mio = hex(0x7542E5)                                   // Mio 首页标识色

    /// 在 view 的当前外观下取 CGColor（CALayer 不会自己跟随浅色 / 深色）
    static func cg(_ c: NSColor, in view: NSView) -> CGColor {
        var out = c.cgColor
        view.effectiveAppearance.performAsCurrentDrawingAppearance { out = c.cgColor }
        return out
    }

    static func symbol(_ name: String, _ size: CGFloat = 14, weight: NSFont.Weight = .regular, label: String? = nil) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: label)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: weight))
    }
}

// MARK: - 计帧（CADisplayLink，macOS 14+）

@MainActor
final class MioFrameMeter: NSObject {
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private(set) var frames = 0
    private(set) var maxGap: CFTimeInterval = 0
    private var gaps: [CFTimeInterval] = []
    private var started: CFTimeInterval = 0

    func start(on view: NSView) {
        stop()
        frames = 0; maxGap = 0; gaps = []; last = 0
        started = CACurrentMediaTime()
        let l = view.displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func tick(_ l: CADisplayLink) {
        let t = l.timestamp
        if last > 0 {
            let g = t - last
            gaps.append(g)
            maxGap = max(maxGap, g)
        }
        last = t
        frames += 1
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    var report: [String: Any] {
        let elapsed = max(0.001, CACurrentMediaTime() - started)
        let sorted = gaps.sorted()
        let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        let longFrames = gaps.filter { $0 > 1.0 / 40 }.count // 掉到 40fps 以下的帧
        return ["frames": frames, "seconds": (elapsed * 100).rounded() / 100, "fps": (Double(frames) / elapsed * 10).rounded() / 10,
                "maxFrameMs": (maxGap * 10000).rounded() / 10, "p95FrameMs": (p95 * 10000).rounded() / 10, "longFrames": longFrames,
                "screenMaxFPS": NSScreen.main?.maximumFramesPerSecond ?? 0]
    }
}

// MARK: - 红绿灯

@MainActor
enum MioTrafficLights {
    /// 把 关闭 / 最小化 / 缩放 按钮垂直居中到窗口顶部 rowHeight 高的一行（标签条）里。AppKit 改尺寸 / 切换前后台时会重排，所以要反复调用
    static func center(in window: NSWindow, rowHeight: CGFloat, leading: CGFloat = 13) {
        guard !window.styleMask.contains(.fullScreen) else { return }
        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let buttons = types.compactMap { window.standardWindowButton($0) }
        guard let first = buttons.first, let container = first.superview else { return }
        let h = first.frame.height
        // 按钮所在视图的坐标（非翻转：原点在左下）
        var y = container.bounds.height - (rowHeight / 2 + h / 2)
        if container.isFlipped { y = rowHeight / 2 - h / 2 }
        if y < 0, let titlebar = container.superview {
            // 标题栏比一行矮：把标题栏容器加高（Electron trafficLightPosition 的做法）
            var f = titlebar.frame
            f.size.height = rowHeight
            f.origin.y = window.frame.height - rowHeight
            titlebar.frame = f
            y = container.isFlipped ? rowHeight / 2 - h / 2 : container.bounds.height - (rowHeight / 2 + h / 2)
        }
        let spacing: CGFloat = 20
        for (i, b) in buttons.enumerated() {
            let o = NSPoint(x: leading + CGFloat(i) * spacing, y: max(0, y).rounded())
            if b.frame.origin != o { b.setFrameOrigin(o) }
        }
    }

    /// 红绿灯占的宽度（标签条左边留空）
    static let reservedWidth: CGFloat = 80
}
