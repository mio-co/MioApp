// MioMacControls.swift — Firefox 式外壳用的小控件（都带悬停 / 按下过渡）：
//   - MioMacToolbarButton：导航栏 / 标签条的图标按钮（悬停圆角底色淡入，按下更深，可显示文字）
//   - MioMacPopupPanel：工具栏弹出面板（应用菜单、Mio 扩展、站点信息、列出所有标签页）——子窗口，淡入 + 下滑 4pt + 微缩放，
//     点外面 / Esc / 窗口失焦关闭；减少动态效果时只淡入淡出
//   - MioMacPanelStack：面板里的「子视图」推入 / 返回（Firefox 应用菜单的左右滑动）
//   - MioMacMenuRow：面板里的一行（图标、标题、快捷键、子菜单箭头、开关），悬停高亮

import AppKit
import MioKit

// MARK: - 图标按钮

@MainActor
class MioMacToolbarButton: NSView {
    var onClick: (() -> Void)?
    /// 按下时（鼠标还没抬起）就触发：弹出面板类按钮用（Firefox 也是 mousedown 打开菜单）
    var triggersOnMouseDown = false
    let imageView = NSImageView()
    let titleLabel = NSTextField(labelWithString: "")
    var isEnabled = true { didSet { alphaValue = isEnabled ? 1 : 0.4 } }
    var isActive = false { didSet { refresh(animated: true) } }   // 面板打开时保持按下态
    var cornerRadius: CGFloat = 4 { didSet { layer?.cornerRadius = cornerRadius } }
    var hoverColor: NSColor = MioTheme.buttonHover
    var pressedColor: NSColor = MioTheme.buttonPressed
    private var hovering = false
    private var pressing = false
    private var tracking: NSTrackingArea?

    init(symbol: String, size: CGFloat = 15, label: String, weight: NSFont.Weight = .regular) {
        super.init(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        imageView.image = MioTheme.symbol(symbol, size, weight: weight, label: label)
        imageView.contentTintColor = MioTheme.text
        imageView.imageScaling = .scaleNone
        imageView.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = MioTheme.text
        titleLabel.isHidden = true
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        toolTip = label
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setSymbol(_ name: String, size: CGFloat = 15, weight: NSFont.Weight = .regular, tint: NSColor? = nil, animated: Bool = false) {
        let img = MioTheme.symbol(name, size, weight: weight, label: toolTip)
        if animated, MioMotion.duration(MioMotion.fast) > 0, let l = imageView.layer {
            let t = CATransition()
            t.type = .fade
            t.duration = MioMotion.duration(MioMotion.fast)
            l.add(t, forKey: "symbol")
        }
        imageView.image = img
        imageView.contentTintColor = tint ?? MioTheme.text
    }

    func setTitle(_ s: String?) {
        titleLabel.stringValue = s ?? ""
        titleLabel.isHidden = s == nil
        imageView.isHidden = s != nil
    }

    override var mouseDownCanMoveWindow: Bool { false }

    /// 淡出到透明的按钮（关闭按钮、溢出时的内联 +）不接收点击
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard alphaValue > 0.05, !isHidden else { return nil }
        return super.hitTest(point) != nil ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; refresh(animated: true) }
    override func mouseExited(with event: NSEvent) { hovering = false; pressing = false; refresh(animated: true) }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressing = true
        refresh(animated: false)
        if triggersOnMouseDown { pressing = false; onClick?() }
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled, pressing else { return }
        pressing = false
        refresh(animated: true)
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func accessibilityPerformPress() -> Bool { onClick?(); return true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh(animated: false)
    }

    func refresh(animated: Bool) {
        guard let l = layer else { return }
        let c: NSColor = (pressing || isActive) ? pressedColor : (hovering && isEnabled ? hoverColor : .clear)
        let to = MioTheme.cg(c, in: self)
        if animated { MioMotion.layer(l, "backgroundColor", from: l.presentation()?.backgroundColor, to: to, duration: MioMotion.fast) }
        else { CATransaction.begin(); CATransaction.setDisableActions(true); l.backgroundColor = to; CATransaction.commit() }
    }

    /// 弹一下（收藏星标、缩放按钮）
    func bounce() {
        guard MioMotion.duration(MioMotion.normal) > 0, let l = imageView.layer else { return }
        let a = CAKeyframeAnimation(keyPath: "transform.scale")
        a.values = [1.0, 1.35, 0.9, 1.05, 1.0]
        a.keyTimes = [0, 0.3, 0.6, 0.85, 1]
        a.duration = MioMotion.duration(0.38)
        l.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        l.position = CGPoint(x: imageView.frame.midX, y: imageView.frame.midY)
        l.add(a, forKey: "bounce")
    }
}

// MARK: - 弹出面板

@MainActor
final class MioMacPopupPanel: NSPanel {
    enum Alignment { case leading, trailing, center }

    private(set) weak var anchor: NSView?
    var onClose: (() -> Void)?
    private var monitors: [Any] = []
    private let host = NSView()
    private let backing = NSVisualEffectView()
    private(set) var content: NSView?
    static private(set) weak var current: MioMacPopupPanel?

    init(content: NSView) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        isReleasedWhenClosed = false
        hidesOnDeactivate = true
        animationBehavior = .none
        backing.material = .menu
        backing.state = .active
        backing.blendingMode = .behindWindow
        backing.wantsLayer = true
        backing.layer?.cornerRadius = 8
        backing.layer?.masksToBounds = true
        backing.layer?.borderWidth = 0.5
        contentView = backing
        setContent(content, animated: false)
    }

    override var canBecomeKey: Bool { true }   // 面板里的文本框 / 开关要能接收键盘
    override var canBecomeMain: Bool { false }

    func setContent(_ v: NSView, animated: Bool) {
        content?.removeFromSuperview()
        content = v
        let size = v.fittingSize
        // 先把面板改成内容的尺寸，再放内容（反过来的话内容会跟着面板的高度变化被自动拉伸 → 整体错位）
        var f = frame
        let top = f.maxY
        f.size = size
        f.origin.y = top - size.height
        setFrame(f, display: false, animate: false)
        v.translatesAutoresizingMaskIntoConstraints = true
        v.frame = backing.bounds
        v.autoresizingMask = [.width, .height]
        backing.addSubview(v)
        backing.layer?.borderColor = MioTheme.cg(MioTheme.panelBorder, in: backing)
    }

    /// 内容高度变了（子视图推入）：保持顶边不动，高度动画
    func resize(to size: NSSize) {
        var f = frame
        let top = f.maxY
        f.size = size
        f.origin.y = top - size.height
        if MioMotion.duration(MioMotion.normal) > 0 {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = MioMotion.duration(MioMotion.normal)
                ctx.timingFunction = MioMotion.easeOut
                self.animator().setFrame(f, display: true)
            }
        } else {
            setFrame(f, display: true)
        }
    }

    func show(below view: NSView, alignment: Alignment = .trailing, offset: CGFloat = 4) {
        MioMacPopupPanel.current?.dismiss(animated: false)
        guard let win = view.window else { return }
        anchor = view
        let r = win.convertToScreen(view.convert(view.bounds, to: nil))
        let size = frame.size
        var x: CGFloat
        switch alignment {
        case .leading: x = r.minX
        case .trailing: x = r.maxX - size.width
        case .center: x = r.midX - size.width / 2
        }
        if let screen = win.screen?.visibleFrame { x = max(screen.minX + 4, min(screen.maxX - size.width - 4, x)) }
        let final = NSRect(x: x, y: r.minY - offset - size.height, width: size.width, height: size.height)
        win.addChildWindow(self, ordered: .above)
        MioMacPopupPanel.current = self
        // Firefox 面板：淡入 + 从上往下 4pt + 0.98 → 1 缩放（减少动态效果：只淡入）
        let d = MioMotion.duration(MioMotion.normal)
        if d > 0 {
            setFrame(final.offsetBy(dx: 0, dy: 6), display: false)
            alphaValue = 0
            orderFront(nil)
            if let l = backing.layer {
                let s = CABasicAnimation(keyPath: "transform.scale")
                s.fromValue = 0.97
                s.toValue = 1
                s.duration = d
                s.timingFunction = MioMotion.easeOut
                l.add(s, forKey: "pop")
            }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = d
                ctx.timingFunction = MioMotion.easeOut
                self.animator().alphaValue = 1
                self.animator().setFrame(final, display: true)
            }
        } else {
            setFrame(final, display: false)
            alphaValue = 1
            orderFront(nil)
        }
        installMonitors()
    }

    private func installMonitors() {
        removeMonitors()
        let down = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] e in
            var pass = true
            MainActor.assumeIsolated {
                guard let self, e.window !== self else { return }
                if let a = self.anchor, e.window === a.window, a.bounds.contains(a.convert(e.locationInWindow, from: nil)) {
                    pass = false // 再点一次按钮 = 关闭（吞掉这次点击，免得又打开）
                }
                self.dismiss(animated: true)
            }
            return pass ? e : nil
        }
        let key = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] e in
            var pass = true
            MainActor.assumeIsolated {
                guard let self, e.keyCode == 53 else { return } // Esc
                pass = false
                if let stack = self.content as? MioMacPanelStack, stack.depth > 1 { stack.pop(); return }
                self.dismiss(animated: true)
            }
            return pass ? e : nil
        }
        monitors = [down, key].compactMap { $0 }
        NotificationCenter.default.addObserver(self, selector: #selector(parentResigned(_:)), name: NSWindow.didResignKeyNotification, object: parent)
    }

    @objc private func parentResigned(_ n: Notification) {
        // 面板自己成为 key（点了里面的文本框）时父窗口也会失焦：那种情况不关
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isVisible, !self.isKeyWindow, !(self.parent?.isKeyWindow ?? false) else { return }
                self.dismiss(animated: true)
            }
        }
    }

    private func removeMonitors() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
        NotificationCenter.default.removeObserver(self)
    }

    func dismiss(animated: Bool) {
        guard isVisible else { return }
        removeMonitors()
        if MioMacPopupPanel.current === self { MioMacPopupPanel.current = nil }
        let finish = { [weak self] in
            guard let self else { return }
            self.parent?.removeChildWindow(self)
            self.orderOut(nil)
            self.alphaValue = 1
            self.onClose?()
        }
        let d = animated ? MioMotion.duration(MioMotion.fast) : 0
        if d > 0 {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = d
                ctx.timingFunction = MioMotion.easeIn
                self.animator().alphaValue = 0
            }, completionHandler: { MainActor.assumeIsolated { finish() } })
        } else {
            finish()
        }
    }
}

// MARK: - 面板子视图推入 / 返回

@MainActor
final class MioMacPanelStack: NSView {
    private var views: [NSView] = []
    var depth: Int { views.count }
    let width: CGFloat

    init(root: NSView, width: CGFloat) {
        self.width = width
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        push(root, animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override var fittingSize: NSSize {
        NSSize(width: width, height: views.last.map { height(of: $0) } ?? 100)
    }

    private func height(of v: NSView) -> CGFloat {
        v.layoutSubtreeIfNeeded()
        return max(40, v.fittingSize.height)
    }

    func push(_ v: NSView, animated: Bool = true) {
        let h = height(of: v)
        let old = views.last
        views.append(v)
        v.translatesAutoresizingMaskIntoConstraints = true
        v.frame = NSRect(x: animated ? width : 0, y: 0, width: width, height: h)
        v.autoresizingMask = [] // 高度固定：面板高度动画时子视图不被拉伸（翻转坐标，贴顶）
        addSubview(v)
        transition(from: old, to: v, forward: true, animated: animated, height: h)
    }

    func pop(animated: Bool = true) {
        guard views.count > 1 else { return }
        let old = views.removeLast()
        guard let v = views.last else { return }
        let h = height(of: v)
        v.frame = NSRect(x: -width, y: 0, width: width, height: h)
        v.autoresizingMask = []
        v.isHidden = false
        transition(from: old, to: v, forward: false, animated: animated, height: h, removeOld: true)
    }

    private func transition(from old: NSView?, to new: NSView, forward: Bool, animated: Bool, height: CGFloat, removeOld: Bool = false) {
        (window as? MioMacPopupPanel)?.resize(to: NSSize(width: width, height: height))
        let d = animated ? MioMotion.duration(MioMotion.normal) : 0
        let done = {
            if removeOld { old?.removeFromSuperview() } else { old?.isHidden = true }
            new.frame.origin.x = 0
            self.window?.makeFirstResponder(new.subviews.first { $0.acceptsFirstResponder } ?? new)
        }
        guard d > 0 else { new.frame.origin.x = 0; done(); return }
        MioMotion.animate(d, {
            new.animator().frame.origin.x = 0
            old?.animator().frame.origin.x = forward ? -self.width * 0.3 : self.width
            old?.animator().alphaValue = 0
            new.alphaValue = 1
        }, completion: {
            old?.alphaValue = 1
            done()
        })
    }
}

// MARK: - 面板里的一行

@MainActor
final class MioMacMenuRow: NSView {
    var onClick: (() -> Void)?
    let icon = NSImageView()
    let title = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")
    let chevron = NSImageView()
    var toggle: NSSwitch?
    var isEnabled = true { didSet { alphaValue = isEnabled ? 1 : 0.45 } }
    var isSelected = false { didSet { refresh(animated: true) } }
    private var hovering = false
    private var tracking: NSTrackingArea?
    static let height: CGFloat = 32

    init(symbol: String?, title t: String, shortcut: String? = nil, submenu: Bool = false, detail d: String? = nil,
         toggle on: Bool? = nil, iconImage: NSImage? = nil, action: (() -> Void)? = nil) {
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: Self.height))
        onClick = action
        wantsLayer = true
        layer?.cornerRadius = 4
        translatesAutoresizingMaskIntoConstraints = false
        icon.image = iconImage ?? symbol.flatMap { MioTheme.symbol($0, 14) }
        icon.contentTintColor = MioTheme.text
        icon.imageScaling = .scaleProportionallyDown
        title.stringValue = t
        title.font = .systemFont(ofSize: 13)
        title.textColor = MioTheme.text
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.stringValue = d ?? shortcut ?? ""
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = MioTheme.secondaryText
        detail.alignment = .right
        detail.setContentHuggingPriority(.required, for: .horizontal)
        chevron.image = MioTheme.symbol("chevron.right", 11, weight: .semibold)
        chevron.contentTintColor = MioTheme.secondaryText
        chevron.isHidden = !submenu
        for v in [icon, title, detail, chevron] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        var cons = [
            heightAnchor.constraint(equalToConstant: Self.height),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 8),
        ]
        if let on {
            let sw = NSSwitch()
            sw.state = on ? .on : .off
            sw.controlSize = .small
            sw.target = self
            sw.action = #selector(switched(_:))
            sw.translatesAutoresizingMaskIntoConstraints = false
            addSubview(sw)
            toggle = sw
            cons += [sw.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10), sw.centerYAnchor.constraint(equalTo: centerYAnchor),
                     detail.trailingAnchor.constraint(equalTo: sw.leadingAnchor, constant: -8)]
        } else {
            cons.append(detail.trailingAnchor.constraint(equalTo: submenu ? chevron.leadingAnchor : trailingAnchor, constant: submenu ? -6 : -12))
        }
        NSLayoutConstraint.activate(cons)
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(t)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var onToggle: ((Bool) -> Void)?
    @objc private func switched(_ s: NSSwitch) { onToggle?(s.state == .on) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; refresh(animated: true) }
    override func mouseExited(with event: NSEvent) { hovering = false; refresh(animated: true) }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        if let t = toggle { t.state = t.state == .on ? .off : .on; onToggle?(t.state == .on); return }
        onClick?()
    }

    override func mouseDown(with event: NSEvent) {}

    func refresh(animated: Bool) {
        guard let l = layer else { return }
        let c: NSColor = isSelected ? MioTheme.accent.withAlphaComponent(0.16) : ((hovering && isEnabled) ? MioTheme.buttonHover : .clear)
        let to = MioTheme.cg(c, in: self)
        if animated { MioMotion.layer(l, "backgroundColor", from: l.presentation()?.backgroundColor, to: to, duration: MioMotion.fast) }
        else { l.backgroundColor = to }
    }

    // MARK: 拼面板内容

    /// 一列行 + 分隔线（nil = 分隔线），可选标题行和返回按钮
    static func column(_ rows: [NSView?], width: CGFloat, header: String? = nil, onBack: (() -> Void)? = nil) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        var all: [NSView] = []
        if let h = header {
            all.append(headerRow(h, onBack: onBack))
            all.append(separator())
        }
        for r in rows { all.append(r ?? separator()) }
        for v in all {
            stack.addArrangedSubview(v)
            v.widthAnchor.constraint(equalToConstant: width - 12).isActive = true
        }
        let wrap = MioMacFlippedView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: wrap.topAnchor),
            stack.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
            wrap.widthAnchor.constraint(equalToConstant: width),
        ])
        return wrap
    }

    static func separator() -> NSView {
        let v = NSBox()
        v.boxType = .separator
        v.translatesAutoresizingMaskIntoConstraints = false
        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(v)
        NSLayoutConstraint.activate([
            wrap.heightAnchor.constraint(equalToConstant: 9),
            v.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 4),
            v.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -4),
            v.centerYAnchor.constraint(equalTo: wrap.centerYAnchor),
        ])
        return wrap
    }

    static func headerRow(_ title: String, onBack: (() -> Void)?) -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = MioTheme.text
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(label)
        var cons = [v.heightAnchor.constraint(equalToConstant: 36),
                    label.centerXAnchor.constraint(equalTo: v.centerXAnchor), label.centerYAnchor.constraint(equalTo: v.centerYAnchor)]
        if let back = onBack {
            let b = MioMacToolbarButton(symbol: "chevron.left", size: 12, label: "返回", weight: .semibold)
            b.onClick = back
            b.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(b)
            cons += [b.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 2), b.centerYAnchor.constraint(equalTo: v.centerYAnchor),
                     b.widthAnchor.constraint(equalToConstant: 28), b.heightAnchor.constraint(equalToConstant: 28)]
        }
        NSLayoutConstraint.activate(cons)
        return v
    }

    static func note(_ text: String) -> NSView {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = .systemFont(ofSize: 11.5)
        l.textColor = MioTheme.secondaryText
        l.translatesAutoresizingMaskIntoConstraints = false
        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(l)
        NSLayoutConstraint.activate([
            l.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 4),
            l.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -6),
            l.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 10),
            l.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -10),
        ])
        return wrap
    }
}

@MainActor
final class MioMacFlippedView: NSView {
    override var isFlipped: Bool { true }
}
