# MioApp

MioCore（https://mio.300031.xyz）的 iOS 壳 App，基于 Capacitor 8。

- App 直接加载线上站点（启动页 `/mio/nav`，见 `server.appStartPath`），MioCore 部署新版后 App 自动生效，无需重新打包。
- 只有改壳本身（图标、原生能力、权限说明）才需要重新出 ipa。

## 出包

推送到 `main` 或手动运行 Actions → **Build unsigned IPA**，在运行页面下载 `Mio-ipa` 产物（保留 14 天）。
打 `v*` 标签会额外发布到 Releases。

## 安装

ipa 未签名。用电脑上的 [iloader](https://iloader.app) → Import IPA，用自己的 Apple ID 签名后装到 iPhone。
免费 Apple ID 签名 7 天有效，到期前重新装一次（数据保留），或交给 SideStore 自动续签。

## 结构

| 路径 | 说明 |
|---|---|
| `capacitor.config.json` | 站点地址、允许跳转的域名（Cloudflare Access / Google / GitHub 登录） |
| `www/index.html` | 离线兜底页 |
| `ios/App` | Xcode 工程（SPM，无 CocoaPods） |
| `.github/workflows/ios.yml` | macOS runner 无签名编译并打包 ipa |

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

- 浏览器：地址栏（标题 — 域名；点一下可输入网址或搜索）、前进 / 后退 / 刷新、分享、**用 Safari 打开**（指南针图标）、设置（齿轮）、关闭；左右滑动手势前进后退。
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
