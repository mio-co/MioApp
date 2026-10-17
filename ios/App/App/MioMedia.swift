// MioMedia.swift — 内置浏览器媒体功能的原生部分（v0.3.3）：
// - 设置（mio.media.*）：画中画按钮、锁屏 Now Playing、SponsorBlock 总开关 + 分类；「后台播放」沿用 v0.3.2 的 mio.browser.backgroundPlayback
// - 用户脚本：可见性伪造（后台播放开时，所有站点）+ YouTube 媒体脚本（MioMediaScripts.youtubeMediaScriptTemplate）
// - MioMediaController（每个内置浏览器一个）：
//   · 切到后台时通知页面续播（WebKit 会把有画面的 <video> 停掉）；耳机拔出 / 来电打断记为「用户暂停」，不续播
//   · 页面没有 navigator.mediaSession 时，用 MPNowPlayingInfoCenter + MPRemoteCommandCenter 兜底（映射到页面 play/pause/next）
//   · SponsorBlock 请求兜底：页面 fetch 失败时代取（只允许 https://sponsor.ajay.app/api/skipSegments/<哈希前缀>）
// - 冒烟（Mac CI）：媒体脚本是否注入、EME（Widevine / FairPlay）在 YouTube 和 open.spotify.com 上是否可用（只记录）
// 纯逻辑与 JS 在 MioMediaScripts.swift。

import UIKit
import WebKit
import AVFoundation
import MediaPlayer

// MARK: - Settings

enum MioMediaSettings {
    private static let pipKey = "mio.media.pipButton"
    private static let nowPlayingKey = "mio.media.nowPlaying"
    private static let sponsorBlockKey = "mio.media.sponsorBlock"
    private static func categoryKey(_ c: String) -> String { "mio.media.sb.\(c)" }

    private static func bool(_ key: String, _ def: Bool) -> Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? def }
    private static func set(_ key: String, _ v: Bool) {
        UserDefaults.standard.set(v, forKey: key)
        // 内置浏览器监听这个通知重建用户脚本（对之后加载的页面生效）
        NotificationCenter.default.post(name: .mioBrowserSettingsDidChange, object: nil)
    }

    /// 播放器上的画中画按钮，默认开
    static var pipButton: Bool {
        get { bool(pipKey, true) }
        set { set(pipKey, newValue) }
    }

    /// 锁屏 / 控制中心显示正在播放并可控制，默认开
    static var nowPlaying: Bool {
        get { bool(nowPlayingKey, true) }
        set { set(nowPlayingKey, newValue) }
    }

    /// SponsorBlock 总开关，默认开
    static var sponsorBlock: Bool {
        get { bool(sponsorBlockKey, true) }
        set { set(sponsorBlockKey, newValue) }
    }

    static func categoryEnabled(_ key: String) -> Bool {
        let def = MioMediaScripts.categories.first(where: { $0.key == key })?.defaultOn ?? false
        return bool(categoryKey(key), def)
    }

    static func setCategory(_ key: String, _ on: Bool) { set(categoryKey(key), on) }

    static var enabledCategories: [String] { MioMediaScripts.categories.map { $0.key }.filter(categoryEnabled) }

    static var config: MioMediaScripts.Config {
        MioMediaScripts.Config(platform: MioWebKitCompat.isMac ? "mac" : "ios",
                               background: MioBrowserSettings.backgroundPlayback,
                               nowPlaying: nowPlaying, pip: pipButton,
                               sponsorBlock: sponsorBlock, categories: enabledCategories)
    }

    /// 内置浏览器的媒体用户脚本（排在 YouTube 防沉迷脚本之后）
    static func userScripts() -> [WKUserScript] {
        var out: [WKUserScript] = []
        if MioBrowserSettings.backgroundPlayback {
            // 后台播放：页面始终认为自己可见（YouTube 在 visibilitychange 时会暂停）——所有站点
            out.append(WKUserScript(source: MioMediaScripts.visibilityScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        // 所有页面都注入，脚本自己只在 *.youtube.com 主框架生效（WKUserScript 不能按域名过滤）
        out.append(WKUserScript(source: MioMediaScripts.youtubeMediaScript(config), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        return out
    }
}

// MARK: - Controller

/// WKUserContentController 会强引用 handler：弱引用转发（带回复）
final class MioMediaWeakReplyHandler: NSObject, WKScriptMessageHandlerWithReply {
    weak var target: WKScriptMessageHandlerWithReply?
    init(_ target: WKScriptMessageHandlerWithReply) { self.target = target }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        guard let t = target else { replyHandler(nil, "gone"); return }
        t.userContentController(c, didReceive: message, replyHandler: replyHandler)
    }
}

final class MioMediaController: NSObject, WKScriptMessageHandlerWithReply {
    static let messageName = "mioMedia"

    private weak var webView: WKWebView?
    private let controller: WKUserContentController
    private var observers: [NSObjectProtocol] = []
    private var remoteTargets: [(MPRemoteCommand, Any)] = []
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    private var ownsNowPlaying = false
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 10
        c.httpAdditionalHeaders = ["Accept": "application/json"]
        return URLSession(configuration: c)
    }()

    init(webView: WKWebView) {
        self.webView = webView
        controller = webView.configuration.userContentController
        super.init()
        controller.addScriptMessageHandler(MioMediaWeakReplyHandler(self), contentWorld: .page, name: Self.messageName)
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.enteredBackground()
        })
        observers.append(nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.endBackgroundTask()
            self?.page("window.__mioMedia&&window.__mioMedia.appState('foreground')")
        })
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] n in
            // 耳机 / 蓝牙断开：系统会暂停，这是用户意图，不续播
            let raw = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            if raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:)) == .oldDeviceUnavailable {
                self?.page("window.__mioMedia&&window.__mioMedia.userIntent('route')")
            }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            // 来电 / 闹钟 / 其他 App 抢占音频：不续播
            let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            if raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began {
                self?.page("window.__mioMedia&&window.__mioMedia.userIntent('interruption')")
            }
        })
    }

    deinit { detach() }

    func detach() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        controller.removeScriptMessageHandler(forName: Self.messageName, contentWorld: .page)
        removeRemoteCommands()
        if ownsNowPlaying { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; ownsNowPlaying = false }
        endBackgroundTask()
    }

    private func page(_ js: String) {
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: 后台续播

    private func enteredBackground() {
        guard MioBrowserSettings.backgroundPlayback, webView?.window != nil else { return }
        // 争取几秒执行时间：WebKit 停掉视频后由页面脚本 / 这里再 play() 一次（之后有声音在播，App 就不会被挂起）
        endBackgroundTask()
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "mio.media.resume") { [weak self] in self?.endBackgroundTask() }
        let js = "window.__mioMedia&&window.__mioMedia.appState('background')"
        page(js)
        for delay in [0.5, 1.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.page(js) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.endBackgroundTask() }
    }

    private func endBackgroundTask() {
        guard bgTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTask)
        bgTask = .invalid
    }

    // MARK: 页面消息

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any], let type = body["type"] as? String else {
            replyHandler(nil, "bad message"); return
        }
        switch type {
        case "sbFetch":
            sponsorBlockFetch(body["url"] as? String ?? "", reply: replyHandler)
        case "state":
            updateNowPlaying(body)
            replyHandler(nil, nil)
        default:
            replyHandler(nil, "unknown type")
        }
    }

    private func sponsorBlockFetch(_ s: String, reply: @escaping (Any?, String?) -> Void) {
        guard MioMediaSettings.sponsorBlock, MioMediaScripts.isAllowedSponsorBlockURL(s), let url = URL(string: s) else {
            reply(nil, "not allowed"); return
        }
        Self.session.dataTask(with: url) { data, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let result: (String?, String?)
            if code == 404 {
                result = ("[]", nil)
            } else if code == 200, let d = data, d.count < 2_000_000, let text = String(data: d, encoding: .utf8) {
                result = (text, nil)
            } else {
                result = (nil, err.map { "\($0.localizedDescription)" } ?? "HTTP \(code)")
            }
            DispatchQueue.main.async { reply(result.0, result.1) }
        }.resume()
    }

    // MARK: Now Playing 兜底（页面没有 MediaSession 时）

    private func updateNowPlaying(_ s: [String: Any]) {
        guard MioMediaSettings.nowPlaying else { return }
        // 有 navigator.mediaSession 时 WebKit 自己管锁屏信息和控制（页面脚本已设好元数据和处理器），这里不插手
        if (s["hasMediaSession"] as? Bool) == true { return }
        registerRemoteCommands()
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: (s["title"] as? String) ?? "",
            MPMediaItemPropertyArtist: (s["artist"] as? String) ?? "",
            MPMediaItemPropertyAlbumTitle: "YouTube",
            MPNowPlayingInfoPropertyPlaybackRate: ((s["playing"] as? Bool) == true) ? ((s["rate"] as? Double) ?? 1) : 0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: (s["position"] as? Double) ?? 0,
        ]
        if let d = s["duration"] as? Double, d > 0 { info[MPMediaItemPropertyPlaybackDuration] = d }
        if let keep = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork],
           (MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String) == (s["title"] as? String) {
            info[MPMediaItemPropertyArtwork] = keep
        } else if let a = s["artwork"] as? String, let url = URL(string: a), url.host == "i.ytimg.com" {
            let title = s["title"] as? String
            Self.session.dataTask(with: url) { data, _, _ in
                guard let d = data, let img = UIImage(data: d) else { return }
                DispatchQueue.main.async {
                    let center = MPNowPlayingInfoCenter.default()
                    guard var cur = center.nowPlayingInfo, (cur[MPMediaItemPropertyTitle] as? String) == title else { return }
                    cur[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
                    center.nowPlayingInfo = cur
                }
            }.resume()
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        ownsNowPlaying = true
    }

    private func registerRemoteCommands() {
        guard remoteTargets.isEmpty else { return }
        let c = MPRemoteCommandCenter.shared()
        func add(_ cmd: MPRemoteCommand, _ name: String) {
            cmd.isEnabled = true
            let t = cmd.addTarget { [weak self] _ in
                guard let self = self, self.webView != nil else { return .noActionableNowPlayingItem }
                self.page("window.__mioMedia&&window.__mioMedia.command('\(name)')")
                return .success
            }
            remoteTargets.append((cmd, t))
        }
        add(c.playCommand, "play")
        add(c.pauseCommand, "pause")
        add(c.togglePlayPauseCommand, "toggle")
        add(c.nextTrackCommand, "next")
        add(c.previousTrackCommand, "previous")
        c.changePlaybackPositionCommand.isEnabled = true
        let seek = c.changePlaybackPositionCommand.addTarget { [weak self] e in
            guard let self = self, let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self.page("window.__mioMedia&&window.__mioMedia.command('seek',\(e.positionTime))")
            return .success
        }
        remoteTargets.append((c.changePlaybackPositionCommand, seek))
    }

    private func removeRemoteCommands() {
        for (cmd, t) in remoteTargets { cmd.removeTarget(t) }
        remoteTargets.removeAll()
    }
}

// MARK: - Settings UI（浏览器设置 › 媒体与 SponsorBlock）

final class MioMediaSettingsViewController: UITableViewController {
    private enum Row { case background, nowPlaying, pip, sponsorBlock, category(MioMediaScripts.Category), drmInfo }
    private var sections: [(title: String?, footer: String?, rows: [Row])] = []

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "媒体与 SponsorBlock"
        rebuild()
    }

    static let sponsorBlockFooter = "自动跳过 YouTube 视频里社区标注的片段，跳过时底部提示，可点「撤销」回看（本次不再自动跳）；手动拖回片段里也不会再跳。进度条上用颜色标出片段。隐私：只发送视频 ID 的 SHA-256 前 4 位，在本机匹配。片段数据来自 SponsorBlock（sponsor.ajay.app），按 CC BY-NC-SA 4.0 授权使用。"

    private func rebuild() {
        var s: [(String?, String?, [Row])] = []
        s.append(("后台播放与画中画",
                  "后台播放：切到后台 / 锁屏后继续播放（页面始终认为自己可见；系统把视频停掉时自动续播，耳机拔出或来电时不续播）。\n锁屏控制：锁屏和控制中心显示正在播放的视频，可播放 / 暂停 / 下一个。\n画中画：YouTube 播放器左上角的按钮（点一下视频显示 3 秒）。对之后打开的页面生效。",
                  [.background, .nowPlaying, .pip]))
        var sb: [Row] = [.sponsorBlock]
        if MioMediaSettings.sponsorBlock { sb += MioMediaScripts.categories.map { .category($0) } }
        s.append(("SponsorBlock", Self.sponsorBlockFooter, sb))
        s.append(("DRM 视频 / 音乐", nil, [.drmInfo]))
        sections = s.map { (title: $0.0, footer: $0.1, rows: $0.2) }
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].rows.count }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { sections[section].title }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? { sections[section].footer }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.selectionStyle = .none
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.detailTextLabel?.numberOfLines = 0
        switch sections[indexPath.section].rows[indexPath.row] {
        case .background:
            cell.textLabel?.text = "后台 / 锁屏继续播放"
            cell.accessoryView = makeSwitch(MioBrowserSettings.backgroundPlayback) {
                MioBrowserSettings.backgroundPlayback = $0
                NotificationCenter.default.post(name: .mioBrowserSettingsDidChange, object: nil)
            }
        case .nowPlaying:
            cell.textLabel?.text = "锁屏 / 控制中心控制"
            cell.accessoryView = makeSwitch(MioMediaSettings.nowPlaying) { MioMediaSettings.nowPlaying = $0 }
        case .pip:
            cell.textLabel?.text = "播放器上的画中画按钮"
            cell.accessoryView = makeSwitch(MioMediaSettings.pipButton) { MioMediaSettings.pipButton = $0 }
        case .sponsorBlock:
            cell.textLabel?.text = "跳过赞助等片段（SponsorBlock）"
            cell.accessoryView = makeSwitch(MioMediaSettings.sponsorBlock) { [weak self] in
                MioMediaSettings.sponsorBlock = $0
                self?.rebuild()
            }
        case .category(let c):
            cell.textLabel?.text = c.title
            cell.indentationLevel = 1
            cell.accessoryView = makeSwitch(MioMediaSettings.categoryEnabled(c.key)) { MioMediaSettings.setCategory(c.key, $0) }
        case .drmInfo:
            cell.textLabel?.text = "Spotify 等 DRM 内容"
            cell.detailTextLabel?.text = "iPhone / Mac 的内置浏览器用系统 WebKit，只支持 Apple FairPlay，不支持 Widevine；open.spotify.com 的网页播放器需要 Widevine，可能无法播放，请用 Safari 或 Spotify App。"
        }
        return cell
    }

    private func makeSwitch(_ on: Bool, _ change: @escaping (Bool) -> Void) -> UISwitch {
        let sw = UISwitch()
        sw.isOn = on
        sw.addAction(UIAction { action in
            if let s = action.sender as? UISwitch { change(s.isOn) }
        }, for: .valueChanged)
        return sw
    }
}

// MARK: - Mac CI 冒烟（只在 MIO_SMOKE_OUT 时由 MioDesktop 调用）

enum MioMediaSmoke {
    /// 在内置浏览器当前的 YouTube 页面检查媒体脚本，再记录 EME 能力；之后打开 open.spotify.com 记录 EME（不作门槛）。
    /// 门槛（ok）：媒体脚本已注入 + videoID 解析 + crypto.subtle 哈希前缀正确。
    static func run(completion: @escaping ([String: Any]) -> Void) {
        var report: [String: Any] = [:]
        func json(_ s: Any?) -> Any {
            guard let str = s as? String, let o = try? JSONSerialization.jsonObject(with: Data(str.utf8)) else { return s.map { "\($0)" } ?? "none" }
            return o
        }
        /// 启动脚本 → 轮询 window[key]（JSON 字符串）
        func probe(_ start: String, _ key: String, timeout: TimeInterval, _ done: @escaping (Any) -> Void) {
            MioBrowserViewController.smokeEvaluate(start) { _, _ in
                let deadline = Date().addingTimeInterval(timeout)
                func poll() {
                    MioBrowserViewController.smokeEvaluate("window.\(key) || null") { r, _ in
                        if let s = r as? String { done(json(s)); return }
                        if Date() > deadline { done("timeout"); return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { poll() }
                    }
                }
                poll()
            }
        }
        probe(MioMediaScripts.mediaSmokeScript, "__mioMediaSmoke", timeout: 6) { media in
            report["youtube"] = media
            let m = media as? [String: Any]
            report["ok"] = (m?["installed"] as? Bool) == true && (m?["parse"] as? Bool) == true && (m?["hashOK"] as? Bool) == true
            probe(MioMediaScripts.emeProbeScript, "__mioEmeProbe", timeout: 9) { eme in
                report["emeYouTube"] = eme
                NSLog("⚡️ Mio smoke: EME on YouTube page = %@", "\(eme)")
                guard MioBrowserViewController.smokeLoad(URL(string: "https://open.spotify.com/")!) else {
                    report["emeSpotify"] = "no browser"
                    completion(report)
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                    probe(MioMediaScripts.emeProbeScript, "__mioEmeProbe", timeout: 9) { eme2 in
                        report["emeSpotify"] = eme2
                        NSLog("⚡️ Mio smoke: EME on open.spotify.com = %@ (informational: Spotify web player needs Widevine)", "\(eme2)")
                        completion(report)
                    }
                }
            }
        }
    }
}
