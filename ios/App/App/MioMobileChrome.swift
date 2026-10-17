// MioMobileChrome.swift — iPhone 内置浏览器的 Safari（iOS 27）式布局：紧凑 / 底部 / 顶部（纯逻辑在 MioMobileChromeCore.swift）
//
// 只用于 iPhone（MioBrowserViewController.usesTopChrome == false）；iPad / Mac 保持 v0.3.3 的顶部工具栏 + 标签条（MioTabs.swift）。
// 挂钩：MioTabs.installTabChrome() 在 iPhone 上调用 MioMobileChrome.install(on:)，原来的顶栏 / 底部 UIToolbar / 域名条隐藏不用；
// MioBrowserViewController 的 desiredInsets / setChromeHidden / metrics 在 mobileChrome 存在时交给这里。
//
// - webView 铺满整个屏幕（内容可以滚到状态栏和悬浮栏下面），栏浮在上面，用 contentInset 让出位置（与 v0.3.2 同一方案）。
// - 紧凑：页面上方没有栏，只有状态栏下的一层模糊（不是栏，不会露出一截）。底部悬浮 Liquid Glass 胶囊：
//   后退（长按 = 历史）· 页面菜单 · 地址栏（域名、进度、右侧刷新 / 停止；点 = 编辑完整网址，长按 = 复制 / 粘贴并前往 / 分享，
//   左右滑 = 切换标签，上滑 = 标签概览）· 标签按钮（两个重叠方块；长按 = 新建 / 新建容器标签 / 关闭 / 回到 Mio 导航）。
// - 向下滚动：栏收缩成底部小域名胶囊（顶部布局：顶部域名条），向上滚动或点它恢复。
// - 页面菜单（MioPageMenuViewController）：原来底部工具栏 / 顶栏的全部入口（前进、分享、翻译、阅读、深色、存到 Mio、拦截、
//   用户脚本、WebRTC、YouTube 防沉迷、用 Safari 打开、查找、请求桌面网站、设置、回到 Mio 导航）。

import UIKit
import WebKit

extension Notification.Name {
    static let mioBrowserLayoutDidChange = Notification.Name("mio.browser.layoutDidChange")
}

// MARK: - Settings

enum MioMobileLayoutSettings {
    /// 也可以用启动参数覆盖（UserDefaults 参数域）：-mio.browser.layout bottom（CI 冒烟用）
    static let key = "mio.browser.layout"

    static var layout: MioBrowserLayout {
        get { MioBrowserLayout.parse(UserDefaults.standard.string(forKey: key)) }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            NotificationCenter.default.post(name: .mioBrowserLayoutDidChange, object: nil)
        }
    }
}

/// 浏览器设置页里的「浏览器布局」一行（只在 iPhone 显示）
enum MioMobileLayoutSettingsUI {
    static var applies: Bool { !MioBrowserViewController.usesTopChrome }

    static func configure(_ cell: UITableViewCell) {
        let l = MioMobileLayoutSettings.layout
        cell.textLabel?.text = "浏览器布局"
        cell.detailTextLabel?.text = "\(l.title) · \(l.detail)"
        cell.accessoryType = .disclosureIndicator
        cell.selectionStyle = .default
    }

    static func choose(from vc: UIViewController, sourceView: UIView?, done: @escaping () -> Void) {
        let cur = MioMobileLayoutSettings.layout
        let a = UIAlertController(title: "浏览器布局", message: "与 Safari 相同的三种布局。向下滚动时栏会收缩成域名胶囊，向上滚动或点它恢复。", preferredStyle: .actionSheet)
        for l in MioBrowserLayout.allCases {
            a.addAction(UIAlertAction(title: l.title + (l == cur ? " ✓" : "") + (l == .defaultLayout ? "（默认）" : ""), style: .default) { _ in
                MioMobileLayoutSettings.layout = l
                done()
            })
        }
        a.addAction(UIAlertAction(title: "取消", style: .cancel))
        if let pop = a.popoverPresentationController {
            pop.sourceView = sourceView ?? vc.view
            pop.sourceRect = sourceView?.bounds ?? CGRect(x: vc.view.bounds.midX, y: vc.view.bounds.midY, width: 1, height: 1)
        }
        vc.present(a, animated: true)
    }
}

// MARK: - Liquid Glass

enum MioGlass {
    /// iOS 26+ 用系统 Liquid Glass（UIGlassEffect），更早的系统用 chrome 材质模糊
    static func make(cornerRadius: CGFloat) -> UIVisualEffectView {
        var effect: UIVisualEffect = UIBlurEffect(style: .systemChromeMaterial)
        #if compiler(>=6.2)
        if #available(iOS 26.0, macCatalyst 26.0, *) { effect = UIGlassEffect() }
        #endif
        let v = UIVisualEffectView(effect: effect)
        v.layer.cornerRadius = cornerRadius
        v.layer.cornerCurve = .continuous
        v.clipsToBounds = true
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }

    static func bar() -> UIVisualEffectView {
        let v = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }
}

// MARK: - Address bar

/// 地址栏：域名（居中）+ 进度条 + 右侧刷新 / 停止；编辑时显示浏览器原来的 addressField（完整网址）
final class MioMobileAddressBar: UIControl {
    let hostLabel = UILabel()
    let reloadButton = UIButton(type: .system)
    let progress = UIProgressView(progressViewStyle: .bar)
    let leading = UIStackView()
    var menuProvider: (() -> UIMenu?)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        hostLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        hostLabel.textAlignment = .center
        hostLabel.textColor = .label
        hostLabel.lineBreakMode = .byTruncatingMiddle
        hostLabel.isUserInteractionEnabled = false
        hostLabel.translatesAutoresizingMaskIntoConstraints = false
        hostLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(hostLabel)
        reloadButton.translatesAutoresizingMaskIntoConstraints = false
        reloadButton.tintColor = .label
        reloadButton.setImage(UIImage(systemName: "arrow.clockwise", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)), for: .normal)
        reloadButton.accessibilityLabel = "刷新"
        addSubview(reloadButton)
        leading.axis = .horizontal
        leading.alignment = .center
        leading.spacing = 0
        leading.translatesAutoresizingMaskIntoConstraints = false
        addSubview(leading)
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.trackTintColor = .clear
        progress.isUserInteractionEnabled = false
        addSubview(progress)
        NSLayoutConstraint.activate([
            leading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            leading.centerYAnchor.constraint(equalTo: centerYAnchor),
            reloadButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            reloadButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            reloadButton.widthAnchor.constraint(equalToConstant: 36),
            reloadButton.heightAnchor.constraint(equalToConstant: 36),
            hostLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            hostLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            hostLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leading.trailingAnchor, constant: 4),
            hostLabel.trailingAnchor.constraint(lessThanOrEqualTo: reloadButton.leadingAnchor, constant: -4),
            progress.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            progress.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            progress.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            progress.heightAnchor.constraint(equalToConstant: 2),
        ])
        isContextMenuInteractionEnabled = true
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let provider = menuProvider else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in provider() }
    }
}

// MARK: - Chrome

final class MioMobileChrome: NSObject, UIGestureRecognizerDelegate {
    private weak var browser: MioBrowserViewController?
    private(set) var layout: MioBrowserLayout
    private(set) var collapsed = false
    private(set) var editing = false
    /// 本标签「请求桌面网站」
    private(set) var desktopMode = false
    private var translateState: [String: Any]?

    // 本次布局创建的视图 / 约束（换布局时整体拆掉重建）
    private var views: [UIView] = []
    private var built: [NSLayoutConstraint] = []
    private var webViewPinned = false

    private var statusBackdrop: UIView?
    /// 紧凑：玻璃胶囊；底部：整块（地址栏 + 工具行）；顶部：底部工具行
    private var bottomChrome: UIView?
    /// 顶部布局：顶部地址栏（含状态栏区域）
    private var topChrome: UIView?
    private(set) var address = MioMobileAddressBar()
    private var pill = UIControl()
    private var pillLabel = UILabel()
    private var topStrip = UIControl()
    private var topStripLabel = UILabel()
    private(set) var backButton = UIButton(type: .system)
    private var forwardButton = UIButton(type: .system)
    private(set) var menuButton = UIButton(type: .system)
    private(set) var tabsButton = UIButton(type: .system)
    private var cancelButton = UIButton(type: .system)
    /// 编辑地址时隐藏的按钮（紧凑胶囊里的 后退 / 菜单 / 标签；底部布局的工具行）
    private var hideWhileEditing: [UIView] = []
    private var barBottomSafe: NSLayoutConstraint?
    private var barBottomKeyboard: NSLayoutConstraint?
    private var topExpanded: NSLayoutConstraint?
    private var topCollapsed: NSLayoutConstraint?
    private var observations: [NSKeyValueObservation] = []
    private var tokens: [NSObjectProtocol] = []

    private static let barHeight: CGFloat = 52
    private static let rowHeight: CGFloat = 44
    private static let addressHeight: CGFloat = 40
    private static let pillHeight: CGFloat = 28
    private static let stripHeight: CGFloat = 24

    init(browser: MioBrowserViewController, layout: MioBrowserLayout) {
        self.browser = browser
        self.layout = layout
        super.init()
    }

    deinit {
        observations.forEach { $0.invalidate() }
        tokens.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// MioTabs.installTabChrome（iPhone）调用
    @discardableResult
    static func install(on b: MioBrowserViewController) -> MioMobileChrome {
        let c = MioMobileChrome(browser: b, layout: MioMobileLayoutSettings.layout)
        b.mobileChrome = c
        c.setUp()
        return c
    }

    private func setUp() {
        guard let b = browser, let wv = b.webView else { return }
        // 原来的顶栏 / 底部工具栏 / 顶部域名条不再显示（视图留着：别的代码仍可能引用它们）
        b.topBar.isHidden = true
        b.toolbar.isHidden = true
        b.miniBar.isHidden = true
        b.progress.isHidden = true
        b.addressField.rightView = nil
        if #available(iOS 16.0, macCatalyst 16.0, *) { wv.isFindInteractionEnabled = true }
        pinWebViewFullScreen()
        build()
        observations = [
            wv.observe(\.url, options: [.new]) { [weak self] _, _ in self?.updateAddress() },
            wv.observe(\.title, options: [.new]) { [weak self] _, _ in self?.updateAddress() },
            wv.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in self?.updateProgress() },
            wv.observe(\.isLoading, options: [.new]) { [weak self] _, _ in self?.updateProgress() },
            wv.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in self?.updateButtons() },
            wv.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in self?.updateButtons() },
        ]
        let field = b.addressField
        tokens.append(NotificationCenter.default.addObserver(forName: UITextField.textDidBeginEditingNotification, object: field, queue: .main) { [weak self] _ in
            self?.setEditing(true)
        })
        tokens.append(NotificationCenter.default.addObserver(forName: UITextField.textDidEndEditingNotification, object: field, queue: .main) { [weak self] _ in
            self?.setEditing(false)
        })
        tokens.append(NotificationCenter.default.addObserver(forName: .mioBrowserLayoutDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.relayout(MioMobileLayoutSettings.layout)
        })
    }

    /// webView 原来贴着安全区上下沿；Safari 式布局里它铺满整个屏幕（左右仍然贴安全区，横屏不钻到刘海下）
    private func pinWebViewFullScreen() {
        guard !webViewPinned, let b = browser, let view = b.view, let wv = b.webView else { return }
        webViewPinned = true
        for c in view.constraints where ((c.firstItem as? WKWebView) === wv && (c.firstAttribute == .top || c.firstAttribute == .bottom))
            || ((c.secondItem as? WKWebView) === wv && (c.secondAttribute == .top || c.secondAttribute == .bottom)) {
            c.isActive = false
        }
        NSLayoutConstraint.activate([
            wv.topAnchor.constraint(equalTo: view.topAnchor),
            wv.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // MARK: build

    private func teardown() {
        NSLayoutConstraint.deactivate(built)
        built = []
        views.forEach { $0.removeFromSuperview() }
        views = []
        hideWhileEditing = []
        statusBackdrop = nil
        bottomChrome = nil
        topChrome = nil
        barBottomSafe = nil
        barBottomKeyboard = nil
        topExpanded = nil
        topCollapsed = nil
    }

    private func relayout(_ l: MioBrowserLayout) {
        guard l != layout, let b = browser else { return }
        if editing { b.addressField.resignFirstResponder() }
        layout = l
        build()
        b.showChrome(animated: false)
        b.view.setNeedsLayout()
    }

    private func symbol(_ name: String, _ size: CGFloat = 17) -> UIImage? {
        UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: .medium))
    }

    private func makeButton(_ symbolName: String, _ label: String, size: CGFloat = 44, pointSize: CGFloat = 17) -> UIButton {
        let btn = UIButton(type: .system)
        btn.setImage(symbol(symbolName, pointSize), for: .normal)
        btn.tintColor = .label
        btn.accessibilityLabel = label
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.widthAnchor.constraint(equalToConstant: size).isActive = true
        btn.heightAnchor.constraint(equalToConstant: size).isActive = true
        return btn
    }

    private func build() {
        guard let b = browser, let view = b.view else { return }
        teardown()
        let safe = view.safeAreaLayoutGuide
        var cs: [NSLayoutConstraint] = []

        // 公共控件
        address = MioMobileAddressBar()
        address.addAction(UIAction { [weak self] _ in self?.beginEditing() }, for: .touchUpInside)
        address.reloadButton.addAction(UIAction { [weak self] _ in self?.reloadOrStop() }, for: .touchUpInside)
        address.menuProvider = { [weak self] in self?.addressMenu() }
        let pan = UIPanGestureRecognizer(target: self, action: #selector(addressPanned(_:)))
        pan.delegate = self
        address.addGestureRecognizer(pan)
        let field = b.addressField
        field.removeFromSuperview()
        field.translatesAutoresizingMaskIntoConstraints = false
        field.alpha = editing ? 1 : 0
        field.isUserInteractionEnabled = editing
        // 完整网址很长：编辑框不能把胶囊撑出屏幕
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        address.addSubview(field)
        cs += [
            field.leadingAnchor.constraint(equalTo: address.leadingAnchor, constant: 4),
            field.trailingAnchor.constraint(equalTo: address.trailingAnchor, constant: -4),
            field.centerYAnchor.constraint(equalTo: address.centerYAnchor),
        ]
        if let c = MioContainerUX.badge(for: b.containerID) {
            // 容器标签：地址栏左侧色点 + 容器名
            let badge = UILabel()
            let text = NSMutableAttributedString(string: "● ", attributes: [.foregroundColor: c.color, .font: UIFont.systemFont(ofSize: 11)])
            text.append(NSAttributedString(string: c.name, attributes: [.foregroundColor: c.color, .font: UIFont.systemFont(ofSize: 12, weight: .semibold)]))
            badge.attributedText = text
            badge.lineBreakMode = .byTruncatingTail
            badge.accessibilityLabel = "容器：\(c.name)"
            badge.translatesAutoresizingMaskIntoConstraints = false
            badge.setContentCompressionResistancePriority(.required, for: .horizontal)
            address.leading.addArrangedSubview(badge)
            cs += [badge.widthAnchor.constraint(lessThanOrEqualToConstant: 90)]
            address.leading.spacing = 4
            address.leading.isLayoutMarginsRelativeArrangement = true
            address.leading.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 0)
        }
        if let reader = b.pageTools?.readerButton {
            reader.removeFromSuperview()
            reader.translatesAutoresizingMaskIntoConstraints = false
            address.leading.addArrangedSubview(reader)
            cs += [reader.widthAnchor.constraint(equalToConstant: 34), reader.heightAnchor.constraint(equalToConstant: 30)]
        }

        backButton = makeButton("chevron.backward", "后退")
        backButton.addAction(UIAction { [weak self] _ in self?.browser?.webView?.goBack() }, for: .touchUpInside)
        backButton.menu = historyMenu(back: true)
        backButton.showsMenuAsPrimaryAction = false
        forwardButton = makeButton("chevron.forward", "前进")
        forwardButton.addAction(UIAction { [weak self] _ in self?.browser?.webView?.goForward() }, for: .touchUpInside)
        forwardButton.menu = historyMenu(back: false)
        forwardButton.showsMenuAsPrimaryAction = false
        // 紧凑：胶囊里单独的按钮；底部 / 顶部：地址栏左侧的「页面菜单」（像 Safari 的 aA）
        menuButton = layout.menuInAddressBar ? makeButton("textformat.size", "页面菜单", size: 36, pointSize: 15) : makeButton("line.3.horizontal", "页面菜单")
        menuButton.addAction(UIAction { [weak self] _ in self?.presentPageMenu() }, for: .touchUpInside)
        tabsButton = makeButton("square.on.square", "标签页")
        tabsButton.addAction(UIAction { [weak self] _ in self?.browser?.tabsController?.showOverview() }, for: .touchUpInside)
        tabsButton.menu = tabsMenu()
        tabsButton.showsMenuAsPrimaryAction = false
        cancelButton = UIButton(type: .system)
        cancelButton.setTitle("取消", for: .normal)
        cancelButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.isHidden = true
        cancelButton.addAction(UIAction { [weak self] _ in self?.browser?.addressField.resignFirstResponder() }, for: .touchUpInside)

        // 收缩胶囊（紧凑 / 底部）与顶部域名条（顶部）
        pill = UIControl()
        pillLabel = UILabel()
        topStrip = UIControl()
        topStripLabel = UILabel()

        switch layout {
        case .compact:
            cs += buildCompact(view: view, safe: safe)
        case .bottom:
            cs += buildBottom(view: view, safe: safe)
        case .top:
            cs += buildTop(view: view, safe: safe)
        }
        if layout != .top {
            // 状态栏下的一层模糊（不是栏：高度 = 状态栏，内容在它下面滚动时文字清楚）
            let backdrop = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
            backdrop.translatesAutoresizingMaskIntoConstraints = false
            backdrop.isUserInteractionEnabled = false
            view.addSubview(backdrop)
            views.append(backdrop)
            statusBackdrop = backdrop
            cs += [
                backdrop.topAnchor.constraint(equalTo: view.topAnchor),
                backdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                backdrop.bottomAnchor.constraint(equalTo: safe.topAnchor),
            ]
            cs += buildPill(view: view, safe: safe)
        }
        NSLayoutConstraint.activate(cs)
        built = cs
        applyCollapse(collapsed)
        updateAddress()
        updateProgress()
        updateButtons()
        tabCountChanged(b.tabsController?.store.count ?? 1)
    }

    /// 紧凑：一条悬浮玻璃胶囊 [后退][菜单][地址栏][标签]
    private func buildCompact(view: UIView, safe: UILayoutGuide) -> [NSLayoutConstraint] {
        let bar = MioGlass.make(cornerRadius: Self.barHeight / 2)
        view.addSubview(bar)
        views.append(bar)
        bottomChrome = bar
        let stack = UIStackView(arrangedSubviews: [backButton, menuButton, address, cancelButton, tabsButton])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.contentView.addSubview(stack)
        hideWhileEditing = [backButton, menuButton, tabsButton]
        let width = bar.widthAnchor.constraint(equalTo: safe.widthAnchor, constant: -20)
        width.priority = .defaultHigh
        let safeBottom = bar.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -4)
        let kb = bar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -6)
        barBottomSafe = safeBottom
        barBottomKeyboard = kb
        let addressHeight = address.heightAnchor.constraint(equalToConstant: Self.addressHeight)
        return [
            bar.centerXAnchor.constraint(equalTo: safe.centerXAnchor),
            width,
            bar.widthAnchor.constraint(lessThanOrEqualToConstant: 640),
            bar.leadingAnchor.constraint(greaterThanOrEqualTo: safe.leadingAnchor, constant: 10),
            bar.trailingAnchor.constraint(lessThanOrEqualTo: safe.trailingAnchor, constant: -10),
            bar.heightAnchor.constraint(equalToConstant: Self.barHeight),
            editing ? kb : safeBottom,
            stack.leadingAnchor.constraint(equalTo: bar.contentView.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: bar.contentView.trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: bar.contentView.centerYAnchor),
            addressHeight,
            cancelButton.widthAnchor.constraint(equalToConstant: 52),
        ]
    }

    /// 地址栏行（底部 / 顶部布局）：[页面菜单][地址栏（圆角底色）][取消]
    private func addressRow() -> UIStackView {
        address.backgroundColor = .tertiarySystemFill
        address.layer.cornerRadius = 12
        address.layer.cornerCurve = .continuous
        address.leading.insertArrangedSubview(menuButton, at: 0)
        let row = UIStackView(arrangedSubviews: [address, cancelButton])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        address.heightAnchor.constraint(equalToConstant: Self.addressHeight).isActive = true
        cancelButton.widthAnchor.constraint(equalToConstant: 52).isActive = true
        return row
    }

    /// 工具行：后退 前进 分享 存到 Mio 标签
    private func toolRow() -> UIStackView {
        let share = makeButton("square.and.arrow.up", "分享")
        share.addAction(UIAction { [weak self] _ in self?.share(from: share) }, for: .touchUpInside)
        let mio = makeButton("book", "存到 Mio / 书签")
        mio.showsMenuAsPrimaryAction = true
        mio.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in
            done(self?.browser?.pageTools?.makeMenu().children ?? [])
        }])
        let row = UIStackView(arrangedSubviews: [backButton, forwardButton, share, mio, tabsButton])
        row.axis = .horizontal
        row.alignment = .center
        row.distribution = .equalSpacing
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    /// 底部：模糊底栏，地址栏一行 + 工具行（编辑时工具行隐藏，地址栏贴着键盘）
    private func buildBottom(view: UIView, safe: UILayoutGuide) -> [NSLayoutConstraint] {
        let bg = MioGlass.bar()
        view.addSubview(bg)
        views.append(bg)
        bottomChrome = bg
        let aRow = addressRow()
        let tRow = toolRow()
        let stack = UIStackView(arrangedSubviews: [aRow, tRow])
        stack.axis = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        views.append(stack)
        hideWhileEditing = [tRow]
        let safeBottom = stack.bottomAnchor.constraint(equalTo: safe.bottomAnchor)
        let kb = stack.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -6)
        barBottomSafe = safeBottom
        barBottomKeyboard = kb
        return [
            stack.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -12),
            tRow.heightAnchor.constraint(equalToConstant: Self.rowHeight),
            editing ? kb : safeBottom,
            bg.topAnchor.constraint(equalTo: stack.topAnchor, constant: -8),
            bg.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bg.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bg.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ]
    }

    /// 顶部：顶部模糊栏（状态栏 + 地址栏），底部模糊工具行；收缩时顶部变成域名条、工具行滑出屏幕
    private func buildTop(view: UIView, safe: UILayoutGuide) -> [NSLayoutConstraint] {
        let top = MioGlass.bar()
        top.clipsToBounds = true
        view.addSubview(top)
        views.append(top)
        topChrome = top
        let aRow = addressRow()
        top.contentView.addSubview(aRow)
        topStripLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        topStripLabel.textAlignment = .center
        topStripLabel.textColor = .label
        topStripLabel.translatesAutoresizingMaskIntoConstraints = false
        topStripLabel.isUserInteractionEnabled = false
        topStrip.translatesAutoresizingMaskIntoConstraints = false
        topStrip.addSubview(topStripLabel)
        topStrip.isAccessibilityElement = true
        topStrip.accessibilityTraits = .button
        topStrip.accessibilityHint = "显示地址栏和工具栏"
        topStrip.addAction(UIAction { [weak self] _ in self?.browser?.showChrome(animated: true) }, for: .touchUpInside)
        top.contentView.addSubview(topStrip)
        let expanded = top.bottomAnchor.constraint(equalTo: safe.topAnchor, constant: Self.addressHeight + 12)
        let collapsedC = top.bottomAnchor.constraint(equalTo: safe.topAnchor, constant: Self.stripHeight)
        topExpanded = expanded
        topCollapsed = collapsedC

        let bottomBG = MioGlass.bar()
        view.addSubview(bottomBG)
        views.append(bottomBG)
        bottomChrome = bottomBG
        let tRow = toolRow()
        bottomBG.contentView.addSubview(tRow)
        return [
            top.topAnchor.constraint(equalTo: view.topAnchor),
            top.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            top.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collapsed ? collapsedC : expanded,
            aRow.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 12),
            aRow.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -12),
            aRow.topAnchor.constraint(equalTo: safe.topAnchor, constant: 6),
            topStrip.leadingAnchor.constraint(equalTo: top.leadingAnchor),
            topStrip.trailingAnchor.constraint(equalTo: top.trailingAnchor),
            topStrip.topAnchor.constraint(equalTo: safe.topAnchor),
            topStrip.heightAnchor.constraint(equalToConstant: Self.stripHeight),
            topStripLabel.centerXAnchor.constraint(equalTo: topStrip.centerXAnchor),
            topStripLabel.topAnchor.constraint(equalTo: topStrip.topAnchor, constant: 2),
            topStripLabel.widthAnchor.constraint(lessThanOrEqualTo: topStrip.widthAnchor, constant: -32),
            // 底部工具行：收缩时整块往下移出屏幕（applyCollapse 里用 transform，不改约束）
            bottomBG.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBG.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBG.topAnchor.constraint(equalTo: safe.bottomAnchor, constant: -Self.rowHeight),
            bottomBG.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            tRow.topAnchor.constraint(equalTo: bottomBG.topAnchor),
            tRow.heightAnchor.constraint(equalToConstant: Self.rowHeight),
            tRow.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 12),
            tRow.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -12),
        ]
    }

    /// 收缩后的底部域名胶囊（紧凑 / 底部布局）
    private func buildPill(view: UIView, safe: UILayoutGuide) -> [NSLayoutConstraint] {
        let glass = MioGlass.make(cornerRadius: Self.pillHeight / 2)
        glass.isUserInteractionEnabled = false
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.isAccessibilityElement = true
        pill.accessibilityTraits = .button
        pill.accessibilityHint = "显示地址栏和工具栏"
        pill.addAction(UIAction { [weak self] _ in self?.browser?.showChrome(animated: true) }, for: .touchUpInside)
        pill.addSubview(glass)
        pillLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        pillLabel.textColor = .label
        pillLabel.textAlignment = .center
        pillLabel.translatesAutoresizingMaskIntoConstraints = false
        pillLabel.isUserInteractionEnabled = false
        pill.addSubview(pillLabel)
        view.addSubview(pill)
        views.append(pill)
        // 有 Home 指示条的机型：胶囊落在指示条上方的安全区里（Safari 一样）；Home 键机型贴底边
        let bottom = pill.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -4)
        let inSafe = pill.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: 6)
        inSafe.priority = .defaultHigh
        return [
            pill.centerXAnchor.constraint(equalTo: safe.centerXAnchor),
            pill.heightAnchor.constraint(equalToConstant: Self.pillHeight),
            pill.widthAnchor.constraint(lessThanOrEqualTo: safe.widthAnchor, constant: -80),
            pill.widthAnchor.constraint(greaterThanOrEqualToConstant: 96),
            bottom,
            inSafe,
            glass.topAnchor.constraint(equalTo: pill.topAnchor),
            glass.bottomAnchor.constraint(equalTo: pill.bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: pill.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: pill.trailingAnchor),
            pillLabel.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 14),
            pillLabel.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -14),
            pillLabel.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
        ]
    }

    // MARK: state

    private func updateAddress() {
        guard let b = browser else { return }
        let url = b.webView?.url
        var host = MioMobileChromeCore.displayHost(url?.absoluteString)
        if host.isEmpty { host = url?.scheme == "about" ? "" : (b.webView?.title ?? "") }
        address.hostLabel.text = host.isEmpty ? "搜索或输入网站名称" : host
        address.hostLabel.textColor = host.isEmpty ? .secondaryLabel : .label
        address.accessibilityLabel = "地址栏，" + (host.isEmpty ? "空" : host)
        pillLabel.text = host
        topStripLabel.text = host
        pill.accessibilityLabel = host
        topStrip.accessibilityLabel = host
    }

    private func updateProgress() {
        guard let wv = browser?.webView else { return }
        let p = Float(wv.estimatedProgress)
        address.progress.setProgress(p, animated: p > address.progress.progress)
        address.progress.isHidden = !wv.isLoading || p >= 1
        address.reloadButton.setImage(symbol(wv.isLoading ? "xmark" : "arrow.clockwise", 14), for: .normal)
        address.reloadButton.accessibilityLabel = wv.isLoading ? "停止" : "刷新"
    }

    private func updateButtons() {
        guard let wv = browser?.webView else { return }
        backButton.isEnabled = wv.canGoBack
        forwardButton.isEnabled = wv.canGoForward
    }

    /// MioTabChrome.reload(count:) 调用
    func tabCountChanged(_ count: Int) {
        tabsButton.accessibilityValue = "\(count) 个标签页"
    }

    private func reloadOrStop() {
        guard let wv = browser?.webView else { return }
        if wv.isLoading { wv.stopLoading() } else if wv.url != nil { wv.reload() }
    }

    // MARK: editing

    private func beginEditing() {
        guard let b = browser, !editing else { return }
        setEditing(true)
        b.addressField.becomeFirstResponder()
    }

    private func setEditing(_ on: Bool) {
        guard let b = browser, on != editing else { return }
        editing = on
        let field = b.addressField
        field.isUserInteractionEnabled = on
        if on, layout != .top {
            barBottomSafe?.isActive = false
            barBottomKeyboard?.isActive = true
        } else {
            barBottomKeyboard?.isActive = false
            barBottomSafe?.isActive = true
        }
        UIView.animate(withDuration: 0.22, delay: 0, options: [.beginFromCurrentState, .curveEaseInOut]) {
            field.alpha = on ? 1 : 0
            self.address.hostLabel.alpha = on ? 0 : 1
            self.address.reloadButton.alpha = on ? 0 : 1
            self.address.leading.alpha = on ? 0 : 1
            self.hideWhileEditing.forEach { $0.isHidden = on }
            self.cancelButton.isHidden = !on
            b.view.layoutIfNeeded()
        }
    }

    // MARK: collapse（MioBrowserViewController.setChromeHidden 调用）

    /// 动画之前：改约束
    func prepareCollapse(_ hide: Bool) {
        collapsed = hide
        if hide && editing { browser?.addressField.resignFirstResponder() }
        guard layout == .top else { return }
        if hide {
            topExpanded?.isActive = false
            topCollapsed?.isActive = true
        } else {
            topCollapsed?.isActive = false
            topExpanded?.isActive = true
        }
    }

    /// 动画里：透明度 / 缩放
    func applyCollapse(_ hide: Bool) {
        collapsed = hide
        switch layout {
        case .compact, .bottom:
            bottomChrome?.alpha = hide ? 0 : 1
            bottomChrome?.isUserInteractionEnabled = !hide
            if layout == .compact {
                bottomChrome?.transform = hide ? CGAffineTransform(scaleX: 0.55, y: 0.6).translatedBy(x: 0, y: 30) : .identity
            } else {
                // 底部布局：地址栏 + 工具行这一整块（stack 与背景）一起淡出
                views.compactMap { $0 as? UIStackView }.forEach { $0.alpha = hide ? 0 : 1; $0.isUserInteractionEnabled = !hide }
            }
            pill.alpha = hide ? 1 : 0
            pill.isUserInteractionEnabled = hide
        case .top:
            (topChrome as? UIVisualEffectView)?.contentView.subviews.forEach { v in
                if v === topStrip { v.alpha = hide ? 1 : 0; v.isUserInteractionEnabled = hide } else { v.alpha = hide ? 0 : 1 }
            }
            bottomChrome?.alpha = hide ? 0 : 1
            bottomChrome?.transform = hide ? CGAffineTransform(translationX: 0, y: (bottomChrome?.bounds.height ?? 80) + 4) : .identity
            bottomChrome?.isUserInteractionEnabled = !hide
        }
    }

    private func geometry() -> MioMobileChromeCore.Geometry {
        guard let view = browser?.view else {
            return MioMobileChromeCore.Geometry(viewHeight: 0, safeTop: 0, safeBottom: 0, bottomChromeMinY: 0, collapsedPillMinY: 0)
        }
        let h = Double(view.bounds.height)
        let safeTop = Double(view.safeAreaInsets.top)
        let safeBottom = Double(view.safeAreaInsets.bottom)
        var bottomMin = h
        if let bc = bottomChrome {
            // 紧凑胶囊收缩时有缩放；用 center / bounds 算未缩放的位置
            bottomMin = Double(bc.center.y - bc.bounds.height / 2)
        }
        if layout == .bottom, let stack = views.first(where: { $0 is UIStackView }) {
            bottomMin = min(bottomMin, Double(stack.frame.minY) - 8)
        }
        let pillMin = pill.superview == nil ? h - safeBottom : Double(pill.frame.minY)
        return MioMobileChromeCore.Geometry(viewHeight: h, safeTop: safeTop, safeBottom: safeBottom, bottomChromeMinY: bottomMin,
                                            collapsedPillMinY: pillMin,
                                            topChromeMaxY: safeTop + Double(Self.addressHeight + 12),
                                            collapsedTopMaxY: safeTop + Double(Self.stripHeight))
    }

    /// MioBrowserViewController.desiredInsets
    func insets(hidden: Bool) -> UIEdgeInsets {
        let e = MioMobileChromeCore.contentInsets(layout: layout, collapsed: hidden, g: geometry())
        return UIEdgeInsets(top: CGFloat(e.top), left: 0, bottom: CGFloat(e.bottom), right: 0)
    }

    /// MioToolbarAutoHide 的「到顶」位置
    var hiddenTopInset: CGFloat { CGFloat(MioMobileChromeCore.hiddenTopInset(layout: layout, g: geometry())) }

    // MARK: gestures

    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard !editing, let pan = g as? UIPanGestureRecognizer else { return !editing }
        let v = pan.velocity(in: address)
        // 只接管明显的横向 / 向上拖动，其余交给点按和长按菜单
        return abs(v.x) > abs(v.y) || v.y < 0
    }

    @objc private func addressPanned(_ pan: UIPanGestureRecognizer) {
        guard pan.state == .ended, let b = browser, let tabs = b.tabsController else { return }
        let t = pan.translation(in: address)
        let v = pan.velocity(in: address)
        let swipe = MioMobileChromeCore.classifySwipe(dx: Double(t.x), dy: Double(t.y), vx: Double(v.x), vy: Double(v.y))
        switch swipe {
        case .overview:
            tabs.showOverview()
        case .nextTab, .previousTab:
            switch MioMobileChromeCore.tabSwitch(ids: tabs.store.tabs.map(\.id), active: tabs.store.activeID, swipe: swipe) {
            case .select(let id):
                UISelectionFeedbackGenerator().selectionChanged()
                tabs.select(id)
            case .newTab:
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                tabs.mioNewTab(nil)
            case .none:
                break
            }
        case .none:
            break
        }
    }

    // MARK: menus

    /// 长按后退 / 前进：历史列表
    private func historyMenu(back: Bool) -> UIMenu {
        UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in
            guard let wv = self?.browser?.webView else { done([]); return }
            let list = back ? Array(wv.backForwardList.backList.reversed()) : wv.backForwardList.forwardList
            let items: [UIMenuElement] = list.prefix(20).map { item in
                let title = item.title.flatMap { $0.isEmpty ? nil : $0 } ?? MioMobileChromeCore.displayHost(item.url.absoluteString)
                return UIAction(title: title, subtitle: MioMobileChromeCore.displayHost(item.url.absoluteString)) { [weak wv] _ in _ = wv?.go(to: item) }
            }
            done(items)
        }])
    }

    /// 长按标签按钮
    private func tabsMenu() -> UIMenu {
        UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in
            guard let b = self?.browser, let tabs = b.tabsController else { done([]); return }
            // 新建标签页 / 新建无痕标签页 / 在容器中新建 ▸ / 新建容器…（MioContainerUX.swift）
            var items: [UIMenuElement] = MioContainerUX.newTabMenuElements(tabs, from: b)
            if tabs.store.hasClosed {
                items.append(UIAction(title: "重新打开关闭的标签页", image: UIImage(systemName: "arrow.uturn.backward")) { _ in tabs.reopenClosed() })
            }
            if let id = b.tabID {
                let c = tabs.containerMenuItems(for: id)
                if !c.isEmpty { items.append(UIMenu(options: .displayInline, children: c)) }
            }
            items.append(UIAction(title: "关闭此标签页", image: UIImage(systemName: "xmark"), attributes: .destructive) { [weak b] _ in
                guard let b = b else { return }
                b.tabsController?.closeTab(b)
            })
            items.append(UIAction(title: "回到 Mio 导航", image: UIImage(systemName: "house")) { _ in tabs.hideBrowser() })
            done(items)
        }])
    }

    /// 长按地址栏：复制链接 / 粘贴并前往 / 分享
    private func addressMenu() -> UIMenu? {
        guard let b = browser else { return nil }
        var items: [UIMenuElement] = []
        if let url = b.webView?.url, url.scheme == "http" || url.scheme == "https" {
            items.append(UIAction(title: "复制链接", image: UIImage(systemName: "doc.on.doc")) { _ in UIPasteboard.general.url = url })
        }
        if UIPasteboard.general.hasStrings || UIPasteboard.general.hasURLs {
            items.append(UIAction(title: "粘贴并前往", image: UIImage(systemName: "doc.on.clipboard")) { [weak b] _ in
                let text = UIPasteboard.general.url?.absoluteString ?? UIPasteboard.general.string ?? ""
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty, let u = MioBrowserViewController.url(fromInput: t) else { return }
                b?.load(u)
            })
        }
        if b.webView?.url != nil {
            items.append(UIAction(title: "分享", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
                guard let self = self else { return }
                self.share(from: self.address)
            })
        }
        return items.isEmpty ? nil : UIMenu(children: items)
    }

    private func share(from source: UIView) {
        guard let b = browser, let url = b.webView?.url else { return }
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let pop = vc.popoverPresentationController {
            pop.sourceView = source
            pop.sourceRect = source.bounds
        }
        b.present(vc, animated: true)
    }

    // MARK: page menu

    func presentPageMenu() {
        guard let b = browser, let wv = b.webView, b.presentedViewController == nil else { return }
        MioTranslate.pageState(wv) { [weak self] state in
            guard let self = self, let b = self.browser, b.presentedViewController == nil else { return }
            self.translateState = state
            let vc = MioPageMenuViewController(chrome: self)
            vc.modalPresentationStyle = .pageSheet
            if let sheet = vc.sheetPresentationController {
                sheet.detents = [.medium(), .large()]
                sheet.prefersGrabberVisible = true
                sheet.prefersScrollingExpandsWhenScrolledToEdge = true
            }
            b.present(vc, animated: true)
        }
    }

    struct MenuRow {
        let title: String
        var subtitle: String? = nil
        let icon: String
        var enabled = true
        /// 开关类条目的当前状态（nil = 普通条目）
        var state: Bool? = nil
        var disclosure = false
        var destructive = false
        /// true = 执行后菜单不关（开关类），false = 先关菜单再执行
        var keepsOpen = false
        let action: () -> Void
    }

    func menuSections() -> [(title: String, rows: [MenuRow])] {
        guard let b = browser, let wv = b.webView else { return [] }
        let url = wv.url
        let isWeb = url?.scheme == "http" || url?.scheme == "https"
        let host = isWeb ? url?.host : nil
        let mode = translateState?["mode"] as? String ?? "off"
        var findOK = false
        if #available(iOS 16.0, macCatalyst 16.0, *) { findOK = true }
        let ctx = MioMobileChromeCore.MenuContext(isWebPage: isWeb, host: host, translateAvailable: translateState != nil, translateMode: mode,
                                                  adblockEnabled: MioAdblockSettings.enabled, webrtcGuardEnabled: MioWebRTCSettings.enabled,
                                                  findSupported: findOK, desktopSupported: true,
                                                  containersSupported: MioContainerStore.isSupported && b.containerID != MioTabStore.privateContainer)
        var out: [(String, [MenuRow])] = []
        for section in MioMobileChromeCore.menuSections(ctx) {
            var rows = section.items.compactMap { row($0, host: host, mode: mode) }
            if section.items.contains(.userScripts), let bridge = MioUserScriptBridge.current, bridge.webView === wv {
                // 本页用户脚本注册的菜单命令（GM_registerMenuCommand）
                let cmds = bridge.menuItems.map { c in
                    MenuRow(title: c.name, subtitle: c.scriptName, icon: "gearshape.2") { [weak bridge] in bridge?.runMenuCommand(scriptID: c.scriptID, id: c.id) }
                }
                if let i = rows.firstIndex(where: { $0.title == MioMobileChromeCore.title(.userScripts) }) { rows.insert(contentsOf: cmds, at: i + 1) }
            }
            if !rows.isEmpty { out.append((section.title, rows)) }
        }
        return out.map { (title: $0.0, rows: $0.1) }
    }

    private func reloadPage() {
        guard let wv = browser?.webView, wv.url != nil else { return }
        wv.reload()
    }

    private func presentNav(_ root: UIViewController) {
        guard let b = browser else { return }
        let nav = UINavigationController(rootViewController: root)
        if root.navigationItem.leftBarButtonItem == nil, root.navigationItem.rightBarButtonItem == nil {
            root.navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak nav] _ in nav?.dismiss(animated: true) })
        } else if root.navigationItem.leftBarButtonItem == nil {
            root.navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak nav] _ in nav?.dismiss(animated: true) })
        }
        b.present(nav, animated: true)
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func row(_ item: MioMobileChromeCore.MenuItem, host: String?, mode: String) -> MenuRow? {
        guard let b = browser, let wv = b.webView else { return nil }
        let title = MioMobileChromeCore.title(item, desktop: desktopMode, systemBrowser: "Safari",
                                              targetLanguage: MioTranslateCore.languageName(MioTranslateSettings.target))
        switch item {
        case .forward:
            return MenuRow(title: title, icon: "chevron.forward", enabled: wv.canGoForward) { [weak wv] in wv?.goForward() }
        case .share:
            return MenuRow(title: title, icon: "square.and.arrow.up") { [weak self] in
                guard let self = self else { return }
                self.share(from: self.menuButton)
            }
        case .findInPage:
            return MenuRow(title: title, icon: "doc.text.magnifyingglass") { [weak wv] in
                if #available(iOS 16.0, macCatalyst 16.0, *) {
                    wv?.isFindInteractionEnabled = true
                    wv?.findInteraction?.presentFindNavigator(showingReplace: false)
                }
            }
        case .requestDesktop:
            return MenuRow(title: title, icon: desktopMode ? "iphone" : "desktopcomputer") { [weak self] in
                guard let self = self, let wv = self.browser?.webView else { return }
                self.desktopMode.toggle()
                wv.customUserAgent = self.desktopMode ? MioWebKitCompat.desktopUserAgent : nil
                if wv.url != nil { wv.reload() }
            }
        case .openExternal:
            return MenuRow(title: title, icon: "safari") { [weak b] in b?.openInSafari() }
        case .translateBilingual:
            return MenuRow(title: title, icon: "character.bubble", state: mode == "bilingual", keepsOpen: false) { [weak wv] in
                if let wv = wv { MioTranslate.setMode(wv, "bilingual") }
            }
        case .translateOnly:
            return MenuRow(title: title, icon: "character.book.closed", state: mode == "translation") { [weak wv] in
                if let wv = wv { MioTranslate.setMode(wv, "translation") }
            }
        case .translateOff:
            return MenuRow(title: title, icon: "arrow.uturn.backward") { [weak wv] in
                if let wv = wv { MioTranslate.setMode(wv, "off") }
            }
        case .translateAuto:
            guard let h = host else { return nil }
            let on = MioTranslateSettings.isAuto(h)
            return MenuRow(title: title, subtitle: MioTranslateCore.normalizeHost(h), icon: "globe", state: on, keepsOpen: true) { [weak self, weak wv] in
                MioTranslateSettings.setAuto(h, !on)
                if !on, mode == "off", let wv = wv {
                    MioTranslate.setMode(wv, MioTranslateSettings.display)
                    self?.translateState?["mode"] = MioTranslateSettings.display
                }
            }
        case .translateTarget:
            return MenuRow(title: title, icon: "textformat", disclosure: true) { [weak self, weak b, weak wv] in
                guard let b = b else { return }
                MioTranslate.presentLanguagePicker(from: b, sourceItem: nil, sourceView: self?.menuButton) { wv?.reload() }
            }
        case .translateSettings:
            return MenuRow(title: title, icon: "slider.horizontal.3", disclosure: true) { [weak b] in
                guard let b = b else { return }
                MioTranslate.presentSettings(from: b, host: host)
            }
        case .reader:
            return MenuRow(title: title, subtitle: (b.pageTools?.readerable ?? false) ? "检测到文章" : nil, icon: "doc.plaintext") { [weak b] in
                b?.pageTools?.openReader(force: true)
            }
        case .darkSite:
            guard let tools = b.pageTools else { return nil }
            return MenuRow(title: title, subtitle: host.map { MioForceDarkPolicy.normalize($0) }, icon: "moon", state: tools.isSiteDark, keepsOpen: true) { [weak tools] in
                tools?.toggleSiteDark()
            }
        case .darkAll:
            guard let tools = b.pageTools else { return nil }
            return MenuRow(title: title, icon: "moon.stars", state: tools.isGlobalDark, keepsOpen: true) { [weak tools] in tools?.toggleGlobalDark() }
        case .pageToolsSettings:
            return MenuRow(title: title, icon: "slider.horizontal.3", disclosure: true) { [weak b] in b?.pageTools?.openSettings() }
        case .saveBookmark, .saveNote, .saveClip:
            let kind: MioSaveKind = item == .saveBookmark ? .bookmark : (item == .saveNote ? .note : .clip)
            return MenuRow(title: kind.title, subtitle: kind.subtitle, icon: kind.systemImage) { [weak b] in b?.pageTools?.save(kind) }
        case .adblock:
            let on = MioAdblockSettings.enabled
            return MenuRow(title: title, subtitle: on ? "正在拦截广告和跟踪器" : "已关闭", icon: on ? "shield.lefthalf.filled" : "shield.slash", state: on, keepsOpen: true) { [weak self] in
                MioAdblockSettings.enabled = !on
                self?.reloadPage()
            }
        case .adblockSite:
            guard let h = host else { return nil }
            let blocking = !MioAdblockSettings.isAllowlisted(h)
            return MenuRow(title: title, subtitle: blocking ? MioAdblockSettings.normalize(h) : "已放行（白名单）：\(MioAdblockSettings.normalize(h))", icon: "checkmark.shield", state: blocking, keepsOpen: true) { [weak self] in
                MioAdblockSettings.setAllowlisted(h, blocking)
                self?.reloadPage()
            }
        case .webrtcSite:
            guard let h = host else { return nil }
            let allowed = MioWebRTCSettings.isAllowed(h)
            return MenuRow(title: title, subtitle: allowed ? "已放行" : "已屏蔽（防 IP 泄露）", icon: "video", state: allowed, keepsOpen: true) { [weak self] in
                MioWebRTCSettings.setAllowed(h, !allowed)
                self?.reloadPage()
            }
        case .userScripts:
            let all = MioUserScriptManager.shared.scripts
            return MenuRow(title: title, subtitle: all.isEmpty ? "未安装" : "已安装 \(all.count) 个，启用 \(all.filter { $0.enabled }.count) 个", icon: "curlybraces", disclosure: true) { [weak self] in
                self?.presentNav(MioUserScriptsViewController())
            }
        case .youtubeFocus:
            let on = MioBrowserSettings.youtubeFocus
            return MenuRow(title: title, subtitle: "隐藏 Shorts、看 Shorts 时定时提醒", icon: "hourglass", state: on, keepsOpen: true) { [weak wv] in
                MioBrowserSettings.youtubeFocus = !on
                if let u = wv?.url?.host, u.hasSuffix("youtube.com") { wv?.reload() }
            }
        case .adblockSettings, .settings:
            return MenuRow(title: title, icon: item == .settings ? "gearshape" : "shield", disclosure: true) { [weak self, weak b] in
                guard let b = b else { return }
                self?.presentNav(MioBrowserSettingsViewController(currentHost: b.webView?.url?.host, currentURL: b.webView?.url))
            }
        case .backToMio:
            return MenuRow(title: title, icon: "house") { [weak b] in b?.closeTapped() }
        case .openInContainer:
            return MenuRow(title: title, subtitle: MioContainerUX.badge(for: b.containerID).map { "当前：\($0.name)" } ?? "当前：默认", icon: "person.2.square.stack", disclosure: true) { [weak self, weak b] in
                guard let b = b else { return }
                MioContainerUX.openPageInContainer(b, sourceView: self?.menuButton)
            }
        case .siteContainer:
            let rule = host.flatMap { h in MioContainerStore.shared.state.siteRules.first { h == $0.host || h.hasSuffix("." + $0.host) } }
            let name = rule.flatMap { MioContainerStore.shared.container($0.containerId)?.name }
            return MenuRow(title: title, subtitle: name.map { "已设为：\($0)" } ?? "未设置", icon: "pin", disclosure: true) { [weak self, weak b] in
                guard let b = b else { return }
                MioContainerUX.setSiteContainer(b, sourceView: self?.menuButton)
            }
        }
    }

    // MARK: smoke（CI 模拟器截图用，MioMobileChromeSmoke）

    func smokeReport() -> [String: Any] {
        guard let b = browser, let view = b.view, let wv = b.webView else { return ["error": "no browser"] }
        let safeTop = view.safeAreaInsets.top
        let frames: [String: CGRect] = [
            "bottomChrome": bottomChrome.map { $0.convert($0.bounds, to: view) } ?? .null,
            "topChrome": topChrome?.frame ?? .null,
            "pill": pill.superview == nil ? .null : pill.frame,
            "webView": wv.frame,
        ]
        // 紧凑 / 底部：状态栏以下、顶部 120pt 里不能有任何可见的栏（「顶部露一截」的回归检查）
        var topIntruders: [String] = []
        if layout != .top {
            let band = CGRect(x: 0, y: safeTop + 1, width: view.bounds.width, height: 120)
            for v in view.subviews where v !== wv && !v.isHidden && v.alpha > 0.01 && v.frame.intersects(band) {
                topIntruders.append(String(describing: type(of: v)))
            }
        }
        return [
            "layout": layout.rawValue,
            "collapsed": collapsed,
            "safeTop": safeTop,
            "safeBottom": view.safeAreaInsets.bottom,
            "contentInsetTop": wv.scrollView.contentInset.top,
            "contentInsetBottom": wv.scrollView.contentInset.bottom,
            "webViewMinY": wv.frame.minY,
            "legacyTopBarHidden": b.topBar.isHidden,
            "legacyToolbarHidden": b.toolbar.isHidden,
            "legacyMiniBarHidden": b.miniBar.isHidden,
            "bottomChromeAlpha": bottomChrome?.alpha ?? -1,
            "pillAlpha": pill.superview == nil ? -1 : pill.alpha,
            "topIntruders": topIntruders,
            "frames": frames.mapValues { $0.isNull ? "null" : NSCoder.string(for: $0) },
            "host": address.hostLabel.text ?? "",
            "containerBadge": address.leading.arrangedSubviews.compactMap { ($0 as? UILabel)?.text }.joined(),
        ]
    }
}

// MARK: - Page menu（紧凑、可滚动的面板）

final class MioPageMenuViewController: UITableViewController {
    private weak var chrome: MioMobileChrome?
    private var sections: [(title: String, rows: [MioMobileChrome.MenuRow])] = []

    init(chrome: MioMobileChrome) {
        self.chrome = chrome
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 44
        tableView.sectionHeaderTopPadding = 4
        tableView.accessibilityIdentifier = "mio.pageMenu"
        reload()
    }

    func reload() {
        sections = chrome?.menuSections() ?? []
        tableView.reloadData()
    }

    var rowCount: Int { sections.reduce(0) { $0 + $1.rows.count } }
    var rowTitles: [String] { sections.flatMap { $0.rows.map(\.title) } }

    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].rows.count }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { sections[section].title }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let r = sections[indexPath.section].rows[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.text = r.title
        content.secondaryText = r.subtitle
        content.secondaryTextProperties.color = .secondaryLabel
        content.textProperties.font = .systemFont(ofSize: 16)
        content.secondaryTextProperties.font = .systemFont(ofSize: 12)
        content.image = UIImage(systemName: r.icon)
        content.imageProperties.tintColor = r.destructive ? .systemRed : .label
        content.textProperties.color = r.enabled ? (r.destructive ? .systemRed : .label) : .tertiaryLabel
        content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 9, leading: 0, bottom: 9, trailing: 0)
        cell.contentConfiguration = content
        if let on = r.state {
            let sw = UISwitch()
            sw.isOn = on
            sw.isUserInteractionEnabled = false
            cell.accessoryView = sw
        } else if r.disclosure {
            cell.accessoryType = .disclosureIndicator
        }
        cell.selectionStyle = r.enabled ? .default : .none
        cell.accessibilityTraits = .button
        if let on = r.state { cell.accessibilityValue = on ? "开" : "关" }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let r = sections[indexPath.section].rows[indexPath.row]
        guard r.enabled else { return }
        if r.keepsOpen {
            r.action()
            // 设置写入后刷新状态（开关类条目）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.reload() }
        } else {
            let action = r.action
            dismiss(animated: true) { action() }
        }
    }
}

// MARK: - Smoke（iOS 模拟器：启动参数 -mioLayoutSmoke YES [-mio.browser.layout compact|bottom|top]）
//
// 打开内置浏览器 → 每一步把状态写到 Documents/layout-smoke/step-<n>.json，等脚本截图后写 ack-<n>，再进行下一步；
// 最后写 result.json（ok + 各步检查）。scripts/sim-layout-smoke.sh 负责截图 / 应答。

enum MioMobileChromeSmoke {
    static var requested: Bool { UserDefaults.standard.bool(forKey: "mioLayoutSmoke") }
    private static var dir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("layout-smoke", isDirectory: true)
    }
    private static var results: [[String: Any]] = []
    private static var failures: [String] = []

    static func runIfRequested() {
        guard requested, !MioBrowserViewController.usesTopChrome else { return }
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = URL(string: UserDefaults.standard.string(forKey: "mioLayoutSmokeURL") ?? "https://en.wikipedia.org/wiki/Safari_(web_browser)")!
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            MioTabsViewController.open(url, from: nil)
            // 页面加载 + 拦截规则首次编译
            wait(seconds: 10) { step1() }
        }
    }

    private static var browser: MioBrowserViewController? { MioTabsViewController.shared?.activeController }

    private static func wait(seconds: Double, _ then: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: then)
    }

    private static func check(_ name: String, _ ok: Bool) {
        if !ok { failures.append(name) }
    }

    /// 写 step 文件，等 ack（最多 40 秒）
    private static func snap(_ n: Int, _ name: String, extra: [String: Any] = [:], then: @escaping () -> Void) {
        var r = browser?.mobileChrome?.smokeReport() ?? ["error": "no mobile chrome"]
        r["step"] = n
        r["name"] = name
        extra.forEach { r[$0.key] = $0.value }
        results.append(r)
        write(r, to: "step-\(n).json")
        NSLog("⚡️ MioLayoutSmoke step %d %@", n, name)
        let ack = dir.appendingPathComponent("ack-\(n)")
        let deadline = Date().addingTimeInterval(40)
        func poll() {
            if FileManager.default.fileExists(atPath: ack.path) || Date() > deadline { then(); return }
            wait(seconds: 0.3, poll)
        }
        poll()
    }

    private static func write(_ obj: [String: Any], to name: String) {
        guard JSONSerialization.isValidJSONObject(obj), let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else {
            try? Data("{\"error\":\"invalid json\"}".utf8).write(to: dir.appendingPathComponent(name))
            return
        }
        try? d.write(to: dir.appendingPathComponent(name), options: .atomic)
    }

    private static func step1() {
        guard let b = browser, let m = b.mobileChrome else {
            failures.append("no mobile chrome")
            finish()
            return
        }
        b.showChrome(animated: false)
        b.view.layoutIfNeeded()
        let r = m.smokeReport()
        check("legacy bars hidden", b.topBar.isHidden && b.toolbar.isHidden && b.miniBar.isHidden)
        check("webView full screen", abs(b.webView.frame.minY) < 0.5)
        if let bc = r["frames"] as? [String: String], let f = bc["bottomChrome"], f != "null" {
            let rect = NSCoder.cgRect(for: f)
            check("bottom chrome inside screen", rect.minX >= -0.5 && rect.maxX <= b.view.bounds.width + 0.5)
        }
        if m.layout != .top {
            check("no bar under status bar (expanded)", (r["topIntruders"] as? [String])?.isEmpty ?? false)
            check("content inset top == safe top", abs(b.webView.scrollView.contentInset.top - b.view.safeAreaInsets.top) < 0.5)
        }
        snap(1, "\(m.layout.rawValue)-expanded") { step2() }
    }

    private static func step2() {
        guard let b = browser, let m = b.mobileChrome else { finish(); return }
        b.setChromeHidden(true, animated: false)
        b.view.layoutIfNeeded()
        let r = m.smokeReport()
        check("collapsed", m.collapsed)
        if m.layout != .top {
            check("no bar under status bar (collapsed)", (r["topIntruders"] as? [String])?.isEmpty ?? false)
            check("pill visible", ((r["pillAlpha"] as? CGFloat) ?? 0) > 0.9)
            check("bar faded", ((r["bottomChromeAlpha"] as? CGFloat) ?? 1) < 0.1)
        }
        snap(2, "\(m.layout.rawValue)-collapsed") {
            b.showChrome(animated: false)
            if m.layout == .compact { step3() } else { finish() }
        }
    }

    private static func step3() {
        guard let b = browser, let m = b.mobileChrome else { finish(); return }
        m.presentPageMenu()
        wait(seconds: 2) {
            let menu = (b.presentedViewController ?? b.tabsController?.presentedViewController) as? MioPageMenuViewController
            let titles = menu?.rowTitles ?? []
            check("page menu shown", menu != nil)
            for must in ["前进", "回到 Mio 导航", "浏览器设置…", "广告拦截", "阅读模式", "用 Safari 打开"] { check("menu has \(must)", titles.contains(must)) }
            snap(3, "compact-page-menu", extra: ["menuRows": titles]) {
                menu?.dismiss(animated: false) { step4() }
                if menu == nil { step4() }
            }
        }
    }

    private static func step4() {
        guard let b = browser, let tabs = b.tabsController else { finish(); return }
        tabs.showOverview()
        wait(seconds: 2) {
            check("overview shown", tabs.presentedViewController is MioTabOverviewViewController)
            snap(4, "compact-tab-overview") {
                tabs.dismiss(animated: false) { step5() }
            }
        }
    }

    /// 容器易用性：新建容器 → 一次性引导 → 容器标签的地址栏色点 + 名称 → 概览容器切换器 → 无痕标签不落盘
    private static func step5() {
        guard MioContainerStore.isSupported, let tabs = MioTabsViewController.shared else { finish(); return }
        UserDefaults.standard.removeObject(forKey: "mio.containers.tipShown")
        guard let c = try? MioContainerStore.shared.create(name: "冒烟") else { check("create container", false); finish(); return }
        check("auto color is blue first", c.color == "blue")
        wait(seconds: 2) {
            let tip = MioBrowserViewController.topPresenter(nil) as? UIAlertController
            check("container tip shown once", tip?.title?.contains("容器") ?? false)
            snap(5, "container-tip") {
                let go = {
                    tabs.newTab(containerID: c.id)
                    wait(seconds: 4) {
                        let r = browser?.mobileChrome?.smokeReport() ?? [:]
                        check("address badge shows container", (r["containerBadge"] as? String)?.contains("冒烟") ?? false)
                        snap(6, "container-tab-badge") {
                            tabs.showOverview()
                            wait(seconds: 2) {
                                let ov = tabs.presentedViewController as? MioTabOverviewViewController
                                ov?.setFilterForSmoke(c.id)
                                check("overview filter shows only container tabs", ov?.visibleCountForSmoke == 1)
                                snap(7, "overview-container-filter") {
                                    tabs.dismiss(animated: false) {
                                        tabs.openPrivateTab()
                                        wait(seconds: 2) {
                                            let saved = String(decoding: tabs.store.serialize(), as: UTF8.self)
                                            check("private tab active", tabs.store.tabs.first { $0.id == tabs.store.activeID }?.containerID == MioTabStore.privateContainer)
                                            check("private tab not persisted", !saved.contains("\"private\""))
                                            snap(8, "private-tab") { finish() }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                if let tip = tip { tip.dismiss(animated: false) { go() } } else { go() }
            }
        }
    }

    private static func finish() {
        let ok = failures.isEmpty
        write(["ok": ok, "failures": failures, "steps": results.count, "layout": MioMobileLayoutSettings.layout.rawValue], to: "result.json")
        NSLog("⚡️ MioLayoutSmoke done ok=%@ failures=%@", ok ? "true" : "false", failures.joined(separator: ", "))
    }
}
