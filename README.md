# MioApp

MioCore（https://mio.300031.xyz）的壳 App：iPhone / iPad（Capacitor 8）、Mac（Mac Catalyst）。只做 Apple 平台。

> Android / Windows 已停止开发，**v0.3.4 是最后一版**（[tag v0.3.4](https://github.com/mio-co/MioApp/tree/v0.3.4) 和 Release 保留存档，代码可在该 tag 查看）。

- App 直接加载线上站点（启动页 `/mio/nav`，见 `server.appStartPath`），MioCore 部署新版后 App 自动生效，无需重新打包。
- 只有改壳本身（图标、原生能力、权限说明）才需要重新出 ipa。

## 出包

GitHub Actions **Build**（`.github/workflows/build.yml`）：PR / 推送 `main` / 手动运行都构建 iOS 和 Mac，运行页面下载产物（保留 14 天）。

| job | runner | 产物 |
|---|---|---|
| `ios` | macos-26 | `Mio.ipa`（未签名） |
| `mac` | macos-26 | `Mio-<版本>-mac.dmg` / `.zip`（Mac Catalyst，arm64 + x86_64，ad-hoc 签名） |
| `ios-sim-smoke` | macos-26 | iOS 模拟器冷启动 + 布局截图冒烟 |
| `unit` | ubuntu-24.04 | Swift 纯逻辑单测 + 注入 JS 单测（node --test / jsdom） |
| `adblock-check` | macos-26 | iOS 拦截规则编译 / YouTube 查询 / WKWebView 对比报告 |

打 `v*` 标签：`unit` / `ios` / `ios-sim-smoke` / `mac` 都成功后 `release` job 把产物挂到 Releases。

## 安装

### iPhone / iPad

ipa 未签名。用电脑上的 [iloader](https://iloader.app) → Import IPA，用自己的 Apple ID 签名后装到 iPhone。
免费 Apple ID 签名 7 天有效，到期前重新装一次（数据保留），或交给 SideStore 自动续签。

### Mac

- 打开 dmg，把 Mio 拖进「应用程序」。ad-hoc 签名、未公证：第一次打开在 Finder 里 **右键 → 打开**（或 系统设置 → 隐私与安全性 → 仍要打开；
  或 `xattr -dr com.apple.quarantine /Applications/Mio.app`）。macOS 12+，Apple 芯片 / Intel 通用。

## 软件内更新（0.3.3 起）

启动 / 回到前台时，如果「自动检查更新」开着、距上次检查超过 24 小时，就查一次
[GitHub Releases latest](https://api.github.com/repos/mio-co/MioApp/releases/latest)（公开仓库，不需要 token）。
设置里有「自动检查更新」开关和「立即检查」（内置浏览器设置 › 软件更新）。
发现新版本时弹窗显示更新说明，可以「稍后」或「跳过此版本」。

| 平台 | 怎么更新 | 校验 |
|---|---|---|
| Mac | App 内下载 `Mio-<版本>-mac.zip` → Mio 退出 → 辅助脚本替换当前 `Mio.app`、去掉 quarantine、重新打开（日志 `~/Library/Logs/Mio-update.log`）。从 dmg 里直接运行 / 目录不可写时改为打开下载页 | `SHA256SUMS.txt`（CI 生成）+ GitHub 资产 digest，Info.plist 的 bundle id 必须一致 |
| iPhone / iPad | 侧载版不能自己装 ipa：弹窗「在 SideStore 中更新」添加 Mio 源，然后在 SideStore「我的 App」里更新 | SideStore / AltStore 按源里的版本和大小下载 Release 的 `Mio.ipa` |

### SideStore / AltStore 源

源地址（每次发版自动更新）：

```
https://github.com/mio-co/MioApp/releases/latest/download/altstore-source.json
```

- SideStore：**源（Sources）→ 右上角 + → 粘贴上面的地址 → 添加**，在 Mio 页面点「获取 / Get」。已经装过 Mio 时，之后的新版本出现在「我的 App（My Apps）」的更新里，
  用同一个 Apple ID 重签，数据保留。也可以在 iPhone 上直接打开
  `sidestore://source?url=https%3A%2F%2Fgithub.com%2Fmio-co%2FMioApp%2Freleases%2Flatest%2Fdownload%2Faltstore-source.json`。
- AltStore Classic：浏览（Browse）→ 源（Sources）→ + → 同一地址。
- Mio 里发现新版本时点「在 SideStore 中更新」会自动打开上面的添加源链接（没装 SideStore 时依次尝试 AltStore，都没有就打开 Release 页）。

### 发版产物（release job 自动生成）

- `SHA256SUMS.txt`：本次 Release 全部 CI 产物的 sha256（`sha256sum -c` 格式）。
- `altstore-source.json`：AltStore 源 v2 格式（`bundleIdentifier` = `xyz.mio.app`，`versions[0]` = 本次 `Mio.ipa` 的版本 / buildVersion / 日期 / 大小 / minOSVersion，
  `appPermissions.privacy` 取自 Info.plist）。生成脚本 `scripts/release-manifests.mjs`，单测 `tools/MioAppTests/js/release-manifests.test.mjs`，PR 的 `unit` job 里会对假产物跑一遍。

## 结构

| 路径 | 说明 |
|---|---|
| `capacitor.config.json` | 站点地址、允许跳转的域名（Cloudflare Access / Google / GitHub 登录） |
| `www/index.html` | 离线兜底页 |
| `ios/App` | Xcode 工程（SPM，无 CocoaPods）；同一个 target 也出 Mac Catalyst |
| `shared/` | 注入脚本单一来源（YouTube 防沉迷、翻译），iOS / Mac 共用 |
| `www/mio-browser/` | 阅读模式 / 强制深色 / 存到 Mio 页面脚本 |
| `scripts/fetch-adblock-assets.mjs` | iOS / Mac 内置拦截资源 |
| `scripts/release-manifests.mjs` | 发版清单（SHA256SUMS.txt、altstore-source.json） |
| `assets/icon.png` | 1024×1024 图标（SideStore / AltStore 源用） |
| `tools/` | `MioAppTests`（单测）、`AdblockCheck`（macOS 拦截核心体检） |
| `.github/workflows/build.yml` | iOS / Mac 构建 + 发布 |

## 冷启动（0.1.2 起）

- 启动屏（`LaunchScreen.storyboard`）：背景色 `MioLaunchBackground`（浅色 `#ffffff` / 深色 `#0a0a0a`，跟随系统），中间 160×160 的 Mio Logo。
- 原生启动遮罩（`AppDelegate.swift` 的 `MioLaunchCover`）与启动屏同色、同 Logo、同位置，盖在 WKWebView 上，直到网页首屏加载动画淡出：
  MioCore 的 `public/boot-loader.js` 通过 `window.webkit.messageHandlers.mioShell` 发 `boot` / `ready` / `failed`。
  兜底：站外页面（Cloudflare Access / Google / GitHub 登录）加载完、站内页面没有 boot-loader（错误页）、真正的网络错误、或 8 秒超时，都会撤掉遮罩。超过 0.8 秒显示转圈。
- WKWebView、窗口、页面下方的底色都设为同一主题色（不是默认的黑 / `systemBackground`）。
- 直接打开 `/mio/nav`，不再经过首页 `/` 的「自动跳转到后台」302（线上实测这一跳 Worker 耗时 p50 约 240 ms）。未登录时 Worker 照常跳登录页。
- 窗口只由 `SceneDelegate` 创建（Info.plist 不声明 storyboard），根控制器是 `MioBridgeViewController`。
- Xcode 控制台会打印 `⚡️ Mio launch cover hidden (ready) at +N ms`，真机测启动耗时用。
- 改启动屏时同步改 `MioLaunchCover`。iOS 会缓存启动屏截图，装新版后若仍是旧启动屏，重启一次手机即可。

## 内置浏览器 + 广告拦截（0.2.0 起）

MioCore（≥ 2026-10-17 部署的版本）在 App 里点**站外链接**（导航页、云剪贴板、笔记、密码库里的网址，以及 `window.open`）会调用原生插件
`Capacitor.Plugins.MioBrowser.open({ url })`，在 App 内置浏览器全屏打开；普通浏览器里行为不变（`MioCore/src/utils/appShell.ts`）。

- 浏览器：地址栏（标题 — 域名；点一下可输入网址或搜索）、前进 / 后退 / 刷新、分享、**用 Safari 打开**（指南针图标；Mac 上为文字按钮，⌘⇧O）、设置（齿轮）、关闭；左右滑动手势前进后退。
  `target=_blank` / `window.open` 在当前页打开；`tel:` `mailto:` 等交给系统。
- 数据隔离：独立的持久化 `WKWebsiteDataStore(forIdentifier:)`（iOS 17+），登录状态保留，和 MioCore 主界面的会话互不影响。（iOS 15–16 只能用默认存储。）
- 后台 / 锁屏播放：`UIBackgroundModes audio` + `AVAudioSession .playback`，页面里 `document.hidden` / `visibilityState` 恒为可见（YouTube 切后台不再自动暂停）。设置里可关。
- 设置 → 「外链默认用 Safari 打开」：打开后 MioCore 的外链直接交给 Safari。

### 拦截方案（AdGuard 开源组件，GPL-3.0，见 [NOTICE](NOTICE)）

| 层 | 组件 | 做什么 |
|---|---|---|
| 网络请求 + 基础元素隐藏 | [SafariConverterLib](https://github.com/AdguardTeam/SafariConverterLib) `ContentBlockerConverter` → `WKContentRuleListStore` | AdGuard/EasyList 规则转成 WebKit 内容拦截 JSON，每个过滤列表单独编译成一个 `WKContentRuleList`（单个列表超过 15 万条会自动对半拆分；例外规则只在同一列表内生效，所以按官方列表边界拆） |
| 脚本类规则 | SafariConverterLib `FilterEngine`（高级规则查询）+ [AdGuard Scriptlets](https://github.com/AdguardTeam/Scriptlets)（`scriptlets.corelibs.json`） | 主框架：在 `decidePolicyFor navigationAction` 里先查好目标页面的 scriptlets / CSS / JS，生成 `atDocumentStart` 用户脚本（按 hostname 分发），比页面脚本先跑；iframe：document-start 发消息给原生，查询后 `evaluateJavaScript(in: frame, in: .page)` 注入 |
| 扩展 CSS | [ExtendedCss](https://github.com/AdguardTeam/ExtendedCss) | `:has()` `:upward()` 等 |

过滤列表（filters.adtidy.org，iOS 优化版）：AdGuard Base、AdGuard 移动广告、AdGuard 跟踪保护、EasyList、EasyPrivacy、AdGuard 中文，
外加 App 内置的「Mio YouTube 补充」（`ios/App/App/AdblockBundle/filter-0.txt`：m.youtube.com 播放器响应里的 `adPlacements` / `playerAds` / `adSlots`、广告请求、页面广告位）。
YouTube 视频广告靠 AdGuard Base 里的 `set-constant ytInitialPlayerResponse.adPlacements` + `json-prune(-fetch/-xhr)-response` 等 scriptlets 去掉。Spotify 不做（iOS 上无法可靠去广告）。

### 自动更新

- **构建时**：`scripts/fetch-adblock-assets.mjs` 下载最新官方列表（带 ETag / Last-Modified 写进 `manifest.json`）、复制 npm 锁定版本的 Scriptlets / ExtendedCss，打进 App（`AdblockBundle/`）。
- **App 启动时**（以及从后台回到前台、`BGAppRefreshTask` 后台刷新）：距上次检查超过 24 小时就逐个列表带 `If-None-Match` / `If-Modified-Since` 请求；有变化的列表在本机重新转换、编译、缓存（`Application Support/MioAdblock`，编译好的规则在 `WKContentRuleListStore` 里持久化，下次启动直接用）。
- **Scriptlets 远程更新**：npm registry 查 `@adguard/scriptlets` 同一主版本的 latest → jsDelivr 下载 `dist/scriptlets.corelibs.json` → 用 jsDelivr data API 给出的 SHA-256 校验 → 解析校验（版本号一致、函数齐全）→ 缓存；任何一步失败都继续用当前 / 内置版本。
- 下载失败、内容不像过滤列表、编译出错：继续用已有规则，首装则用 App 内置版本。
- 设置页（浏览器工具栏齿轮，或右上角盾牌 → 拦截设置）：总开关、当前站点开关、每个列表的规则数 / 版本 / 下载时间、Scriptlets 版本、上次检查结果、**立即更新**、白名单（含子域名，左滑删除）。
- 首次安装后第一次启动要在本机编译约 33 万条规则（macOS CI 上 ~15 秒，手机上预计 15–30 秒，后台进行）；这期间打开浏览器最多等 4 秒，仍未完成就先不拦截加载。

### 验证（CI）

`adblock-check` job 在 macOS runner 上编译与 App 相同的 `MioAdblockCore.swift`（`tools/AdblockCheck`），转换 + 编译全部内置列表、查询 YouTube 的高级规则，并用 WKWebView（iPhone UA）对比开 / 关拦截加载 m.youtube.com 和 adblock-tester.com，产物 `adblock-check`（report.json + 截图）。

## YouTube 防沉迷 + 滚动隐藏工具栏（iOS / Mac 内置浏览器，0.3.2 起）

- **YouTube 防沉迷**（设置 › 浏览体验，默认开；提醒间隔默认 60 秒，可选 30 秒–10 分钟）：`MioWebCompat.youtubeFocusScriptTemplate`，
  document-start 注入，脚本自己只在 `*.youtube.com` 主框架生效。隐藏首页 / 推荐 / 搜索 / 侧栏里的 Shorts 区块和卡片（`html.mio-channel-page` 频道页保留）、
  底部 pivot 栏 / guide / mini guide 的 Shorts 入口、「打开 App」推广，删掉 `apple-itunes-app` meta。手机版（`ytm-*`）和桌面版（`ytd-*`、`grid-shelf-view-model`）都覆盖。
  - 不轮询、不常驻观察整份文档：路由变化靠 `yt-navigate-finish` / `yt-page-data-updated` / `state-navigateend` / `popstate` / `history.pushState/replaceState` 钩子；
    文本识别的 Shorts 导航项只在路由变化和导航容器自己的观察器（200ms 节流）里处理。
  - 进入 `/shorts/` 立即提醒，之后只在页面可见时累计时间（读 `Document.prototype` 的真实可见性，不受「后台播放」脚本影响），离开 Shorts 即重置。
  - 提醒胶囊用 DOM API 构建（YouTube 有 Trusted Types，不能用 innerHTML），`pointer-events: none`，顶部留出 safe-area，深浅色都可读。
  - 关闭后不注入（对之后加载的页面生效）。与 AdGuard Scriptlets 各自独立注入。
  - 测试：`tools/MioAppTests/js/youtube-focus.test.mjs`（jsdom）；Mac CI 冒烟在真实 YouTube 页面里检查脚本已注入并能弹出提醒（`youtubeFocusOK`）。
- **滚动时隐藏工具栏**（iPhone / iPad 默认开，Mac 默认关）：webView 固定铺满安全区，地址栏和底部工具栏浮在上面，用 `scrollView.contentInset` 让出位置
  （尺寸不变 → 页面不重排）。向下滚动超过 16pt 隐藏，向上滚动、回到顶部、停在底部、点状态栏、新的主框架导航、地址栏聚焦（⌘L）、旋转时显示；
  隐藏时顶部保留域名条，点一下恢复。只认用户手势驱动的滚动，VoiceOver 开启或网页全屏时不隐藏。
  状态机是纯函数 `MioToolbarAutoHide`（`MioWebCompat.swift`），单测在 `tools/MioAppTests`。scroll delegate 挂在 WKScrollView 的外部 delegate 上（WebKit 自己的回调照常）。

## 媒体：后台播放 / 画中画 / 锁屏控制 / SponsorBlock / DRM（0.3.3 起）

源码：`ios/App/App/MioMediaScripts.swift`（纯逻辑 + 注入 JS，唯一源）、`ios/App/App/MioMedia.swift`（iOS / Mac 原生部分、设置页）。
设置：浏览器设置 › 浏览体验 › **媒体与 SponsorBlock**。

- **后台播放**（沿用 v0.3.2 的「后台 / 锁屏继续播放」开关，默认开）：可见性伪造从 `MioBrowser.backgroundPlaybackScripts` 移到 `MioMediaScripts.visibilityScript`，
  现在在 window 捕获阶段就拦掉 `visibilitychange`（之前只拦 document）。iOS 上 WebKit 切后台会停掉有画面的 `<video>`：
  原生在 `didEnterBackground` 时通知页面（`__mioMedia.appState('background')`，0 / 0.5 / 1.5 秒，带后台任务），页面脚本在**真的不可见或刚切后台**、
  暂停前确实在播放、不是用户暂停时自动 `play()`。锁屏 / 控制中心的暂停（MediaSession）、耳机拔出（`routeChange oldDeviceUnavailable`）、
  来电 / 其他 App 抢占音频（`interruption began`）、画中画窗口里的暂停都算用户意图，不续播。`AVAudioSession .playback` + `UIBackgroundModes audio` 已有。
  Mac：窗口失焦本来不暂停。
- **锁屏 Now Playing**：页面脚本设置 `navigator.mediaSession` 元数据（标题 / 频道 / 封面 `i.ytimg.com/vi/<id>/hqdefault.jpg`）、位置，
  并包一层 `setActionHandler`：YouTube 自己的处理器照常调用，只是先记一下「用户要暂停」。页面没有 MediaSession 时，iOS 原生用
  `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter`（播放 / 暂停 / 切换 / 上一个 / 下一个 / 拖动进度）兜底，映射到 `__mioMedia.command(...)`。
- **画中画**：YouTube 播放器左上角加一个按钮（点视频显示 3 秒），用 `video.webkitSetPresentationMode('picture-in-picture')`。`allowsPictureInPictureMediaPlayback = true` 已有。
- **SponsorBlock**（默认开，默认只跳 赞助 / 自我推广 / 互动提醒，片头 / 片尾可选）：`GET https://sponsor.ajay.app/api/skipSegments/<SHA-256(videoID) 前 4 位>?categories=[…]&actionTypes=["skip"]`，
  只发哈希前缀，本地按 videoID 精确匹配。YouTube 的 CSP 没有 `connect-src`、API 返回 `Access-Control-Allow-Origin: *`，所以页面直接 `fetch`（`credentials: omit`）；
  iOS 上 fetch 失败时经原生代取（只允许 `https://sponsor.ajay.app/api/skipSegments/<十六进制前缀>`）。播放进入片段自动跳到结尾，底部提示「已跳过…」+「撤销」
  （回到跳过前的位置，本次不再自动跳）；用户手动拖进片段内部也不再跳；进度条上按分类颜色标出片段。全部 DOM API 构建（Trusted Types）。
- **Spotify / DRM**（不改 UA）：iOS / Mac 的 WKWebView 只有 FairPlay（`com.apple.fps`），没有 Widevine；Mac CI 冒烟会记录 YouTube 和 open.spotify.com 上
  `requestMediaKeySystemAccess`（Widevine / FairPlay / ClearKey）的结果（`smoke-mac.json` 的 `media.emeYouTube` / `media.emeSpotify`，不作门槛）。
- 测试：`tools/MioAppTests/js/media-youtube.test.mjs`（videoID 解析、哈希前缀匹配、跳过 / 撤销 / 手动 seek、续播判定、MediaSession、画中画、Trusted Types）、
  `media-visibility.test.mjs`（可见性伪造 + 与防沉迷共存）、`MioMediaScriptsTests.swift`；
  Mac 冒烟门槛 `mediaOK`（真实 YouTube 页面里脚本已注入、`crypto.subtle` 哈希前缀正确）。

SponsorBlock 数据由社区提交，来自 [SponsorBlock](https://sponsor.ajay.app)（作者 Ajay Ramachandran），按 [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/) 授权使用；
Mio 只在播放时实时查询，不缓存到磁盘、不再分发数据。

## 已知限制

- WKWebView 不支持网页里的文件下载，快传取件下载可能无效（后续可加原生下载插件）。
- 不能后台运行，也不能自动读取相册。

## Mac（Mac Catalyst，0.3.0 起）

- 与 iOS 同一个 Xcode target（`SUPPORTS_MACCATALYST = YES`）。Capacitor 的 xcframework 没有 Catalyst 切片，CapApp-SPM 只链接到 iOS（pbxproj `platformFilter = ios`；`CapApp-SPM/Package.swift` 仍由 Capacitor CLI 管理），
  Swift 里用 `#if canImport(Capacitor) && !targetEnvironment(macCatalyst)` 区分。
- Mac 主界面 `MioDesktopViewController`（`ios/App/App/MioDesktop.swift`）：纯 WKWebView 加载 `/mio/nav`，启动遮罩同 iOS，document-start 注入 `window.MioDesktop.browser`
  （`open` / `openSettings` / `getInfo`，WKScriptMessageHandlerWithReply 返回 Promise，只对 MioCore 的 https 主框架开放）。内置浏览器、拦截（SafariConverterLib + Scriptlets + ExtendedCss）、设置页复用 iOS 代码；常驻时每小时检查是否满 24 小时需要更新规则。
- 页面没交给 bridge 的站外链接点击 → 内置浏览器；Access / Google / GitHub 登录留在主窗口；站内新窗口 / 登录弹窗 → 同会话弹窗。⌘R 刷新、⌘[ ⌘] 前进后退、⌘, 拦截设置。
- 内置浏览器在 Mac 上是主窗口里的全屏层（不是独立窗口）。
- 内置浏览器在 Mac（和 iPad）上按桌面 Safari 访问：UA 与系统 Safari 相同（`Macintosh; Intel Mac OS X 10_15_7 … Version/<系统 Safari 版本> Safari/605.1.15`，
  版本由 macOS 版本推出）、`preferredContentMode = .desktop`、`m.youtube.com` 改写到 `www.youtube.com`、Mac 上确保 MediaSource 开启。iPhone 仍用手机 UA。
  纯逻辑在 `ios/App/App/MioWebCompat.swift`（不依赖 UIKit / WebKit）。
- 回车键：Mac 上主界面和内置浏览器都注入 `MioWebCompat.returnKeyFixScript`——textarea / contenteditable 里 Enter / Shift+Enter 没被原生处理时补一次与 Safari 相同的编辑命令
  （页面 preventDefault、输入法组字、原生已插入时都不动）；补过时控制台打印 `[Mio] Return key not handled natively`，回车冒泡到原生控制器时日志 `Return key reached … unhandled`。
- 通行密钥 / iCloud 钥匙串：第三方站点的 Passkey 和钥匙串自动填充需要 Apple 审批的浏览器权限，免签名包拿不到，不做绕过。
  入口：内置浏览器工具栏「用 Safari 打开」、菜单栏「浏览器 › 用 Safari 打开」⌘⇧O、设置页说明；网页调用 WebAuthn 失败时提示改用 Safari。
- CI 冒烟：`MIO_SMOKE_OUT` 时打开公开首页 `/`，确认 `MioDesktop.browser` 存在、`open()` 弹出内置浏览器、拦截规则编译就绪，
  且内置浏览器里 YouTube 页面的 `navigator.userAgent` 是桌面 Safari、MediaSource 可用（`browserProbe`）。
- 单测（`unit` job，不需要 Xcode）：`swift test --package-path tools/MioAppTests`（UA、桌面版改写、过滤列表里会删 YouTube `streamingData` 的规则体检），
  `node --test tools/MioAppTests/js/*.test.mjs`（回车键兜底、通行密钥提示脚本，从 Swift 文件里抽出 JS 跑）。
