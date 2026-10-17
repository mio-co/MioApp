// MioMacNavBar.swift — Firefox 桌面式导航栏（标签条下面一行）：
//   侧边栏 · 后退 · 前进 · 刷新/停止 ·（弹性）· 地址栏 ·（弹性）· Mio 扩展 · ≡ 应用菜单；底部 2pt 加载进度条
//   地址栏：跟踪保护盾牌 + 站点信息锁（首页显示 Mio 标识）、域名高亮 / 路径变灰、缩放百分比（非 100% 时滑出，点一下复位）、收藏星标；
//   聚焦时「突出」（左右各放大 4pt、变白、2pt 强调色描边、阴影）并在下方弹出建议列表（淡入 + 下滑），↑↓ 选择、回车打开、Esc 还原

import AppKit
import QuartzCore

@MainActor
final class MioMacNavBar: NSView {
    static let height: CGFloat = 40

    let sidebarButton = MioMacToolbarButton(symbol: "sidebar.left", size: 14, label: "侧边栏 (⌃⌘S)")
    let backButton = MioMacToolbarButton(symbol: "arrow.left", size: 15, label: "后退 (⌘[)")
    let forwardButton = MioMacToolbarButton(symbol: "arrow.right", size: 15, label: "前进 (⌘])")
    let reloadButton = MioMacToolbarButton(symbol: "arrow.clockwise", size: 15, label: "重新载入 (⌘R)")
    let urlBar = MioMacURLBar()
    let extensionsButton = MioMacToolbarButton(symbol: "puzzlepiece.extension", size: 15, label: "Mio 扩展")
    let menuButton = MioMacToolbarButton(symbol: "line.3.horizontal", size: 15, label: "打开应用菜单")
    let progress = MioMacProgressBar()
    private let separator = NSView()
    private var leadingConstraint: NSLayoutConstraint?
    private var urlLeading: NSLayoutConstraint?
    private var urlTrailing: NSLayoutConstraint?
    private var urlHeight: NSLayoutConstraint?
    private let urlSlot = NSView()
    private(set) var isLoading = false

    var leadingInset: CGFloat = 8 {
        didSet {
            guard oldValue != leadingInset else { return }
            MioMotion.animate(MioMotion.normal, {
                self.leadingConstraint?.constant = self.leadingInset
                self.layoutSubtreeIfNeeded()
            })
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        separator.wantsLayer = true
        for b in [sidebarButton, backButton, forwardButton, reloadButton, extensionsButton, menuButton] {
            b.translatesAutoresizingMaskIntoConstraints = false
            addSubview(b)
            b.widthAnchor.constraint(equalToConstant: 32).isActive = true
            b.heightAnchor.constraint(equalToConstant: 32).isActive = true
            b.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -1).isActive = true
        }
        extensionsButton.triggersOnMouseDown = true
        menuButton.triggersOnMouseDown = true
        sidebarButton.setAccessibilityIdentifier("mio.nav.sidebar")
        backButton.setAccessibilityIdentifier("mio.nav.back")
        forwardButton.setAccessibilityIdentifier("mio.nav.forward")
        reloadButton.setAccessibilityIdentifier("mio.nav.reload")
        extensionsButton.setAccessibilityIdentifier("mio.nav.extensions")
        menuButton.setAccessibilityIdentifier("mio.nav.menu")
        urlSlot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(urlSlot)
        urlBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(urlBar)
        progress.translatesAutoresizingMaskIntoConstraints = false
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)
        addSubview(progress)
        let lead = sidebarButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leadingInset)
        leadingConstraint = lead
        // 地址栏：放在两组按钮之间的「槽」里，尽量居中、最宽 1000pt；聚焦时比槽左右各大 4pt
        let slotCenter = urlSlot.centerXAnchor.constraint(equalTo: centerXAnchor)
        slotCenter.priority = .defaultLow
        let slotWide = urlSlot.widthAnchor.constraint(equalToConstant: 1000)
        slotWide.priority = NSLayoutConstraint.Priority(240)
        let ul = urlBar.leadingAnchor.constraint(equalTo: urlSlot.leadingAnchor)
        let ut = urlBar.trailingAnchor.constraint(equalTo: urlSlot.trailingAnchor)
        let uh = urlBar.heightAnchor.constraint(equalToConstant: 30)
        urlLeading = ul; urlTrailing = ut; urlHeight = uh
        NSLayoutConstraint.activate([
            lead,
            backButton.leadingAnchor.constraint(equalTo: sidebarButton.trailingAnchor, constant: 2),
            forwardButton.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 2),
            reloadButton.leadingAnchor.constraint(equalTo: forwardButton.trailingAnchor, constant: 2),
            menuButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            extensionsButton.trailingAnchor.constraint(equalTo: menuButton.leadingAnchor, constant: -2),
            urlSlot.leadingAnchor.constraint(greaterThanOrEqualTo: reloadButton.trailingAnchor, constant: 12),
            urlSlot.trailingAnchor.constraint(lessThanOrEqualTo: extensionsButton.leadingAnchor, constant: -12),
            urlSlot.widthAnchor.constraint(lessThanOrEqualToConstant: 1000),
            slotCenter, slotWide,
            urlSlot.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -1),
            urlSlot.heightAnchor.constraint(equalToConstant: 30),
            ul, ut, uh,
            urlBar.centerYAnchor.constraint(equalTo: urlSlot.centerYAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
            progress.leadingAnchor.constraint(equalTo: leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: trailingAnchor),
            progress.bottomAnchor.constraint(equalTo: bottomAnchor),
            progress.heightAnchor.constraint(equalToConstant: 2),
        ])
        urlBar.onFocusChange = { [weak self] focused in self?.setURLBarExpanded(focused) }
        setAccessibilityIdentifier("mio.navbar")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
    }

    func applyColors() {
        layer?.backgroundColor = MioTheme.cg(MioTheme.toolbar, in: self)
        separator.layer?.backgroundColor = MioTheme.cg(MioTheme.separator, in: self)
        urlBar.applyColors()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { window?.performZoom(nil); return }
        window?.performDrag(with: event) // 导航栏空白处也能拖窗口（垂直标签模式下它就是标题栏）
    }

    /// 地址栏突出（Firefox breakout）
    private func setURLBarExpanded(_ on: Bool) {
        let inset: CGFloat = on ? 4 : 0
        MioMotion.animate(MioMotion.fast + 0.04, {
            self.urlLeading?.constant = -inset
            self.urlTrailing?.constant = inset
            self.urlHeight?.constant = on ? 34 : 30
            self.layoutSubtreeIfNeeded()
        })
    }

    func setLoading(_ loading: Bool) {
        guard loading != isLoading else { return }
        isLoading = loading
        reloadButton.setSymbol(loading ? "xmark" : "arrow.clockwise", size: loading ? 14 : 15, animated: true)
        reloadButton.toolTip = loading ? "停止载入 (Esc)" : "重新载入 (⌘R)"
        if MioMotion.duration(MioMotion.normal) > 0, !loading, let l = reloadButton.imageView.layer {
            // 停止 → 刷新：转半圈落位
            let r = CABasicAnimation(keyPath: "transform.rotation.z")
            r.fromValue = Double.pi / 2
            r.toValue = 0
            r.duration = MioMotion.normal
            r.timingFunction = MioMotion.easeOut
            l.add(r, forKey: "settle")
        }
    }
}

// MARK: - 地址栏

@MainActor
final class MioMacURLBar: NSView, NSTextFieldDelegate {
    let shieldButton = MioMacToolbarButton(symbol: "shield", size: 13, label: "跟踪保护")
    let identityButton = MioMacToolbarButton(symbol: "lock.fill", size: 12, label: "站点信息")
    let field = MioMacURLField()
    let zoomButton = MioMacToolbarButton(symbol: "plus.magnifyingglass", size: 11, label: "重置缩放 (⌘0)")
    let starButton = MioMacToolbarButton(symbol: "star", size: 14, label: "为此页加书签 (⌘D)")
    private var zoomWidth: NSLayoutConstraint?
    private(set) var isFocused = false
    private(set) var security: MioURLDisplay.Security = .none
    private var displayURL: URL?
    private var isHome = false

    // 建议
    var suggestionsFor: ((String) -> [MioSuggestion])?
    var onPick: ((MioSuggestion) -> Void)?
    var onSubmit: ((String) -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    var onEscapeToPage: (() -> Void)?
    let dropdown = MioMacURLDropdown()
    private var typed = ""
    private var suggestions: [MioSuggestion] = []
    private var selection = -1

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 0
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOffset = CGSize(width: 0, height: -1)
        layer?.shadowRadius = 4
        layer?.shadowOpacity = 0
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13.5)
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.placeholderString = "使用 Google 搜索，或者输入网址"
        field.delegate = self
        field.owner = self
        field.setAccessibilityIdentifier("mio.urlbar.field")
        zoomButton.cornerRadius = 9
        zoomButton.hoverColor = MioTheme.buttonPressed
        zoomButton.setAccessibilityIdentifier("mio.urlbar.zoom")
        starButton.setAccessibilityIdentifier("mio.urlbar.star")
        identityButton.setAccessibilityIdentifier("mio.urlbar.identity")
        shieldButton.setAccessibilityIdentifier("mio.urlbar.shield")
        for v in [shieldButton, identityButton, field, zoomButton, starButton] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        let zw = zoomButton.widthAnchor.constraint(equalToConstant: 0)
        zoomWidth = zw
        zoomButton.alphaValue = 0
        NSLayoutConstraint.activate([
            shieldButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            shieldButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            shieldButton.widthAnchor.constraint(equalToConstant: 24),
            shieldButton.heightAnchor.constraint(equalToConstant: 24),
            identityButton.leadingAnchor.constraint(equalTo: shieldButton.trailingAnchor, constant: 0),
            identityButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            identityButton.widthAnchor.constraint(equalToConstant: 24),
            identityButton.heightAnchor.constraint(equalToConstant: 24),
            field.leadingAnchor.constraint(equalTo: identityButton.trailingAnchor, constant: 4),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.trailingAnchor.constraint(equalTo: zoomButton.leadingAnchor, constant: -4),
            zoomButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            zoomButton.heightAnchor.constraint(equalToConstant: 18),
            zw,
            zoomButton.trailingAnchor.constraint(equalTo: starButton.leadingAnchor, constant: -2),
            starButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            starButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            starButton.widthAnchor.constraint(equalToConstant: 26),
            starButton.heightAnchor.constraint(equalToConstant: 24),
        ])
        dropdown.onPick = { [weak self] i in self?.pick(i) }
        dropdown.onHover = { [weak self] i in self?.select(i, fill: false) }
        setAccessibilityIdentifier("mio.urlbar")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func applyColors() {
        layer?.backgroundColor = MioTheme.cg(isFocused ? MioTheme.urlbarFocused : MioTheme.urlbar, in: self)
        layer?.borderColor = MioTheme.cg(MioTheme.accent, in: self)
        dropdown.applyColors(from: self)
        refreshDisplay()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(field) // 点地址栏空白处也聚焦
    }

    // MARK: 显示

    func setDisplay(url: URL?, isHome: Bool) {
        displayURL = url
        self.isHome = isHome
        security = MioURLDisplay.security(url, isHome: isHome)
        let sym: String
        var tint = MioTheme.secondaryText
        switch security {
        case .home: sym = "m.circle.fill"; tint = MioTheme.mio
        case .secure: sym = "lock.fill"
        case .insecure: sym = "lock.slash"; tint = .systemRed
        case .local: sym = "info.circle"
        case .none: sym = "magnifyingglass"
        }
        identityButton.setSymbol(sym, size: security == .home ? 14 : 12, weight: security == .home ? .semibold : .regular, tint: tint)
        identityButton.toolTip = security == .insecure ? "连接不安全" : (security == .secure ? "连接安全" : "站点信息")
        shieldButton.isHidden = security == .home || security == .none
        shieldButton.imageView.contentTintColor = MioTheme.secondaryText
        if !isFocused { refreshDisplay() }
    }

    private func refreshDisplay() {
        guard !isFocused else { return }
        if isHome {
            field.attributedStringValue = NSAttributedString(string: MioMacHome.displayName, attributes: [
                .foregroundColor: MioTheme.text, .font: NSFont.systemFont(ofSize: 13.5, weight: .medium)])
            return
        }
        let p = MioURLDisplay.parts(displayURL)
        let s = NSMutableAttributedString()
        let font = NSFont.systemFont(ofSize: 13.5)
        s.append(NSAttributedString(string: p.prefix, attributes: [.foregroundColor: MioTheme.secondaryText, .font: font]))
        s.append(NSAttributedString(string: p.host, attributes: [.foregroundColor: MioTheme.text, .font: font]))
        s.append(NSAttributedString(string: p.rest, attributes: [.foregroundColor: MioTheme.secondaryText, .font: font]))
        field.attributedStringValue = s
    }

    var displayedText: String { field.stringValue }

    /// 缩放百分比（非默认时滑出）
    func setZoom(_ level: Double, isDefault: Bool) {
        let label = MioZoomCore.label(level)
        let show = !isDefault
        let wasShown = (zoomWidth?.constant ?? 0) > 0
        zoomButton.setTitle(label)
        zoomButton.titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        let w: CGFloat = show ? zoomButton.titleLabel.intrinsicContentSize.width + 14 : 0
        if show == wasShown && (!show || abs((zoomWidth?.constant ?? 0) - w) < 0.5) {
            if show { zoomButton.bounce() }
            return
        }
        MioMotion.animate(MioMotion.normal, {
            self.zoomWidth?.constant = w
            self.zoomButton.animator().alphaValue = show ? 1 : 0
            self.layoutSubtreeIfNeeded()
        })
        zoomButton.layer?.backgroundColor = MioTheme.cg(MioTheme.buttonHover, in: self)
    }

    func setStarred(_ on: Bool, animated: Bool) {
        let was = starButton.toolTip == "编辑此书签"
        starButton.setSymbol(on ? "star.fill" : "star", size: 14, tint: on ? MioTheme.accent : MioTheme.text, animated: animated)
        starButton.toolTip = on ? "编辑此书签" : "为此页加书签 (⌘D)"
        if animated && on && !was { starButton.bounce() }
    }

    // MARK: 聚焦

    func focusChanged(_ focused: Bool) {
        guard focused != isFocused else { return }
        isFocused = focused
        onFocusChange?(focused)
        let bgTo = MioTheme.cg(focused ? MioTheme.urlbarFocused : MioTheme.urlbar, in: self)
        if let l = layer {
            MioMotion.layer(l, "backgroundColor", from: l.presentation()?.backgroundColor, to: bgTo, duration: MioMotion.fast)
            MioMotion.layer(l, "borderWidth", from: l.presentation()?.borderWidth, to: focused ? 2 : 0, duration: MioMotion.fast)
            MioMotion.layer(l, "shadowOpacity", from: l.presentation()?.shadowOpacity, to: focused ? Float(0.16) : Float(0), duration: MioMotion.fast)
        }
        if focused {
            typed = ""
            field.stringValue = isHome ? "" : MioURLDisplay.editingText(displayURL)
            field.textColor = MioTheme.text
        } else {
            dropdown.hide(animated: true)
            suggestions = []
            selection = -1
            refreshDisplay()
        }
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        typed = field.stringValue
        selection = -1
        updateSuggestions()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        focusChanged(false)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)):
            if !dropdown.isVisible { updateSuggestions() }
            select(MioSuggest.move(selection: selection, by: 1, count: suggestions.count), fill: true)
            return true
        case #selector(NSResponder.moveUp(_:)):
            select(MioSuggest.move(selection: selection, by: -1, count: suggestions.count), fill: true)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            if selection >= 0 { pick(selection) } else { submit(field.stringValue) }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            if dropdown.isVisible {
                dropdown.hide(animated: true)
                if selection >= 0 { field.stringValue = typed; selection = -1 }
            } else {
                field.stringValue = isHome ? "" : MioURLDisplay.editingText(displayURL)
                onEscapeToPage?()
            }
            return true
        default:
            return false
        }
    }

    func updateSuggestions() {
        let q = field.stringValue
        suggestions = suggestionsFor?(q) ?? []
        if suggestions.isEmpty || !isFocused {
            dropdown.hide(animated: true)
        } else {
            dropdown.show(suggestions, below: self, selection: selection)
        }
    }

    private func select(_ i: Int, fill: Bool) {
        selection = i
        dropdown.setSelection(i)
        guard fill else { return }
        if i >= 0, i < suggestions.count {
            let s = suggestions[i]
            field.stringValue = s.kind == .search ? s.title : s.url
        } else {
            field.stringValue = typed
        }
        field.currentEditor()?.moveToEndOfDocument(nil)
    }

    private func pick(_ i: Int) {
        guard i >= 0, i < suggestions.count else { return }
        let s = suggestions[i]
        dropdown.hide(animated: true)
        onPick?(s)
    }

    private func submit(_ text: String) {
        dropdown.hide(animated: true)
        onSubmit?(text)
    }
}

@MainActor
final class MioMacURLField: NSTextField {
    weak var owner: MioMacURLBar?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            owner?.focusChanged(true)
            // Firefox：第一次点击全选（鼠标追踪结束后再选，否则会被点击位置的光标覆盖）
            perform(#selector(selectAllDeferred), with: nil, afterDelay: 0)
        }
        return ok
    }

    @objc private func selectAllDeferred() { currentEditor()?.selectAll(nil) }

    override var mouseDownCanMoveWindow: Bool { false }
}

// MARK: - 地址栏下拉建议

@MainActor
final class MioMacURLDropdown: NSObject {
    private var panel: NSPanel?
    private let stack = NSStackView()
    private var rows: [MioMacSuggestionRow] = []
    private let container = MioMacFlippedView()
    var onPick: ((Int) -> Void)?
    var onHover: ((Int) -> Void)?
    private(set) var isVisible = false
    private weak var anchor: NSView?

    override init() {
        super.init()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.cornerRadius = 8
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 0.5
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
    }

    func applyColors(from v: NSView) {
        container.layer?.backgroundColor = MioTheme.cg(MioTheme.urlbarFocused, in: v)
        container.layer?.borderColor = MioTheme.cg(MioTheme.panelBorder, in: v)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none
        p.contentView = container
        return p
    }

    func show(_ items: [MioSuggestion], below anchor: NSView, selection: Int) {
        guard let win = anchor.window else { return }
        self.anchor = anchor
        let p = panel ?? makePanel()
        panel = p
        applyColors(from: anchor)
        for r in rows { stack.removeArrangedSubview(r); r.removeFromSuperview() }
        let width = anchor.bounds.width
        rows = items.enumerated().map { (i, s) in
            let r = MioMacSuggestionRow(s)
            r.onClick = { [weak self] in self?.onPick?(i) }
            r.onHover = { [weak self] in self?.onHover?(i) }
            return r
        }
        for r in rows {
            stack.addArrangedSubview(r)
            r.widthAnchor.constraint(equalToConstant: width - 12).isActive = true
        }
        setSelection(selection)
        let h = CGFloat(rows.count) * MioMacSuggestionRow.height + 12
        let r = win.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let final = NSRect(x: r.minX, y: r.minY - 4 - h, width: width, height: h)
        container.frame = NSRect(origin: .zero, size: final.size)
        if !isVisible {
            isVisible = true
            win.addChildWindow(p, ordered: .above)
            let d = MioMotion.duration(MioMotion.fast + 0.04)
            if d > 0 {
                p.setFrame(final.offsetBy(dx: 0, dy: 6), display: false)
                p.alphaValue = 0
                p.orderFront(nil)
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = d
                    ctx.timingFunction = MioMotion.easeOut
                    p.animator().alphaValue = 1
                    p.animator().setFrame(final, display: true)
                }
            } else {
                p.setFrame(final, display: true)
                p.alphaValue = 1
                p.orderFront(nil)
            }
        } else {
            // 已显示：高度跟着条数平滑变化
            MioMotion.animate(MioMotion.fast, { p.animator().setFrame(final, display: true) })
        }
    }

    func setSelection(_ i: Int) {
        for (k, r) in rows.enumerated() { r.isSelected = k == i }
    }

    func hide(animated: Bool) {
        guard isVisible, let p = panel else { return }
        isVisible = false
        let finish = { p.parent?.removeChildWindow(p); p.orderOut(nil); p.alphaValue = 1 }
        if animated && MioMotion.duration(MioMotion.fast) > 0 {
            MioMotion.animate(MioMotion.fast, timing: MioMotion.easeIn, { p.animator().alphaValue = 0 }, completion: finish)
        } else {
            finish()
        }
    }

    var window: NSWindow? { panel }
    var rowCount: Int { rows.count }
}

@MainActor
final class MioMacSuggestionRow: NSView {
    static let height: CGFloat = 32
    var onClick: (() -> Void)?
    var onHover: (() -> Void)?
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let action = NSTextField(labelWithString: "")
    private var tracking: NSTrackingArea?
    var isSelected = false { didSet { if oldValue != isSelected { refresh() } } }

    init(_ s: MioSuggestion) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        translatesAutoresizingMaskIntoConstraints = false
        let sym: String
        var act: String
        switch s.kind {
        case .search: sym = "magnifyingglass"; act = "— 使用 Google 搜索"
        case .visit: sym = "globe"; act = "— 访问"
        case .switchTab: sym = "square.on.square"; act = "— 切换到标签页"
        case .bookmark: sym = "star.fill"; act = "— " + MioURLDisplay.displayString(URL(string: s.url))
        case .history: sym = "clock"; act = "— " + MioURLDisplay.displayString(URL(string: s.url))
        }
        if act == "— " { act = "" }
        icon.image = MioTheme.symbol(sym, 13)
        title.stringValue = s.title
        title.font = .systemFont(ofSize: 13)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(740), for: .horizontal)
        action.stringValue = act
        action.font = .systemFont(ofSize: 12)
        action.lineBreakMode = .byTruncatingTail
        action.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for v in [icon, title, action] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            action.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 6),
            action.centerYAnchor.constraint(equalTo: centerYAnchor),
            action.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
        ])
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func refresh() {
        let bg: NSColor = isSelected ? MioTheme.accent : .clear
        if let l = layer { MioMotion.layer(l, "backgroundColor", from: l.presentation()?.backgroundColor, to: MioTheme.cg(bg, in: self), duration: 0.08) }
        title.textColor = isSelected ? MioTheme.accentText : MioTheme.text
        action.textColor = isSelected ? MioTheme.accentText.withAlphaComponent(0.85) : MioTheme.secondaryText
        icon.contentTintColor = isSelected ? MioTheme.accentText : MioTheme.secondaryText
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { onHover?() }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { onClick?() }
}

// MARK: - 加载进度条

@MainActor
final class MioMacProgressBar: NSView {
    private let bar = CALayer()
    private let glow = CAGradientLayer()
    private(set) var progress: Double = 0
    private var visible = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        bar.anchorPoint = CGPoint(x: 0, y: 0.5)
        bar.cornerRadius = 1
        layer?.addSublayer(bar)
        glow.startPoint = CGPoint(x: 0, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 0.5)
        bar.addSublayer(glow)
        bar.opacity = 0
        setAccessibilityIdentifier("mio.progress")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bar.bounds = CGRect(x: 0, y: 0, width: bounds.width * CGFloat(progress), height: bounds.height)
        bar.position = CGPoint(x: 0, y: bounds.midY)
        glow.frame = CGRect(x: 0, y: 0, width: max(bounds.width, 1), height: bounds.height)
        CATransaction.commit()
    }

    /// 进度平滑前进（只往前走）；完成后走满再淡出
    func set(progress p: Double, loading: Bool) {
        let accent = MioTheme.cg(MioTheme.accent, in: self)
        bar.backgroundColor = accent
        glow.colors = [NSColor.clear.cgColor, NSColor.white.withAlphaComponent(0.35).cgColor, NSColor.clear.cgColor]
        let target = loading ? max(0.08, min(0.98, p)) : 1.0
        if loading && !visible {
            visible = true
            progress = 0
            MioMotion.layer(bar, "opacity", from: 0, to: Float(1), duration: MioMotion.fast)
            setWidth(0, animated: false)
            if MioMotion.duration(1) > 0 {
                let shimmer = CABasicAnimation(keyPath: "position.x")
                shimmer.fromValue = -bounds.width / 2
                shimmer.toValue = bounds.width * 1.5
                shimmer.duration = 1.4
                shimmer.repeatCount = .infinity
                glow.add(shimmer, forKey: "shimmer")
            }
        }
        guard visible else { return }
        if target >= progress || !loading {
            progress = target
            setWidth(CGFloat(target), animated: true)
        }
        if !loading {
            visible = false
            let d = MioMotion.duration(0.3)
            if d > 0 {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 1
                fade.toValue = 0
                fade.beginTime = CACurrentMediaTime() + 0.18
                fade.duration = d
                fade.fillMode = .backwards
                bar.opacity = 0
                bar.add(fade, forKey: "fade")
            } else {
                bar.opacity = 0
            }
            glow.removeAnimation(forKey: "shimmer")
        }
    }

    private func setWidth(_ f: CGFloat, animated: Bool) {
        let to = CGRect(x: 0, y: 0, width: bounds.width * f, height: bounds.height)
        if animated && MioMotion.duration(0.25) > 0 {
            MioMotion.layer(bar, "bounds", from: NSValue(rect: bar.presentation()?.bounds ?? bar.bounds), to: NSValue(rect: to), duration: 0.25)
        } else {
            CATransaction.begin(); CATransaction.setDisableActions(true); bar.bounds = to; CATransaction.commit()
        }
    }

    var isVisibleBar: Bool { visible }
}
