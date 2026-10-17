// MioDesktopParity.swift — v0.3.4 Mac 内置浏览器跟 Safari 对齐（只在 Mac 上生效；iPhone / iPad 行为不变）
//   · 页面缩放：⌘+ / ⌘- / ⌘0、Safari 档位、按站点记住、设置里的默认缩放、地址栏百分比小标签（点一下重置）
//   · Mac 版界面是 iPad idiom（整窗按 77% 缩放显示）：网页的「100%」按 Safari 换算（pageZoom = 档位 / 0.77），
//     顶部工具栏 / 地址栏 / 标签条按 Safari macOS 的屏幕尺寸换算成逻辑点
//   · YouTube：恢复 v0.3.0 的 UA（HLS 高清）；「在 Safari 中看高清」兜底按钮；「YouTube 始终用 Safari 打开」（默认关）
// 纯逻辑在 MioDesktopParityCore.swift。

import UIKit
import WebKit

extension Notification.Name {
    /// 某站点的缩放变了（同站点的其他标签跟着变，像 Safari）。object = 站点键 String
    static let mioZoomDidChange = Notification.Name("mio.zoom.didChange")
}

enum MioDesktopParitySettings {
    private static let d = UserDefaults.standard
    static let defaultZoomKey = "mio.zoom.default"
    static let sitesKey = "mio.zoom.sites"
    static let youtubeAlwaysSafariKey = "mio.desktop.youtubeAlwaysSafari"

    /// 设置里的「默认页面缩放」（档位值，1.0 = 实际大小）
    static var defaultZoom: Double {
        get { let v = d.double(forKey: defaultZoomKey); return v > 0 ? MioZoomCore.nearest(v) : 1.0 }
        set { d.set(MioZoomCore.nearest(newValue), forKey: defaultZoomKey); NotificationCenter.default.post(name: .mioZoomDidChange, object: nil) }
    }

    static var sites: MioZoomCore.SiteTable {
        get { MioZoomCore.SiteTable(json: d.string(forKey: sitesKey)) }
        set { d.set(newValue.json, forKey: sitesKey) }
    }

    static func zoom(for site: String?) -> Double { sites.zoom(for: site, default: defaultZoom) }

    static func setZoom(_ z: Double, for site: String?) {
        var t = sites
        t.set(z, for: site, default: defaultZoom)
        sites = t
        NotificationCenter.default.post(name: .mioZoomDidChange, object: site)
    }

    /// Mac：YouTube 视频页直接用 Safari 打开（默认关；HLS 高清通常已够用）
    static var youtubeAlwaysSafari: Bool {
        get { d.bool(forKey: youtubeAlwaysSafariKey) }
        set { d.set(newValue, forKey: youtubeAlwaysSafariKey) }
    }
}

/// Mac 上的尺寸换算：iPad idiom 的 Catalyst 窗口按 0.77 缩放显示，Safari 的屏幕尺寸要除以它才是逻辑点
enum MioMacMetrics {
    static var factor: CGFloat {
        guard MioWebKitCompat.isMac else { return 1 }
        if #available(iOS 14.0, macCatalyst 14.0, *), UIDevice.current.userInterfaceIdiom == .mac { return 1 }
        return 0.77
    }
    /// Safari macOS 的屏幕点 → 本 App 的逻辑点
    static func pt(_ screen: CGFloat) -> CGFloat { (screen / factor).rounded() }

    static var toolbarHeight: CGFloat { pt(52) }   // Safari 紧凑工具栏 ~52pt
    static var stripHeight: CGFloat { pt(28) }     // Safari 标签条 ~28pt
    static var addressHeight: CGFloat { pt(28) }   // 地址栏胶囊 ~28pt
    static var addressFont: CGFloat { pt(13) }     // 地址栏 13pt
    static var tabFont: CGFloat { pt(12) }
    static var symbolSize: CGFloat { pt(15) }      // 工具栏 SF Symbols，中等权重
    /// 网页 100% 对应的 pageZoom（看起来和 Safari 的 100% 一样大）
    static var pageZoomBase: CGFloat { 1 / factor }
}

enum MioDesktopParity {
    static var enabled: Bool { MioWebKitCompat.isMac }

    /// v0.3.0 的 YouTube UA（ProcessInfo 主版本号与当时一致）
    static let legacyYouTubeUA: String = MioYouTubeCompat.legacyMacUserAgent(osMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)

    /// Mac 上 YouTube 保留手机 / 平板版（不做 m.youtube.com → www 的桌面改写）
    static func keepsYouTubeLegacy(_ url: URL?) -> Bool { enabled && MioYouTubeCompat.isYouTubeHost(url?.host) }

    static func desiredUserAgent(for url: URL) -> String {
        keepsYouTubeLegacy(url) ? legacyYouTubeUA : MioWebKitCompat.desktopUserAgent
    }

    /// 冒烟：最近一次 YouTube 页的 UA / hlsManifestUrl
    static var lastYouTubeProbe: [String: Any]?

    static let youtubeProbeJS = #"""
    (() => { const r = { href: location.href, ua: navigator.userAgent };
      try { const p = document.getElementById('movie_player'); let pr = window.ytInitialPlayerResponse;
        if (p && typeof p.getPlayerResponse === 'function') pr = p.getPlayerResponse() || pr;
        r.playability = pr && pr.playabilityStatus && pr.playabilityStatus.status;
        const sd = pr && pr.streamingData; r.streamingData = !!sd; r.hlsManifestUrl = !!(sd && sd.hlsManifestUrl);
        r.adaptiveFormats = sd && sd.adaptiveFormats ? sd.adaptiveFormats.length : 0;
        const v = document.querySelector('video'); if (v) { r.videoSrcScheme = String(v.currentSrc || v.src || '').slice(0, 5); r.videoHeight = v.videoHeight; }
      } catch (e) { r.error = String(e); }
      return JSON.stringify(r); })()
    """#
}

// MARK: - 浏览器挂钩

extension MioBrowserViewController {
    /// decidePolicyFor（主框架 http/https）里调用：返回 true 表示已处理（调用方 cancel）
    func parityDecide(_ action: WKNavigationAction, url: URL, isMain: Bool, preferences: WKWebpagePreferences) -> Bool {
        guard MioDesktopParity.enabled, isMain, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        let isYT = MioYouTubeCompat.isYouTubeHost(url.host)
        if isYT {
            // v0.3.0：不强制桌面内容模式
            preferences.preferredContentMode = .recommended
            if MioDesktopParitySettings.youtubeAlwaysSafari, MioYouTubeCompat.isVideoPage(url),
               let hd = MioYouTubeCompat.safariHDURL(url, seconds: nil) {
                UIApplication.shared.open(hd)
                return true
            }
        }
        let ua = MioDesktopParity.desiredUserAgent(for: url)
        if webView.customUserAgent != ua {
            webView.customUserAgent = ua
            // 请求头里的 UA 在发起时已定：换 UA 的 GET 导航取消后用新 UA 重新加载（前进后退 / POST 只换 UA 不重载）
            if action.navigationType != .backForward, (action.request.httpMethod ?? "GET").uppercased() == "GET" {
                let req = action.request
                DispatchQueue.main.async { [weak self] in _ = self?.webView.load(req) }
                return true
            }
        }
        applyPageZoom(for: url)
        return false
    }

    var paritySiteKey: String? { MioZoomCore.siteKey(url: webView?.url) }

    /// 当前页的缩放档位（1.0 = 实际大小）
    var zoomLevel: Double { MioDesktopParitySettings.zoom(for: paritySiteKey) }

    func applyPageZoom(for url: URL? = nil) {
        guard MioDesktopParity.enabled, let wv = webView else { return }
        let level = MioDesktopParitySettings.zoom(for: MioZoomCore.siteKey(url: url ?? wv.url))
        let z = CGFloat(level) * MioMacMetrics.pageZoomBase
        if #available(iOS 14.0, macCatalyst 14.0, *), abs(wv.pageZoom - z) > 0.001 { wv.pageZoom = z }
        updateZoomBadge(level)
    }

    @objc func mioZoomIn(_ sender: Any?) { setZoomLevel(MioZoomCore.zoomIn(from: zoomLevel)) }
    @objc func mioZoomOut(_ sender: Any?) { setZoomLevel(MioZoomCore.zoomOut(from: zoomLevel)) }
    @objc func mioZoomReset(_ sender: Any?) { setZoomLevel(MioDesktopParitySettings.defaultZoom) }

    func setZoomLevel(_ z: Double) {
        guard MioDesktopParity.enabled else { return }
        MioDesktopParitySettings.setZoom(z, for: paritySiteKey)
        applyPageZoom()
    }

    // MARK: 地址栏小标签

    private static var badgeTag: Int { 0x5A00 }

    func updateZoomBadge(_ level: Double) {
        guard MioDesktopParity.enabled else { return }
        let show = !MioZoomCore.isDefault(level, default: 1.0)
        let pad: CGFloat = 10
        if show {
            let b: UIButton
            if let existing = addressField.leftView?.viewWithTag(Self.badgeTag) as? UIButton {
                b = existing
            } else {
                b = UIButton(type: .system)
                b.tag = Self.badgeTag
                b.titleLabel?.font = .systemFont(ofSize: MioMacMetrics.pt(11), weight: .medium)
                b.backgroundColor = .tertiarySystemFill
                b.layer.cornerRadius = 5
                b.accessibilityHint = "点按恢复实际大小"
                b.addAction(UIAction { [weak self] _ in self?.mioZoomReset(nil) }, for: .touchUpInside)
            }
            b.setTitle(MioZoomCore.label(level), for: .normal)
            b.accessibilityLabel = "页面缩放 " + MioZoomCore.label(level)
            b.sizeToFit()
            let w = b.bounds.width + 10, h = MioMacMetrics.pt(18)
            let box = UIView(frame: CGRect(x: 0, y: 0, width: w + pad, height: h))
            b.frame = CGRect(x: pad / 2, y: 0, width: w, height: h)
            box.addSubview(b)
            addressField.leftView = box
        } else if addressField.leftView?.viewWithTag(Self.badgeTag) != nil {
            addressField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: pad, height: pad))
        }
    }

    // MARK: 在 Safari 中看高清

    @objc func mioYouTubeInSafari(_ sender: Any?) {
        let url = webView.url
        webView.evaluateJavaScript("(function(){var v=document.querySelector('video');return v?v.currentTime:0})()") { result, _ in
            let t = (result as? NSNumber)?.doubleValue
            if let hd = MioYouTubeCompat.safariHDURL(url, seconds: t) ?? url { UIApplication.shared.open(hd) }
        }
    }

    func parityDidFinish() {
        guard MioDesktopParity.enabled else { return }
        applyPageZoom()
        tabChrome?.parityRefresh()
        guard MioYouTubeCompat.isYouTubeHost(webView.url?.host) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.webView?.evaluateJavaScript(MioDesktopParity.youtubeProbeJS) { result, _ in
                if let s = result as? String, let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] {
                    MioDesktopParity.lastYouTubeProbe = obj
                    NSLog("⚡️ Mio YouTube UA/HLS probe: %@", s)
                }
            }
        }
    }
}

// MARK: - 顶部工具栏（Mac）：Safari 尺寸 + 「在 Safari 中看高清」按钮

private var hdItemKey: UInt8 = 0
private var zoomObserverKey: UInt8 = 0
private var urlObserverKey: UInt8 = 0

extension MioTabChrome {
    /// installTop 里、设 toolbar.items 之前调用：Mac 上返回额外按钮（YouTube 高清兜底）
    func parityExtraItems() -> [UIBarButtonItem] {
        guard MioDesktopParity.enabled, let b = browser else { return [] }
        let item = UIBarButtonItem(image: UIImage(systemName: "play.tv"), style: .plain, target: b, action: #selector(MioBrowserViewController.mioYouTubeInSafari(_:)))
        item.title = "在 Safari 中看高清"
        item.accessibilityLabel = "在 Safari 中看高清"
        objc_setAssociatedObject(self, &hdItemKey, item, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        // YouTube 是单页应用：首页 → 视频页不触发 didFinish，跟着 URL 变化刷新按钮
        let obs = b.webView?.observe(\.url, options: [.new]) { [weak self] _, _ in DispatchQueue.main.async { self?.parityRefresh() } }
        objc_setAssociatedObject(self, &urlObserverKey, obs, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        parityRefresh()
        return [item]
    }

    /// YouTube 视频页才显示高清按钮
    func parityRefresh() {
        guard let item = objc_getAssociatedObject(self, &hdItemKey) as? UIBarButtonItem else { return }
        let on = MioYouTubeCompat.isVideoPage(browser?.webView?.url)
        if #available(iOS 16.0, macCatalyst 16.0, *) { item.isHidden = !on } else { item.isEnabled = on }
    }

    /// installTop 末尾调用：工具栏 / 地址栏 / 标签条换成 Safari macOS 的尺寸
    func parityStyleTop(toolbar: UIToolbar, addressSlot: UIView?) {
        guard MioDesktopParity.enabled, let b = browser else { return }
        toolbar.heightAnchor.constraint(equalToConstant: MioMacMetrics.toolbarHeight).isActive = true
        b.addressField.font = .systemFont(ofSize: MioMacMetrics.addressFont)
        b.addressField.layer.cornerRadius = MioMacMetrics.pt(7)
        if let slot = addressSlot {
            for c in slot.constraints where c.firstAttribute == .height && c.firstItem === slot { c.constant = MioMacMetrics.addressHeight }
            for c in b.addressField.constraints where c.firstAttribute == .height && c.firstItem === b.addressField { c.constant = MioMacMetrics.addressHeight }
        }
        let cfg = UIImage.SymbolConfiguration(pointSize: MioMacMetrics.symbolSize, weight: .medium)
        for item in toolbar.items ?? [] where item.customView == nil {
            if let img = item.image { item.image = img.applyingSymbolConfiguration(cfg) ?? img }
        }
        b.shieldButton.setPreferredSymbolConfiguration(cfg, forImageIn: .normal)
        // 同站点其他标签改了缩放：本标签跟着变
        let obs = NotificationCenter.default.addObserver(forName: .mioZoomDidChange, object: nil, queue: .main) { [weak b] n in
            guard let b = b else { return }
            if n.object == nil || (n.object as? String) == b.paritySiteKey { b.applyPageZoom() }
        }
        objc_setAssociatedObject(self, &zoomObserverKey, MioObserverToken(obs), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}

/// 释放时移除通知观察者
final class MioObserverToken {
    let token: NSObjectProtocol
    init(_ t: NSObjectProtocol) { token = t }
    deinit { NotificationCenter.default.removeObserver(token) }
}

// MARK: - 设置页（「Mac 显示与缩放」）

final class MioDesktopParitySettingsViewController: UITableViewController {
    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "页面缩放与 YouTube"
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { section == 0 ? 2 : 1 }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { section == 0 ? "页面缩放" : "YouTube" }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 0
            ? "与 Safari 相同：⌘+ 放大、⌘- 缩小、⌘0 实际大小（菜单栏「显示」），每个网站单独记住；地址栏里的百分比点一下恢复。触控板双指捏合可临时放大。"
            : "YouTube 在 Mac 上用与 v0.3.0 相同的 UA，播放高清 HLS 流。仍是低清时点工具栏的「在 Safari 中看高清」（从当前进度继续）。"
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        switch (indexPath.section, indexPath.row) {
        case (0, 0):
            cell.textLabel?.text = "默认页面缩放"
            cell.detailTextLabel?.text = MioZoomCore.label(MioDesktopParitySettings.defaultZoom)
            cell.accessoryType = .disclosureIndicator
        case (0, 1):
            let n = MioDesktopParitySettings.sites.count
            cell.textLabel?.text = "清除各网站的缩放（\(n)）"
            cell.textLabel?.textColor = n > 0 ? .systemRed : .secondaryLabel
        default:
            cell.textLabel?.text = "YouTube 始终用 Safari 打开"
            let sw = UISwitch()
            sw.isOn = MioDesktopParitySettings.youtubeAlwaysSafari
            sw.addAction(UIAction { [weak sw] _ in MioDesktopParitySettings.youtubeAlwaysSafari = sw?.isOn ?? false }, for: .valueChanged)
            cell.accessoryView = sw
            cell.selectionStyle = .none
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch (indexPath.section, indexPath.row) {
        case (0, 0):
            let a = MioActionList(title: "默认页面缩放", message: nil)
            for z in MioZoomCore.levels {
                let cur = MioZoomCore.isDefault(z, default: MioDesktopParitySettings.defaultZoom)
                a.add(MioZoomCore.label(z), checked: cur) { [weak self] in
                    MioDesktopParitySettings.defaultZoom = z
                    self?.tableView.reloadData()
                }
            }
            _ = a.present(from: self, sourceView: tableView.cellForRow(at: indexPath))
        case (0, 1):
            MioDesktopParitySettings.sites = MioZoomCore.SiteTable()
            NotificationCenter.default.post(name: .mioZoomDidChange, object: nil)
            tableView.reloadData()
        default: break
        }
    }
}

// MARK: - 冒烟（Mac）：⌘+ 后 pageZoom 变化、重载后保持；YouTube UA / HLS 记录

enum MioDesktopParitySmoke {
    static let pageURL = URL(string: "https://example.com/")!

    static func run(completion: @escaping ([String: Any], Bool) -> Void) {
        var r: [String: Any] = ["metricsFactor": MioMacMetrics.factor, "idiom": UIDevice.current.userInterfaceIdiom.rawValue,
                                "legacyYouTubeUA": MioDesktopParity.legacyYouTubeUA, "desktopUA": MioWebKitCompat.desktopUserAgent]
        // YouTube 页：UA 与 hlsManifestUrl（LOGIN_REQUIRED / 机房 IP 被拦时只记录，不作门槛）
        r["youtubeProbe"] = MioDesktopParity.lastYouTubeProbe ?? "none"
        r["youtubeUAIsLegacy"] = (MioDesktopParity.lastYouTubeProbe?["ua"] as? String) == MioDesktopParity.legacyYouTubeUA
        guard #available(iOS 14.0, macCatalyst 14.0, *), MioBrowserViewController.smokeLoad(pageURL) else { completion(r, false); return }
        // 非 YouTube 站点：仍是桌面 Safari UA（v0.3.1 #5 的行为），再测缩放
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            guard let b = MioBrowserViewController.current, let wv = b.webView else { completion(r, false); return }
            wv.evaluateJavaScript("navigator.userAgent") { ua, _ in
                let uaOK = (ua as? String) == MioWebKitCompat.desktopUserAgent
                r["exampleUA"] = ua ?? "nil"
                r["exampleUAIsDesktop"] = uaOK
                let site = b.paritySiteKey
                r["site"] = site ?? "nil"
                let before = wv.pageZoom
                b.mioZoomIn(nil)
                let after = wv.pageZoom
                r["pageZoomBefore"] = before
                r["pageZoomAfterZoomIn"] = after
                r["storedLevel"] = MioDesktopParitySettings.zoom(for: site)
                r["badge"] = (b.addressField.leftView?.viewWithTag(0x5A00) as? UIButton)?.title(for: .normal) ?? "none"
                let changed = site == "example.com" && after > before + 0.01 && abs(MioDesktopParitySettings.zoom(for: site) - 1.15) < 0.001
                wv.reload()
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    let kept = abs(wv.pageZoom - after) < 0.001
                    r["pageZoomAfterReload"] = wv.pageZoom
                    b.mioZoomReset(nil)
                    r["pageZoomAfterReset"] = wv.pageZoom
                    let reset = abs(wv.pageZoom - MioMacMetrics.pageZoomBase) < 0.001 && MioDesktopParitySettings.sites.count == 0
                    r["zoomChanged"] = changed; r["zoomKeptAfterReload"] = kept; r["zoomReset"] = reset
                    completion(r, uaOK && changed && kept && reset)
                }
            }
        }
    }
}
