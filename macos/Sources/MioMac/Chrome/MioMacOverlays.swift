// MioMacOverlays.swift — 网页上方 / 下方的浮层：
//   - MioMacFindBar：Firefox 式查找栏（网页底部滑出；↑↓ 上一个 / 下一个、区分大小写、匹配计数、Esc 关闭）
//   - MioMacZoomHUD：⌘+ / ⌘- / ⌘0 时网页中央的缩放提示（淡入 + 微缩放，停 0.9 秒后淡出）
//   - MioMacToast：顶部小提示（例如 Mio 扩展开关后「重新载入后生效」）

import AppKit
import WebKit

// MARK: - 查找栏

@MainActor
final class MioMacFindBar: NSView, NSSearchFieldDelegate {
    static let height: CGFloat = 38
    let field = NSSearchField()
    let prevButton = MioMacToolbarButton(symbol: "chevron.up", size: 12, label: "上一个 (⇧⌘G)", weight: .semibold)
    let nextButton = MioMacToolbarButton(symbol: "chevron.down", size: 12, label: "下一个 (⌘G)", weight: .semibold)
    let caseBox = NSButton(checkboxWithTitle: "区分大小写", target: nil, action: nil)
    let status = NSTextField(labelWithString: "")
    let closeButton = MioMacToolbarButton(symbol: "xmark", size: 11, label: "关闭查找栏 (Esc)", weight: .semibold)
    weak var webView: WKWebView?
    var onClose: (() -> Void)?
    private var matchIndex = 0
    private var matchCount = 0
    private let topLine = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        field.placeholderString = "在页面中查找"
        field.delegate = self
        field.sendsSearchStringImmediately = true
        field.target = self
        field.action = #selector(searchChanged(_:))
        field.setAccessibilityIdentifier("mio.findbar.field")
        caseBox.target = self
        caseBox.action = #selector(searchChanged(_:))
        caseBox.font = .systemFont(ofSize: 12)
        status.font = .systemFont(ofSize: 12)
        status.textColor = MioTheme.secondaryText
        prevButton.onClick = { [weak self] in self?.find(backwards: true) }
        nextButton.onClick = { [weak self] in self?.find(backwards: false) }
        closeButton.onClick = { [weak self] in self?.onClose?() }
        topLine.wantsLayer = true
        for v in [field, prevButton, nextButton, caseBox, status, closeButton, topLine] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            topLine.topAnchor.constraint(equalTo: topAnchor),
            topLine.leadingAnchor.constraint(equalTo: leadingAnchor),
            topLine.trailingAnchor.constraint(equalTo: trailingAnchor),
            topLine.heightAnchor.constraint(equalToConstant: 1),
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.widthAnchor.constraint(equalToConstant: 260),
            prevButton.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 4),
            prevButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            prevButton.widthAnchor.constraint(equalToConstant: 26), prevButton.heightAnchor.constraint(equalToConstant: 26),
            nextButton.leadingAnchor.constraint(equalTo: prevButton.trailingAnchor, constant: 2),
            nextButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            nextButton.widthAnchor.constraint(equalToConstant: 26), nextButton.heightAnchor.constraint(equalToConstant: 26),
            caseBox.leadingAnchor.constraint(equalTo: nextButton.trailingAnchor, constant: 12),
            caseBox.centerYAnchor.constraint(equalTo: centerYAnchor),
            status.leadingAnchor.constraint(equalTo: caseBox.trailingAnchor, constant: 14),
            status.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 24), closeButton.heightAnchor.constraint(equalToConstant: 24),
        ])
        setAccessibilityIdentifier("mio.findbar")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyColors() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); applyColors() }

    func applyColors() {
        layer?.backgroundColor = MioTheme.cg(MioTheme.toolbar, in: self)
        topLine.layer?.backgroundColor = MioTheme.cg(MioTheme.separator, in: self)
    }

    func focus() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    @objc private func searchChanged(_ sender: Any?) {
        matchIndex = 0
        find(backwards: false, fresh: true)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) { onClose?(); return true }
        if sel == #selector(NSResponder.insertNewline(_:)) {
            find(backwards: NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false)
            return true
        }
        return false
    }

    func find(backwards: Bool, fresh: Bool = false) {
        let q = field.stringValue
        guard let wv = webView, !q.isEmpty else { status.stringValue = ""; return }
        let cfg = WKFindConfiguration()
        cfg.backwards = backwards
        cfg.caseSensitive = caseBox.state == .on
        cfg.wraps = true
        wv.find(q, configuration: cfg) { [weak self] r in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !r.matchFound {
                    self.status.stringValue = "未找到短语"
                    self.status.textColor = .systemRed
                    self.shake()
                    return
                }
                if fresh { self.countMatches(q) } else if self.matchCount > 0 {
                    self.matchIndex = backwards ? (self.matchIndex - 1 + self.matchCount) % self.matchCount : (self.matchIndex + 1) % self.matchCount
                    self.showCount()
                }
            }
        }
    }

    private func countMatches(_ q: String) {
        // WKWebView 没有公开的匹配数：在页面文本里数（与 Firefox「第 1 个，共 N 个匹配」一致的显示）
        let cs = caseBox.state == .on
        let js = "(function(q,cs){var t=(document.body&&document.body.innerText)||'';if(!cs){t=t.toLowerCase();q=q.toLowerCase();}var n=0,i=0;while(q&&(i=t.indexOf(q,i))!==-1){n++;i+=q.length;}return n;})(\(MioMacSmoke.jsonString(q)),\(cs ? "true" : "false"))"
        webView?.evaluateJavaScript(js) { [weak self] v, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.matchCount = (v as? Int) ?? (v as? NSNumber)?.intValue ?? 0
                self.matchIndex = 0
                self.showCount()
            }
        }
    }

    private func showCount() {
        status.textColor = MioTheme.secondaryText
        status.stringValue = matchCount > 0 ? "第 \(matchIndex + 1) 个，共 \(matchCount) 个匹配" : "找到匹配"
    }

    private func shake() {
        guard MioMotion.duration(0.3) > 0, let l = field.layer else { return }
        let a = CAKeyframeAnimation(keyPath: "transform.translation.x")
        a.values = [0, -6, 6, -4, 4, -2, 0]
        a.duration = 0.3
        l.add(a, forKey: "shake")
    }
}

// MARK: - 缩放提示

@MainActor
final class MioMacZoomHUD: NSVisualEffectView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "100%")
    private var hideWork: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 150, height: 56))
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
        icon.image = MioTheme.symbol("plus.magnifyingglass", 20, weight: .medium)
        icon.contentTintColor = .labelColor
        label.font = .monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
        label.textColor = .labelColor
        for v in [icon, label] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
        ])
        alphaValue = 0
        isHidden = true
        setAccessibilityIdentifier("mio.zoomhud")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(level: Double, zoomingIn: Bool?, in container: NSView) {
        label.stringValue = MioZoomCore.label(level)
        icon.image = MioTheme.symbol(zoomingIn == false ? "minus.magnifyingglass" : "plus.magnifyingglass", 20, weight: .medium)
        if superview !== container {
            removeFromSuperview()
            container.addSubview(self, positioned: .above, relativeTo: nil)
        }
        frame = NSRect(x: (container.bounds.width - 150) / 2, y: (container.bounds.height - 56) / 2, width: 150, height: 56).integral
        let wasShown = !isHidden && alphaValue > 0.5
        isHidden = false
        hideWork?.cancel()
        if !wasShown {
            if MioMotion.duration(MioMotion.fast) > 0, let l = layer {
                let s = CABasicAnimation(keyPath: "transform.scale")
                s.fromValue = 0.9
                s.toValue = 1
                s.duration = MioMotion.normal
                s.timingFunction = MioMotion.easeOut
                l.add(s, forKey: "pop")
            }
            MioMotion.animate(MioMotion.fast, { self.animator().alphaValue = 1 })
        } else if MioMotion.duration(MioMotion.fast) > 0, let l = label.layer {
            let t = CATransition()
            t.type = .push
            t.subtype = zoomingIn == false ? .fromBottom : .fromTop
            t.duration = MioMotion.fast
            l.add(t, forKey: "tick")
        }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                MioMotion.animate(0.25, timing: MioMotion.easeIn, { self.animator().alphaValue = 0 }, completion: { self.isHidden = self.alphaValue < 0.01 })
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }

    var isShowing: Bool { !isHidden && alphaValue > 0.01 }
}

// MARK: - 小提示

@MainActor
final class MioMacToast: NSView {
    private let label = NSTextField(labelWithString: "")
    private let button = NSButton(title: "", target: nil, action: nil)
    private var action: (() -> Void)?
    private var hideWork: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        label.font = .systemFont(ofSize: 12.5)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.target = self
        button.action = #selector(tapped)
        for v in [label, button] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 10),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            heightAnchor.constraint(equalToConstant: 38),
        ])
        alphaValue = 0
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func tapped() { action?(); hide() }

    func show(_ text: String, button title: String?, in container: NSView, action: (() -> Void)? = nil) {
        layer?.backgroundColor = MioTheme.cg(MioTheme.panel, in: container)
        label.stringValue = text
        label.textColor = MioTheme.text
        button.title = title ?? ""
        button.isHidden = title == nil
        self.action = action
        if superview !== container { removeFromSuperview(); container.addSubview(self, positioned: .above, relativeTo: nil) }
        let size = fittingSize
        let final = NSRect(x: (container.bounds.width - size.width) / 2, y: container.bounds.height - size.height - 12, width: size.width, height: size.height).integral
        isHidden = false
        frame = final.offsetBy(dx: 0, dy: MioMotion.reduce ? 0 : 10)
        MioMotion.animate(MioMotion.normal, {
            self.animator().frame = final
            self.animator().alphaValue = 1
        })
        hideWork?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.hide() } }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: w)
    }

    func hide() {
        MioMotion.animate(MioMotion.fast, { self.animator().alphaValue = 0 }, completion: { self.isHidden = true })
    }
}
