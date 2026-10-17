// MioUpdater.swift — 软件内更新（iOS 侧载 / Mac Catalyst），纯逻辑在 MioUpdateCore.swift
//
// - 回到前台（SceneDelegate.sceneDidBecomeActive）：「自动检查更新」打开、距上次检查 ≥ 24 小时 → 查 GitHub Releases latest
// - iOS（SideStore / AltStore 侧载，App 不能自己装 ipa）：弹窗「在 SideStore 中更新」（sidestore:// 添加 Mio 源，
//   之后在 SideStore「我的 App」里更新）/「打开 Release 页」
// - Mac Catalyst：下载 Mio-x.y.z-mac.zip → 校验 SHA-256（CI 生成的 SHA256SUMS.txt + GitHub 资产 digest）→
//   写一个辅助脚本（/bin/sh，独立会话）→ App 退出 → 脚本解压、替换当前 .app、去 quarantine、重新打开。
//   App 所在目录不可写（App Translocation、dmg 里直接运行、权限不够）时退化为打开下载页。
// 设置键前缀 mio.update.*；设置页「软件更新」区块调用 MioUpdater.shared。

import UIKit

enum MioUpdateSettings {
    private static let autoCheckKey = "mio.update.autoCheck"
    private static let lastCheckKey = "mio.update.lastCheck"
    private static let lastAttemptKey = "mio.update.lastAttempt"
    private static let skipVersionKey = "mio.update.skipVersion"

    static var autoCheck: Bool {
        get { UserDefaults.standard.object(forKey: autoCheckKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: autoCheckKey) }
    }
    static var lastCheck: Date? {
        get { UserDefaults.standard.object(forKey: lastCheckKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: lastCheckKey) }
    }
    static var lastAttempt: Date? {
        get { UserDefaults.standard.object(forKey: lastAttemptKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: lastAttemptKey) }
    }
    static var skipVersion: String? {
        get { UserDefaults.standard.string(forKey: skipVersionKey) }
        set { UserDefaults.standard.set(newValue, forKey: skipVersionKey) }
    }
}

final class MioUpdater: NSObject {
    static let shared = MioUpdater()

    private(set) var busy = false
    private var downloadTask: URLSessionDownloadTask?
    private var progressObservation: NSKeyValueObservation?

    var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    /// CI 冒烟测试（MIO_SMOKE_OUT）不自动检查
    private static let isSmokeTest = ProcessInfo.processInfo.environment["MIO_SMOKE_OUT"] != nil

    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 30
        return URLSession(configuration: c)
    }()

    // MARK: - Entry points

    func sceneDidBecomeActive() {
        guard !Self.isSmokeTest, !busy else { return }
        guard MioUpdateCore.shouldAutoCheck(enabled: MioUpdateSettings.autoCheck, lastCheck: MioUpdateSettings.lastCheck,
                                            lastAttempt: MioUpdateSettings.lastAttempt, now: Date()) else { return }
        // 冷启动时晚几秒，不和首屏加载抢网络
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self = self, !self.busy, UIApplication.shared.applicationState == .active else { return }
            guard MioUpdateCore.shouldAutoCheck(enabled: MioUpdateSettings.autoCheck, lastCheck: MioUpdateSettings.lastCheck,
                                                lastAttempt: MioUpdateSettings.lastAttempt, now: Date()) else { return }
            self.check(manual: false, from: nil)
        }
    }

    /// 设置页「立即检查」（manual = true：已是最新 / 失败也提示，忽略「跳过此版本」）
    func check(manual: Bool, from presenter: UIViewController?, completion: (() -> Void)? = nil) {
        guard !busy else { completion?(); return }
        busy = true
        MioUpdateSettings.lastAttempt = Date()
        var req = URLRequest(url: MioUpdateCore.latestAPI)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Mio-iOS/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        Self.session.dataTask(with: req) { [weak self] data, resp, error in
            let result: Result<MioUpdateCore.Release?, Error>
            if let error = error {
                result = .failure(error)
            } else if let http = resp as? HTTPURLResponse, http.statusCode == 404 {
                result = .success(nil)
            } else if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                result = .failure(NSError(domain: "MioUpdate", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "GitHub API HTTP \(http.statusCode)"]))
            } else {
                result = Result { try MioUpdateCore.parseRelease(data ?? Data()) }
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.busy = false
                self.handle(result, manual: manual, presenter: presenter)
                completion?()
            }
        }.resume()
    }

    private func handle(_ result: Result<MioUpdateCore.Release?, Error>, manual: Bool, presenter: UIViewController?) {
        switch result {
        case .failure(let e):
            NSLog("⚡️ Mio update check failed: %@", e.localizedDescription)
            if manual { alert("检查更新失败", e.localizedDescription, presenter: presenter) }
        case .success(let release):
            MioUpdateSettings.lastCheck = Date()
            let current = currentVersion
            guard let r = release, MioUpdateCore.isNewer(r.version, than: current) else {
                if manual { alert("已是最新版本", "当前版本 \(current)" + (release.map { "，最新发布 \($0.version)" } ?? "") + "。", presenter: presenter) }
                return
            }
            if !manual && MioUpdateSettings.skipVersion == r.version { return }
            NSLog("⚡️ Mio update available: %@ (current %@)", r.version, current)
            presentUpdate(r, manual: manual, presenter: presenter)
        }
    }

    // MARK: - Prompt

    private func presentUpdate(_ r: MioUpdateCore.Release, manual: Bool, presenter: UIViewController?) {
        let notes = MioUpdateCore.plainNotes(r.notes)
        let title = "发现新版本 \(r.version)（当前 \(currentVersion)）"
        #if targetEnvironment(macCatalyst)
        let hint = "下载后 Mio 会退出并自动替换为新版本，然后重新打开。"
        let a = UIAlertController(title: title, message: (notes.isEmpty ? "" : notes + "\n\n") + hint, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "下载并安装", style: .default) { [weak self] _ in self?.macInstall(r, presenter: presenter) })
        a.addAction(UIAlertAction(title: "打开下载页", style: .default) { _ in UIApplication.shared.open(r.page) })
        #else
        let hint = "侧载版不能在 App 内直接安装：在 SideStore / AltStore 里添加 Mio 源后，到「我的 App」更新（继续用同一个 Apple ID 签名，数据保留）。"
        let a = UIAlertController(title: title, message: (notes.isEmpty ? "" : notes + "\n\n") + hint, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "在 SideStore 中更新", style: .default) { [weak self] _ in self?.openSideStore(fallback: r.page) })
        a.addAction(UIAlertAction(title: "打开 Release 页", style: .default) { _ in UIApplication.shared.open(r.page) })
        #endif
        if !manual {
            a.addAction(UIAlertAction(title: "跳过此版本", style: .default) { _ in MioUpdateSettings.skipVersion = r.version })
        }
        a.addAction(UIAlertAction(title: "稍后", style: .cancel))
        present(a, from: presenter)
    }

    /// 依次尝试 sidestore:// / altstore-classic:// / altstore:// 添加源；都没有安装时打开 Release 页
    func openSideStore(fallback: URL = MioUpdateCore.releasesPage) {
        var links = MioUpdateCore.addSourceDeepLinks()
        func next() {
            guard !links.isEmpty else { UIApplication.shared.open(fallback); return }
            let url = links.removeFirst()
            UIApplication.shared.open(url, options: [:]) { ok in
                NSLog("⚡️ Mio update: open %@ → %@", url.scheme ?? "?", ok ? "ok" : "no handler")
                if !ok { next() }
            }
        }
        next()
    }

    // MARK: - Mac Catalyst

    #if targetEnvironment(macCatalyst)
    private func macFallback(_ r: MioUpdateCore.Release, _ reason: String, presenter: UIViewController?) {
        let a = UIAlertController(title: "无法自动更新", message: reason, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "打开下载页", style: .default) { _ in UIApplication.shared.open(r.page) })
        a.addAction(UIAlertAction(title: "关闭", style: .cancel))
        present(a, from: presenter)
    }

    private func macInstall(_ r: MioUpdateCore.Release, presenter: UIViewController?) {
        guard let zip = r.macZip else {
            return macFallback(r, "Release \(r.tag) 里没有 Mac 安装包（Mio-\(r.version)-mac.zip）。", presenter: presenter)
        }
        let bundlePath = Bundle.main.bundleURL.path
        let parent = (bundlePath as NSString).deletingLastPathComponent
        let fm = FileManager.default
        guard MioUpdateCore.canReplaceInPlace(bundlePath: bundlePath) else {
            return macFallback(r, "Mio 当前从只读位置运行（\(bundlePath)）。请先把 Mio.app 拖到「应用程序」文件夹再打开，或从下载页手动更新。", presenter: presenter)
        }
        guard fm.isWritableFile(atPath: parent), fm.isWritableFile(atPath: bundlePath) else {
            return macFallback(r, "没有权限替换 \(bundlePath)。请从下载页手动更新。", presenter: presenter)
        }
        busy = true
        let progress = UIAlertController(title: "下载 Mio \(r.version)", message: "正在获取校验信息…", preferredStyle: .alert)
        progress.addAction(UIAlertAction(title: "取消", style: .cancel) { [weak self] _ in
            self?.downloadTask?.cancel()
        })
        present(progress, from: presenter)
        let finish: (String?) -> Void = { [weak self] error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.busy = false
                self.downloadTask = nil
                self.progressObservation = nil
                progress.dismiss(animated: true) {
                    if let e = error { self.macFallback(r, e, presenter: presenter) }
                }
            }
        }
        fetchSums(r) { [weak self] sums in
            guard let self = self else { return }
            let expected: String
            do {
                expected = try MioUpdateCore.expectedSha256(for: zip, sums: sums)
            } catch {
                return finish(error.localizedDescription)
            }
            DispatchQueue.main.async { progress.message = "正在下载…" }
            let task = Self.session.downloadTask(with: zip.url) { tmp, resp, error in
                if let e = error as NSError? {
                    return finish(e.code == NSURLErrorCancelled ? nil : "下载失败：\(e.localizedDescription)")
                }
                guard let tmp = tmp, let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    return finish("下载失败：HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)")
                }
                do {
                    let work = fm.temporaryDirectory.appendingPathComponent("mio-update-\(UUID().uuidString)", isDirectory: true)
                    try fm.createDirectory(at: work, withIntermediateDirectories: true)
                    let file = work.appendingPathComponent(zip.name)
                    try fm.moveItem(at: tmp, to: file)
                    let actual = try MioUpdateCore.sha256Hex(ofFile: file)
                    guard MioUpdateCore.sha256Matches(actual, expected) else {
                        try? fm.removeItem(at: work)
                        throw MioUpdateCore.ChecksumError.fileMismatch
                    }
                    NSLog("⚡️ Mio update: %@ sha256 ok (%@)", zip.name, actual)
                    try self.launchInstaller(zip: file, work: work, target: bundlePath)
                    DispatchQueue.main.async {
                        self.busy = false
                        progress.message = "校验通过，Mio 即将退出并安装新版本…"
                        // 给辅助脚本一点时间启动，然后退出（脚本等本进程退出后再替换）
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { exit(0) }
                    }
                } catch {
                    finish(error.localizedDescription)
                }
            }
            self.progressObservation = task.progress.observe(\.fractionCompleted) { p, _ in
                let total = zip.size > 0 ? Double(zip.size) : Double(p.totalUnitCount)
                DispatchQueue.main.async {
                    progress.message = total > 0
                        ? String(format: "%.1f / %.1f MB", p.fractionCompleted * total / 1_048_576, total / 1_048_576)
                        : String(format: "%.0f%%", p.fractionCompleted * 100)
                }
            }
            self.downloadTask = task
            task.resume()
        }
    }

    /// SHA256SUMS.txt（CI 生成）→ [name: hex]；没有该资产 / 下载失败时 nil（只用 GitHub 资产 digest）
    private func fetchSums(_ r: MioUpdateCore.Release, completion: @escaping ([String: String]?) -> Void) {
        guard let a = r.asset(named: MioUpdateCore.sumsAsset) else { return completion(nil) }
        Self.session.dataTask(with: a.url) { data, resp, _ in
            guard let data = data, let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let text = String(data: data, encoding: .utf8) else { return completion(nil) }
            completion(MioUpdateCore.parseSha256Sums(text))
        }.resume()
    }

    /// 写辅助脚本并以独立会话（POSIX_SPAWN_SETSID）启动 /bin/sh，App 退出后它还在运行
    private func launchInstaller(zip: URL, work: URL, target: String) throws {
        let fm = FileManager.default
        let script = work.appendingPathComponent("install.sh")
        try MioUpdateCore.macInstallScript.write(to: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let logs = fm.urls(for: .libraryDirectory, in: .userDomainMask).first?.appendingPathComponent("Logs", isDirectory: true)
        if let logs = logs { try? fm.createDirectory(at: logs, withIntermediateDirectories: true) }
        let log = logs?.appendingPathComponent("Mio-update.log").path ?? work.appendingPathComponent("update.log").path
        let args = ["/bin/sh", script.path, String(getpid()), zip.path, target, work.path, log, Bundle.main.bundleIdentifier ?? MioUpdateCore.bundleIdentifier]
        var cargs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
        cargs.append(nil)
        defer { for p in cargs { free(p) } }
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // POSIX_SPAWN_SETSID = 0x0400（macOS 10.15+）：新会话，不随 App 的进程组一起结束
        if posix_spawnattr_setflags(&attr, Int16(0x0400)) != 0 {
            NSLog("⚡️ Mio update: POSIX_SPAWN_SETSID not supported")
        }
        // 固定的最小环境（不依赖 App 进程的环境变量）
        let envStrings: [String] = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin", "HOME=\(NSHomeDirectory())", "LANG=en_US.UTF-8"]
        var cenv: [UnsafeMutablePointer<CChar>?] = envStrings.map { strdup($0) }
        cenv.append(nil)
        defer { for p in cenv { free(p) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, "/bin/sh", nil, &attr, cargs, cenv)
        guard rc == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(rc), userInfo: [NSLocalizedDescriptionKey: "无法启动安装脚本（posix_spawn \(rc)）"])
        }
        NSLog("⚡️ Mio update: installer pid %d, log %@", pid, log)
    }
    #endif

    // MARK: - Presentation

    private func alert(_ title: String, _ message: String, presenter: UIViewController?) {
        let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "好", style: .default))
        present(a, from: presenter)
    }

    private func present(_ vc: UIViewController, from presenter: UIViewController?) {
        guard var top = presenter ?? Self.topViewController() else { return }
        while let p = top.presentedViewController, !p.isBeingDismissed { top = p }
        top.present(vc, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let window = scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
        return window?.rootViewController
    }
}

// MARK: - Settings UI helpers（MioBrowserSettingsViewController 的「软件更新」区块）

enum MioUpdaterSettingsUI {
    #if targetEnvironment(macCatalyst)
    static let footer = "发现新版本时下载 Mac 安装包（校验 SHA-256），Mio 退出后自动替换并重新打开。Mio.app 放在只读位置（如直接从 dmg 运行）时改为打开下载页。"
    #else
    static let footer = "侧载版在 SideStore / AltStore 里更新：发现新版本时可一键添加 Mio 源（\(MioUpdateCore.altStoreSourceURL)），之后在「我的 App」里更新。"
    #endif

    static func configureCheckCell(_ cell: UITableViewCell, formatter: (Date?) -> String) {
        let busy = MioUpdater.shared.busy
        cell.textLabel?.text = busy ? "正在检查…" : "立即检查更新"
        cell.textLabel?.textColor = .systemBlue
        cell.detailTextLabel?.text = "当前 \(MioUpdater.shared.currentVersion) · 上次检查 \(formatter(MioUpdateSettings.lastCheck))"
        cell.selectionStyle = .default
    }
}
