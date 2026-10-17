// MioMacTabBar.swift — Firefox 桌面式横向标签条（在导航栏上方、与红绿灯同一行）：
//   - 标签平分宽度（76…225pt），固定标签只显示图标；放不下时横向滚动（滚轮竖向也能滚、选中标签自动滚到可见、两端渐隐）
//   - 新建「+」紧跟最后一个标签；溢出时「+」移到右端固定；右端「列出所有标签页」
//   - 打开：宽度从 0 展开 + 淡入；关闭：收缩到 0 + 淡出，其余标签平滑补位；用鼠标关闭时宽度锁定，鼠标离开标签条后再展开
//   - 拖拽排序：被拖标签跟手（抬起阴影），其他标签让位动画；拖出标签条 → 浮动缩略图跟随，松手成新窗口
//   - 悬停高亮淡入淡出；关闭按钮悬停（或选中）时出现；加载中显示转圈；播放声音 / 静音图标可点
//   - 空白处拖动窗口、双击按系统设置缩放 / 最小化窗口

import AppKit
import QuartzCore

@MainActor
final class MioMacTabBar: NSView {
    struct Item: Equatable {
        var id: Int
        var title: String
        var color: NSColor?
        var pinned: Bool
        var loading: Bool
        var audible: Bool
        var muted: Bool
        var favicon: NSImage?
        var isHome: Bool

        static func == (a: Item, b: Item) -> Bool {
            a.id == b.id && a.title == b.title && a.color == b.color && a.pinned == b.pinned && a.loading == b.loading
                && a.audible == b.audible && a.muted == b.muted && a.favicon === b.favicon && a.isHome == b.isHome
        }
    }

    static let height: CGFloat = 40
    static let tabHeight: CGFloat = 32

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onNewTab: (() -> Void)?
    var onMove: ((Int, Int) -> Void)?                 // (tab id, 新下标)
    var onDetach: ((Int, NSPoint) -> Void)?           // (tab id, 屏幕坐标)
    var onToggleMute: ((Int) -> Void)?
    var onListAll: ((NSView) -> Void)?
    var contextMenu: ((Int) -> NSMenu?)?
    var canDetach: (() -> Bool)?

    private(set) var items: [Item] = []
    private(set) var activeID: Int?
    private(set) var tabViews: [Int: MioMacTabView] = [:]
    private var closing: [MioMacTabView] = []
    private let scroll = MioMacTabScrollView()
    private let doc = MioMacTabDocView()
    let newTabInline = MioMacToolbarButton(symbol: "plus", size: 14, label: "新建标签页 (⌘T)")
    let newTabTrailing = MioMacToolbarButton(symbol: "plus", size: 14, label: "新建标签页 (⌘T)")
    let listAllButton = MioMacToolbarButton(symbol: "chevron.down", size: 12, label: "列出所有标签页", weight: .semibold)
    private let fadeMask = CAGradientLayer()
    private(set) var layoutResult = MioTabLayout.Result(xs: [], widths: [], contentWidth: 0, overflow: false, tabWidth: 225)
    private var lockedWidth: Double?
    private var tracking: NSTrackingArea?

    /// 红绿灯让位（全屏时变小，带动画）
    var leadingInset: CGFloat = MioTrafficLights.reservedWidth {
        didSet { guard oldValue != leadingInset else { return }; MioMotion.animate(MioMotion.normal, { self.layoutAll(animated: true) }) }
    }

    // 拖拽
    private struct Drag {
        var id: Int
        var startPoint: NSPoint      // 标签条坐标
        var startX: CGFloat          // 被拖标签起始 x（doc 坐标）
        var from: Int
        var target: Int
        var active = false
        var detaching = false
    }
    private var drag: Drag?
    private var dragWindow: NSWindow?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .allowed
        scroll.verticalScrollElasticity = .none
        scroll.documentView = doc
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.wantsLayer = true
        addSubview(scroll)
        doc.bar = self
        doc.addSubview(newTabInline)
        for b in [newTabTrailing, listAllButton] { addSubview(b) }
        newTabInline.onClick = { [weak self] in self?.onNewTab?() }
        newTabTrailing.onClick = { [weak self] in self?.onNewTab?() }
        newTabTrailing.alphaValue = 0
        listAllButton.triggersOnMouseDown = true
        listAllButton.onClick = { [weak self] in guard let self else { return }; self.onListAll?(self.listAllButton) }
        fadeMask.startPoint = CGPoint(x: 0, y: 0.5)
        fadeMask.endPoint = CGPoint(x: 1, y: 0.5)
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled(_:)), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("标签页")
        setAccessibilityIdentifier("mio.tabbar")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
        NotificationCenter.default.addObserver(self, selector: #selector(keyChanged(_:)), name: NSWindow.didBecomeKeyNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(keyChanged(_:)), name: NSWindow.didResignKeyNotification, object: window)
    }

    @objc private func keyChanged(_ n: Notification) { applyColors() }

    func applyColors() {
        let key = window?.isKeyWindow ?? true
        layer?.backgroundColor = MioTheme.cg(key ? MioTheme.frame : MioTheme.frameInactive, in: self)
        for v in tabViews.values { v.refresh(animated: false) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseExited(with event: NSEvent) {
        // Firefox：关标签后宽度先锁住，鼠标离开标签条再平滑展开
        guard lockedWidth != nil, drag == nil else { return }
        lockedWidth = nil
        MioMotion.animate(MioMotion.normal, { self.layoutAll(animated: true) })
    }

    // MARK: 数据

    func reload(tabs: [Item], activeID: Int?, animated: Bool = true) {
        let oldIDs = items.map(\.id)
        let newIDs = tabs.map(\.id)
        let changed = tabs != items || activeID != self.activeID
        guard changed else { return }
        let removed = Set(oldIDs).subtracting(newIDs)
        let inserted = Set(newIDs).subtracting(oldIDs)
        items = tabs
        let activeChanged = activeID != self.activeID
        self.activeID = activeID
        let anim = animated && !oldIDs.isEmpty && MioMotion.duration(MioMotion.normal) > 0

        for id in removed {
            guard let v = tabViews.removeValue(forKey: id) else { continue }
            if anim {
                closing.append(v)
                v.isClosing = true
                MioMotion.animate(MioMotion.normal, timing: MioMotion.easeOut, {
                    v.animator().frame = NSRect(x: v.frame.minX, y: v.frame.minY, width: 0, height: v.frame.height)
                    v.animator().alphaValue = 0
                }, completion: { [weak self] in
                    v.removeFromSuperview()
                    self?.closing.removeAll { $0 === v }
                })
            } else {
                v.removeFromSuperview()
            }
        }
        for t in tabs {
            if let v = tabViews[t.id] {
                v.update(t, active: t.id == activeID)
            } else {
                let v = MioMacTabView(item: t, active: t.id == activeID)
                v.bar = self
                tabViews[t.id] = v
                doc.addSubview(v)
            }
        }
        if !inserted.isEmpty { lockedWidth = nil }
        // 选中标签放到最上层（阴影不被邻居盖住）
        if let a = activeID, let v = tabViews[a] { v.layer?.zPosition = 1 }
        for (id, v) in tabViews where id != activeID { v.layer?.zPosition = 0 }

        if anim {
            // 新标签从 0 宽度展开
            let result = computeLayout()
            for id in inserted {
                guard let v = tabViews[id], let i = newIDs.firstIndex(of: id) else { continue }
                let x = CGFloat(result.xs[i]) + 0
                v.frame = NSRect(x: x, y: tabY, width: 0, height: Self.tabHeight)
                v.alphaValue = 0
            }
            MioMotion.animate(MioMotion.normal, {
                self.layoutAll(animated: true)
                for id in inserted { self.tabViews[id]?.animator().alphaValue = 1 }
            })
        } else {
            layoutAll(animated: false)
        }
        if activeChanged || !inserted.isEmpty { revealActive(animated: anim) }
    }

    func setLoading(_ id: Int, _ loading: Bool) {
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].loading != loading else { return }
        items[i].loading = loading
        tabViews[id]?.update(items[i], active: id == activeID)
    }

    // MARK: 布局

    private var tabY: CGFloat { ((Self.height - Self.tabHeight) / 2).rounded() }
    private let buttonSize: CGFloat = 28

    private var trailingControlsWidth: CGFloat { buttonSize + 8 + (layoutResult.overflow ? buttonSize + 2 : 0) }

    private func computeLayout() -> MioTabLayout.Result {
        let scrollWidth = max(0, bounds.width - leadingInset - (buttonSize + 8))
        // 先按「不溢出」算（留出内联 + 按钮）；溢出了就把 + 挪到右端，可用宽度相应变小
        var r = MioTabLayout.layout(pinned: items.map(\.pinned), available: Double(scrollWidth - buttonSize - 4), lockedWidth: lockedWidth)
        if r.overflow {
            r = MioTabLayout.layout(pinned: items.map(\.pinned), available: Double(scrollWidth - buttonSize - 2), lockedWidth: lockedWidth)
            r.overflow = true
        }
        return r
    }

    override func layout() {
        super.layout()
        layoutAll(animated: false)
    }

    func layoutAll(animated: Bool) {
        let r = computeLayout()
        let overflowChanged = r.overflow != layoutResult.overflow
        layoutResult = r
        let h = Self.height
        // 右端：列出所有标签页；溢出时 + 也在右端
        let listFrame = NSRect(x: bounds.width - buttonSize - 6, y: (h - buttonSize) / 2, width: buttonSize, height: buttonSize)
        let trailingFrame = NSRect(x: listFrame.minX - buttonSize - 2, y: listFrame.minY, width: buttonSize, height: buttonSize)
        let scrollRight = r.overflow ? trailingFrame.minX - 2 : listFrame.minX - 2
        let scrollFrame = NSRect(x: leadingInset, y: 0, width: max(0, scrollRight - leadingInset), height: h)
        let docWidth = max(scrollFrame.width, CGFloat(r.contentWidth) + (r.overflow ? 4 : buttonSize + 8))
        let target = animated ? { (v: NSView) -> NSView in v.animator() } : { (v: NSView) -> NSView in v }
        target(listAllButton).frame = listFrame
        target(newTabTrailing).frame = trailingFrame
        if overflowChanged || !animated {
            target(newTabTrailing).alphaValue = r.overflow ? 1 : 0
            target(newTabInline).alphaValue = r.overflow ? 0 : 1
        }
        scroll.frame = scrollFrame
        doc.frame = NSRect(x: 0, y: 0, width: docWidth, height: h)
        for (i, t) in items.enumerated() {
            guard let v = tabViews[t.id], i < r.xs.count else { continue }
            if let d = drag, d.active, d.id == t.id { continue } // 被拖的标签跟手
            let f = NSRect(x: CGFloat(r.xs[i]), y: tabY, width: CGFloat(r.widths[i]), height: Self.tabHeight)
            if v.frame != f { target(v).frame = f }
        }
        let plusX = CGFloat(r.contentWidth) + 4
        target(newTabInline).frame = NSRect(x: plusX, y: (h - buttonSize) / 2, width: buttonSize, height: buttonSize)
        updateFades()
    }

    // MARK: 滚动

    func revealActive(animated: Bool) {
        guard let a = activeID, let i = items.firstIndex(where: { $0.id == a }), i < layoutResult.xs.count else { return }
        let clip = scroll.contentView
        let offset = Double(clip.bounds.origin.x)
        guard let o = MioTabLayout.scrollOffset(revealing: layoutResult.xs[i], width: layoutResult.widths[i], offset: offset,
                                                visible: Double(clip.bounds.width), content: Double(doc.frame.width)) else { return }
        let p = NSPoint(x: CGFloat(o), y: 0)
        if animated && MioMotion.duration(MioMotion.slow) > 0 {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = MioMotion.slow
                ctx.timingFunction = MioMotion.easeInOut
                clip.animator().setBoundsOrigin(p)
            }
        } else {
            clip.setBoundsOrigin(p)
        }
        scroll.reflectScrolledClipView(clip)
    }

    @objc private func scrolled(_ n: Notification) { updateFades() }

    /// 溢出时两端渐隐（滚到头的那一端不渐隐）
    private func updateFades() {
        guard let l = scroll.layer else { return }
        guard layoutResult.overflow else { l.mask = nil; return }
        let clip = scroll.contentView.bounds
        let w = max(1, clip.width)
        let fade = min(0.08, 24 / w)
        let atStart = clip.minX <= 1
        let atEnd = clip.maxX >= doc.frame.width - 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fadeMask.frame = scroll.bounds
        let clear = NSColor.clear.cgColor, solid = NSColor.black.cgColor
        fadeMask.colors = [atStart ? solid : clear, solid, solid, atEnd ? solid : clear]
        fadeMask.locations = [0, NSNumber(value: Double(fade)), NSNumber(value: Double(1 - fade)), 1]
        l.mask = fadeMask
        CATransaction.commit()
    }

    // MARK: 空白处：拖动窗口 / 双击

    func backgroundMouseDown(_ event: NSEvent) {
        if event.clickCount == 2 {
            let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
            if action == "Minimize" { window?.performMiniaturize(nil) } else if action != "None" { window?.performZoom(nil) }
            return
        }
        window?.performDrag(with: event)
    }

    override func mouseDown(with event: NSEvent) { backgroundMouseDown(event) }

    override func scrollWheel(with event: NSEvent) { scroll.scrollWheel(with: event) }

    // MARK: 关闭（鼠标点 ×：锁定宽度）

    func closeFromMouse(_ id: Int) {
        if layoutResult.tabWidth < 225 { lockedWidth = layoutResult.tabWidth }
        onClose?(id)
    }

    // MARK: 拖拽排序 / 拖出

    func pressBegan(_ id: Int, event: NSEvent) {
        guard let v = tabViews[id], let from = items.firstIndex(where: { $0.id == id }) else { return }
        drag = Drag(id: id, startPoint: convert(event.locationInWindow, from: nil), startX: v.frame.minX, from: from, target: from)
        if id != activeID { onSelect?(id) } // Firefox：按下就切换
    }

    func pressDragged(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let screen = window?.convertPoint(toScreen: event.locationInWindow) ?? .zero
        dragMoved(to: p, screenPoint: screen)
    }

    func pressEnded(_ event: NSEvent) {
        let screen = window?.convertPoint(toScreen: event.locationInWindow) ?? .zero
        dragEnded(screenPoint: screen)
    }

    /// 也给冒烟用（模拟拖拽）：p 是标签条坐标
    func dragMoved(to p: NSPoint, screenPoint: NSPoint) {
        guard var d = drag, let v = tabViews[d.id] else { return }
        let dx = p.x - d.startPoint.x
        let dy = p.y - d.startPoint.y
        if !d.active {
            guard abs(dx) > 4 || abs(dy) > 6 else { return }
            d.active = true
            v.setLifted(true)
            v.layer?.zPosition = 10
        }
        let item = items[d.from]
        // 允许的区间：固定标签在固定区内，普通标签在普通区内
        let pinnedCount = items.filter(\.pinned).count
        let allowed = item.pinned ? 0...max(0, pinnedCount - 1) : min(pinnedCount, items.count - 1)...(items.count - 1)
        let outside = MioTabLayout.isDetach(verticalDistance: Double(max(-p.y, p.y - bounds.height)))
        if outside && (canDetach?() ?? false) {
            if !d.detaching { d.detaching = true; showDragWindow(for: v) }
            moveDragWindow(to: screenPoint)
        } else if d.detaching {
            d.detaching = false
            hideDragWindow()
        }
        v.alphaValue = d.detaching ? 0.35 : 1
        // 跟手（限制在标签区内）
        let minX = CGFloat(layoutResult.xs[allowed.lowerBound])
        let maxX = CGFloat(layoutResult.xs[allowed.upperBound])
        let x = max(minX, min(maxX, d.startX + dx))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        v.frame.origin.x = x
        CATransaction.commit()
        // 让位
        let mids = zip(layoutResult.xs, layoutResult.widths).map { $0 + $1 / 2 }
        let target = MioTabLayout.dropIndex(center: Double(x + v.frame.width / 2), mids: mids, from: d.from, allowed: allowed)
        if target != d.target {
            d.target = target
            drag = d
            shiftOthers(for: d)
        }
        drag = d
    }

    private func shiftOthers(for d: Drag) {
        // 固定标签只在固定区里换位，所以第 i 个槽位的 x 不变：直接用当前布局的槽位
        let order = MioTabLayout.reordered(items, from: d.from, to: d.target)
        let xs = layoutResult.xs
        MioMotion.animate(MioMotion.fast + 0.03, {
            for (i, t) in order.enumerated() where t.id != d.id {
                guard let v = self.tabViews[t.id], i < xs.count else { continue }
                v.animator().frame.origin.x = CGFloat(xs[i])
            }
        })
    }

    func dragEnded(screenPoint: NSPoint) {
        guard let d = drag else { return }
        drag = nil
        guard d.active, let v = tabViews[d.id] else { return }
        v.setLifted(false)
        v.alphaValue = 1
        if d.detaching {
            hideDragWindow()
            v.layer?.zPosition = d.id == activeID ? 1 : 0
            layoutAll(animated: false)
            onDetach?(d.id, screenPoint)
            return
        }
        v.layer?.zPosition = d.id == activeID ? 1 : 0
        if d.target != d.from { onMove?(d.id, d.target) }
        MioMotion.animate(MioMotion.fast + 0.03, { self.layoutAll(animated: true) })
    }

    func beginProgrammaticDrag(_ id: Int) {
        guard let v = tabViews[id], let from = items.firstIndex(where: { $0.id == id }) else { return }
        drag = Drag(id: id, startPoint: NSPoint(x: v.frame.midX + tabsOriginX, y: Self.height / 2), startX: v.frame.minX, from: from, target: from)
    }

    var dragStartPoint: NSPoint? { drag?.startPoint }

    // 拖出时的浮动缩略图
    private func showDragWindow(for v: MioMacTabView) {
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        let img = NSImage(size: v.bounds.size)
        img.addRepresentation(rep)
        let w = NSPanel(contentRect: NSRect(origin: .zero, size: NSSize(width: v.bounds.width, height: v.bounds.height)),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.level = .floating
        w.ignoresMouseEvents = true
        let iv = NSImageView(image: img)
        iv.wantsLayer = true
        iv.layer?.cornerRadius = 6
        iv.layer?.masksToBounds = true
        iv.layer?.backgroundColor = MioTheme.cg(MioTheme.selectedTab, in: v)
        w.contentView = iv
        w.alphaValue = 0
        w.orderFront(nil)
        MioMotion.animate(MioMotion.fast, { w.animator().alphaValue = 0.92 })
        dragWindow = w
    }

    private func moveDragWindow(to p: NSPoint) {
        guard let w = dragWindow else { return }
        w.setFrameOrigin(NSPoint(x: p.x - w.frame.width / 2, y: p.y - w.frame.height / 2))
    }

    private func hideDragWindow() {
        guard let w = dragWindow else { return }
        dragWindow = nil
        MioMotion.animate(MioMotion.fast, { w.animator().alphaValue = 0 }, completion: { w.orderOut(nil) })
    }

    // MARK: 截图 / 冒烟

    var tabFrames: [Int: NSRect] { tabViews.mapValues { $0.frame } }
    /// 标签（doc 坐标）→ 标签条坐标的 x 偏移
    var tabsOriginX: CGFloat { scroll.frame.minX - scroll.contentView.bounds.minX }
}

// MARK: - 滚动（竖向滚轮 → 横向）

@MainActor
final class MioMacTabScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX), let doc = documentView, doc.frame.width > contentView.bounds.width {
            let clip = contentView
            let factor: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
            var x = clip.bounds.origin.x - event.scrollingDeltaY * factor
            x = max(0, min(doc.frame.width - clip.bounds.width, x))
            clip.setBoundsOrigin(NSPoint(x: x, y: 0))
            reflectScrolledClipView(clip)
            return
        }
        super.scrollWheel(with: event)
    }
}

@MainActor
final class MioMacTabDocView: NSView {
    weak var bar: MioMacTabBar?
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) { bar?.backgroundMouseDown(event) }
}

// MARK: - 单个标签

@MainActor
final class MioMacTabView: NSView {
    weak var bar: MioMacTabBar?
    private(set) var item: MioMacTabBar.Item
    private(set) var active: Bool
    var isClosing = false
    private let bgView = NSView()
    private var bg: CALayer { bgView.layer! }
    private let favicon = NSImageView()
    private let throbberHost = NSView()
    private let throbber = CAShapeLayer()
    private let titleLabel = NSTextField(labelWithString: "")
    private let titleMask = CAGradientLayer()
    private let titleClip = NSView()
    private let closeButton = MioMacToolbarButton(symbol: "xmark", size: 10, label: "关闭标签页 (⌘W)", weight: .semibold)
    private let audioButton = MioMacToolbarButton(symbol: "speaker.wave.2.fill", size: 10, label: "静音标签页")
    private let contextLine = CALayer()
    private var hovering = false
    private var tracking: NSTrackingArea?
    private var lifted = false

    init(item: MioMacTabBar.Item, active: Bool) {
        self.item = item
        self.active = active
        super.init(frame: NSRect(x: 0, y: 0, width: 100, height: MioMacTabBar.tabHeight))
        wantsLayer = true
        layer?.masksToBounds = false
        bgView.wantsLayer = true
        bgView.layer?.masksToBounds = false
        bg.cornerRadius = 6
        bg.shadowOffset = CGSize(width: 0, height: -0.5)
        bg.shadowRadius = 2.5
        bg.shadowColor = NSColor.black.cgColor
        addSubview(bgView)
        favicon.imageScaling = .scaleProportionallyDown
        favicon.wantsLayer = true
        addSubview(favicon)
        throbber.fillColor = nil
        throbber.lineWidth = 1.6
        throbber.lineCap = .round
        throbber.strokeStart = 0
        throbber.strokeEnd = 0.7
        throbber.isHidden = true
        titleLabel.font = .systemFont(ofSize: 12)
        titleLabel.lineBreakMode = .byClipping
        titleLabel.cell?.truncatesLastVisibleLine = false
        titleClip.wantsLayer = true
        titleClip.addSubview(titleLabel)
        titleMask.startPoint = CGPoint(x: 0, y: 0.5)
        titleMask.endPoint = CGPoint(x: 1, y: 0.5)
        titleClip.layer?.mask = titleMask
        addSubview(titleClip)
        closeButton.cornerRadius = 4
        closeButton.onClick = { [weak self] in guard let self else { return }; self.bar?.closeFromMouse(self.item.id) }
        audioButton.cornerRadius = 4
        audioButton.onClick = { [weak self] in guard let self else { return }; self.bar?.onToggleMute?(self.item.id) }
        addSubview(audioButton)
        addSubview(closeButton)
        contextLine.cornerRadius = 1
        bg.addSublayer(contextLine)
        throbberHost.wantsLayer = true
        throbberHost.layer?.addSublayer(throbber)
        addSubview(throbberHost)
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        update(item, active: active)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }

    func update(_ item: MioMacTabBar.Item, active: Bool) {
        let activeChanged = active != self.active
        let loadingChanged = item.loading != self.item.loading
        self.item = item
        self.active = active
        titleLabel.stringValue = item.title
        toolTip = item.title
        setAccessibilityLabel(item.title)
        setAccessibilityValue(active ? "选中" : "")
        titleLabel.font = .systemFont(ofSize: 12, weight: active ? .medium : .regular)
        if item.isHome {
            favicon.image = MioTheme.symbol("m.circle.fill", 15, weight: .semibold)
            favicon.contentTintColor = MioTheme.mio
        } else if let f = item.favicon {
            favicon.image = f
            favicon.contentTintColor = nil
        } else {
            favicon.image = MioTheme.symbol("globe", 13)
            favicon.contentTintColor = MioTheme.secondaryText
        }
        audioButton.isHidden = !(item.audible || item.muted)
        audioButton.setSymbol(item.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", size: 10, animated: true)
        audioButton.toolTip = item.muted ? "取消静音标签页" : "静音标签页"
        contextLine.isHidden = item.color == nil
        contextLine.backgroundColor = item.color?.cgColor
        if loadingChanged || throbber.isHidden == item.loading { setThrobber(item.loading) }
        needsLayout = true
        layoutContents()
        refresh(animated: activeChanged)
    }

    private func setThrobber(_ on: Bool) {
        throbber.isHidden = !on
        throbberHost.isHidden = !on
        favicon.isHidden = on
        throbber.removeAllAnimations()
        guard on else { return }
        if MioMotion.reduce {
            throbber.strokeEnd = 1
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1; pulse.toValue = 0.35; pulse.duration = 0.9; pulse.autoreverses = true; pulse.repeatCount = .infinity
            throbber.add(pulse, forKey: "pulse")
        } else {
            throbber.strokeEnd = 0.7
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -Double.pi * 2
            spin.duration = 0.8
            spin.repeatCount = .infinity
            throbber.add(spin, forKey: "spin")
        }
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutContents()
    }

    override func layout() {
        super.layout()
        layoutContents()
    }

    private var showsClose: Bool {
        guard !item.pinned else { return false }
        return active ? bounds.width >= 60 : (hovering && bounds.width >= 90)
    }

    func layoutContents() {
        let b = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(!NSAnimationContext.current.allowsImplicitAnimation)
        bgView.frame = b
        contextLine.frame = NSRect(x: 8, y: 1, width: max(0, b.width - 16), height: 2) // 非翻转：y=1 在底部
        CATransaction.commit()
        let iconSize: CGFloat = 16
        let cy = (b.height - iconSize) / 2
        if item.pinned {
            favicon.frame = NSRect(x: (b.width - iconSize) / 2, y: cy, width: iconSize, height: iconSize)
            titleClip.isHidden = true
            closeButton.isHidden = true
            // 固定标签：声音图标叠在右上角
            audioButton.frame = NSRect(x: b.width - 15, y: b.height - 15, width: 14, height: 14)
        } else {
            var x: CGFloat = 10
            favicon.frame = NSRect(x: x, y: cy, width: iconSize, height: iconSize)
            x += iconSize + 6
            if !audioButton.isHidden {
                audioButton.frame = NSRect(x: x - 2, y: (b.height - 18) / 2, width: 18, height: 18)
                x += 18
            }
            let closeW: CGFloat = 20
            closeButton.frame = NSRect(x: b.width - closeW - 6, y: (b.height - closeW) / 2, width: closeW, height: closeW)
            closeButton.isHidden = false
            let right = showsClose ? closeButton.frame.minX - 2 : b.width - 8
            titleClip.isHidden = false
            titleClip.frame = NSRect(x: x, y: 0, width: max(0, right - x), height: b.height)
            let th = titleLabel.intrinsicContentSize.height
            titleLabel.frame = NSRect(x: 0, y: (b.height - th) / 2, width: max(titleClip.frame.width, titleLabel.intrinsicContentSize.width), height: th)
            // Firefox：标题放不下时右侧渐隐，而不是省略号
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            titleMask.frame = titleClip.bounds
            let fits = titleLabel.intrinsicContentSize.width <= titleClip.frame.width
            let fadeStart = titleClip.frame.width > 0 ? max(0, 1 - 18 / titleClip.frame.width) : 1
            titleMask.colors = [NSColor.black.cgColor, NSColor.black.cgColor, (fits ? NSColor.black : NSColor.clear).cgColor]
            titleMask.locations = [0, NSNumber(value: Double(fadeStart)), 1]
            CATransaction.commit()
        }
        throbberHost.frame = favicon.frame
        let tr = throbberHost.bounds.insetBy(dx: 1.5, dy: 1.5)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        throbber.bounds = CGRect(origin: .zero, size: tr.size)
        throbber.position = CGPoint(x: tr.midX, y: tr.midY)
        throbber.path = CGPath(ellipseIn: throbber.bounds, transform: nil)
        CATransaction.commit()
    }

    func refresh(animated: Bool) {
        let color: NSColor = active ? MioTheme.selectedTab : (hovering ? MioTheme.hoverTab : .clear)
        let to = MioTheme.cg(color, in: self)
        let shadow: Float = active ? (lifted ? 0.32 : 0.18) : (lifted ? 0.3 : 0)
        if animated {
            MioMotion.layer(bg, "backgroundColor", from: bg.presentation()?.backgroundColor, to: to, duration: MioMotion.fast)
            MioMotion.layer(bg, "shadowOpacity", from: bg.presentation()?.shadowOpacity, to: shadow, duration: MioMotion.fast)
        } else {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            bg.backgroundColor = to
            bg.shadowOpacity = shadow
            CATransaction.commit()
        }
        bg.shadowRadius = lifted ? 6 : 2.5
        titleLabel.textColor = active ? MioTheme.text : MioTheme.text.withAlphaComponent(0.85)
        throbber.strokeColor = MioTheme.cg(MioTheme.throbber, in: self)
        let wantClose = showsClose
        let alpha: CGFloat = wantClose ? 1 : 0
        if closeButton.alphaValue != alpha {
            if animated { MioMotion.animate(MioMotion.fast, { self.closeButton.animator().alphaValue = alpha }) } else { closeButton.alphaValue = alpha }
        }
    }

    func setLifted(_ on: Bool) {
        lifted = on
        refresh(animated: true)
        guard let l = layer, MioMotion.duration(MioMotion.fast) > 0 else { return }
        let s = CABasicAnimation(keyPath: "transform.scale")
        s.fromValue = on ? 1.0 : 1.03
        s.toValue = on ? 1.03 : 1.0
        s.duration = MioMotion.fast
        s.fillMode = .forwards
        s.isRemovedOnCompletion = !on
        l.add(s, forKey: "lift")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        layoutContents()
        refresh(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        layoutContents()
        refresh(animated: true)
    }

    override func mouseDown(with event: NSEvent) {
        guard !isClosing else { return }
        if event.modifierFlags.contains(.control) { rightMouseDown(with: event); return }
        bar?.pressBegan(item.id, event: event)
    }

    override func mouseDragged(with event: NSEvent) { bar?.pressDragged(event) }
    override func mouseUp(with event: NSEvent) { bar?.pressEnded(event) }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { bar?.closeFromMouse(item.id) } // 中键关闭
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = bar?.contextMenu?(item.id) else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func accessibilityPerformPress() -> Bool { bar?.onSelect?(item.id); return true }
}
