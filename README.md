# MioApp

MioCore（https://mio.300031.xyz）的壳 App：iOS / Android（Capacitor 8）、Mac（Mac Catalyst）、Windows（Electron）。

- App 直接加载线上站点（启动页 `/mio/nav`，见 `server.appStartPath`），MioCore 部署新版后 App 自动生效，无需重新打包。
- 只有改壳本身（图标、原生能力、权限说明）才需要重新出 ipa。

## 出包

GitHub Actions **Build**（`.github/workflows/build.yml`）：PR / 推送 `main` / 手动运行都构建全部平台，运行页面下载产物（保留 14 天）。

| job | runner | 产物 |
|---|---|---|
| `ios` | macos-26 | `Mio.ipa`（未签名） |
| `mac` | macos-26 | `Mio-<版本>-mac.dmg` / `.zip`（Mac Catalyst，arm64 + x86_64，ad-hoc 签名） |
| `android` | ubuntu-24.04 | `Mio-<版本>-android-unsigned.apk`（release，未签名）、`Mio-<版本>-android-debug.apk`（debug 签名） |
| `windows` | windows-latest | `Mio-Setup-<版本>-x64.exe`（NSIS 安装版）、`Mio-Portable-<版本>-x64.exe`（便携版），未签名 |
| `adblock-check` | macos-26 | iOS 拦截规则编译 / YouTube 查询 / WKWebView 对比报告 |

打 `v*` 标签：所有平台成功后 `release` job 把以上产物挂到 Releases。Android 正式包 `Mio.apk` 不在 CI 里签名：
发布后在本地用固定 keystore 对 release APK 做 v2/v3 签名，`apksigner verify` 通过后上传到同一个 Release（keystore 不进仓库、不进 Actions secrets）。

## 安装

### iPhone / iPad

ipa 未签名。用电脑上的 [iloader](https://iloader.app) → Import IPA，用自己的 Apple ID 签名后装到 iPhone。
免费 Apple ID 签名 7 天有效，到期前重新装一次（数据保留），或交给 SideStore 自动续签。

### Android

- 装 Release 里的 **`Mio.apk`**（固定 keystore 签名，以后的版本同一签名，可直接覆盖升级、数据保留）。需要允许「安装未知应用」。
- `-android-debug.apk`：CI 的 debug 签名（每次构建临时生成密钥），只用于临时测试；和 `Mio.apk` 签名不同，互相覆盖前要先卸载。
- `-android-unsigned.apk`：未签名原包，不能直接安装。
- arm64-v8a（手机）+ x86_64（模拟器 / Chromebook），最低 Android 7.0（API 24）。

### Mac

- 打开 dmg，把 Mio 拖进「应用程序」。ad-hoc 签名、未公证：第一次打开在 Finder 里 **右键 → 打开**（或 系统设置 → 隐私与安全性 → 仍要打开；
  或 `xattr -dr com.apple.quarantine /Applications/Mio.app`）。macOS 12+，Apple 芯片 / Intel 通用。

### Windows

- `Mio-Setup-…exe` 装到当前用户（可选目录，不需要管理员）；`Mio-Portable-…exe` 免安装（数据在 `%APPDATA%\Mio`）。
- 未签名：SmartScreen 提示「Windows 已保护你的电脑」→ **更多信息 → 仍要运行**。Windows 10 / 11 x64。

## 结构

| 路径 | 说明 |
|---|---|
| `capacitor.config.json` | 站点地址、允许跳转的域名（Cloudflare Access / Google / GitHub 登录） |
| `www/index.html` | 离线兜底页 |
| `ios/App` | Xcode 工程（SPM，无 CocoaPods）；同一个 target 也出 Mac Catalyst |
| `android/` | Android 工程（Capacitor 8）：`MioBrowserPlugin`、`BrowserActivity`（独立进程 `:browser`）、`AdblockStore` / `AdblockUpdateWorker` |
| `native/mioadblock` | Android 拦截引擎（Rust：Brave adblock-rust 0.13.3 + AdGuard 高级规则 / Scriptlets，JNI），`cargo ndk` 交叉编译 |
| `desktop/` | Windows（Electron）壳：主窗口 + 内置浏览器（Ghostery 拦截） |
| `scripts/fetch-adblock-assets.mjs` | iOS / Mac / Android 内置拦截资源 |
| `.github/workflows/build.yml` | 全平台构建 + 发布 |

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

## 已知限制

- WKWebView 不支持网页里的文件下载，快传取件下载可能无效（后续可加原生下载插件）。
- 不能后台运行，也不能自动读取相册。

## Android（0.3.0 起）

- Capacitor 8 Android 工程，主界面同 iOS（`/mio/nav`），注册同名插件 `MioBrowser`（`open` / `openSettings` / `getInfo`），MioCore 无需区分平台。
- 内置浏览器 `BrowserActivity` 跑在独立进程 `:browser`（WebView 数据目录与主界面分开）：地址栏、前进后退刷新、分享、用系统浏览器打开、拦截开关 / 设置。
- 拦截：`native/mioadblock`（Rust）—— Brave [adblock-rust](https://github.com/brave/adblock-rust) 网络请求 + 元素隐藏；AdGuard 高级规则（scriptlet / CSS / JS / ExtendedCss）自建索引，
  用 AdGuard Scriptlets 生成页面脚本注入。列表与 iOS 相同（同一份 `fetch-adblock-assets.mjs` 输出，含 filter-0）。
- 自动更新：WorkManager 每天 + 启动时距上次超过 24 小时，逐个列表条件请求；Scriptlets 同 iOS（npm 同主版本 latest → jsDelivr + SHA-256 校验）。
- CI：`cargo test`（真实列表）→ `cargo ndk -t arm64-v8a -t x86_64 --platform 24` → `cap sync android` → `assembleRelease assembleDebug`，检查 APK 内两个架构的 `libmioadblock.so` 和拦截资源。
- 签名：`android/app/build.gradle` 从环境变量读取（`MIO_KEYSTORE_FILE` 等），缺失时跳过；CI 不配置，release 保持未签名。

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

## Windows（Electron，0.3.0 起）

`desktop/`：Electron 44 + electron-builder（NSIS + portable）。

- 主窗口（会话 `persist:mio`）加载 `/mio/nav`，preload 暴露 `window.MioDesktop.browser`（只接受 MioCore 站点主框架的调用）。主窗口只允许 MioCore / Cloudflare Access / Google / GitHub 登录的跳转，其余站外地址交给内置浏览器。
- 内置浏览器：独立窗口，会话 `persist:mio-browser`（与主窗口分开，可在设置里清除）；地址栏（网址或 Google 搜索）、前进后退刷新、用系统浏览器打开、盾牌（本页拦截数、当前站点开关）、设置；
  Ctrl+L / F5 / Alt+← → / Ctrl+W / F12；后台播放（`document.hidden` 恒为 false + `backgroundThrottling: false`）。
- 拦截：[@ghostery/adblocker-electron](https://github.com/ghostery/adblocker) 2.20.1 —— 网络（含 `$redirect` / `$csp`）、元素隐藏（generic、扩展选择器、DOM 变化补充）、Scriptlets（`##+js()`，uBO resources.json）。
  Scriptlets 由 Mio 的 frame preload 在页面脚本之前同步取到并注入主世界（Ghostery 默认的异步注入太晚），iframe 里也生效。
  列表：与 iOS / Android 相同的 6 个 AdGuard 列表的 **uBlock Origin 语法版本**（`filters.adtidy.org/extension/ublock/filters/<id>.txt`），加 `desktop/filters/mio-youtube.txt`（filter-0 的 uBO 版）。
- 引擎在 `utilityProcess` 里构建（约 55 万条网络规则，几秒），序列化缓存到 `%APPDATA%\Mio\adblock\engine.bin`，之后启动直接反序列化（约 50 ms）。
- 自动更新：启动 15 秒后 + 每小时检查是否满 24 小时，逐个列表 / resources.json 条件请求；有变化后台重建并原子替换；失败继续用现有版本，首装用安装包内置版本。
- 设置窗口：总开关、当前站点开关、外链默认用系统浏览器、后台播放、清除浏览数据、列表规则数 / 版本 / 下载时间、Scriptlets 数、引擎规模、上次检查结果、立即更新、白名单（含子域名）。
- 测试：`cd desktop && npm test`；CI 还启动打包后的 exe 冒烟（引擎就绪、主窗口有 `MioDesktop.browser`、YouTube 有请求被拦截、白名单后不拦截）。本地运行：`npm ci && npm run fetch-assets && npm start`。
