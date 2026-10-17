# Mio v0.4.0：Apple-only、浏览器为本体 —— 架构与迁移计划

状态：可行性验证 + 骨架（`feat/mac-native`，draft PR #21，不合并、不发版）。
方向（用户已定）：v0.4.0 只做 iPhone / iPad / Mac；一个 WebKit 引擎、一套 Swift 代码；浏览器是 App 本体；Windows / Android 停止开发
（v0.3.4 tag 作存档，历史不删）。

## 1. 为什么 Mac 要从 Catalyst 换成原生 AppKit

| | Mac Catalyst（v0.3.x） | 原生 AppKit（本分支） |
|---|---|---|
| `typeof MediaSource` / `ManagedMediaSource` | `undefined` / `undefined`（Catalyst 进程里的 WKWebView 是 iOS 配置；私有偏好 `_setMediaSourceEnabled:` 设成 true 也没用） | `function` / `function`，vp9 / av01 / avc1 / hvc1 / opus 全部 `isTypeSupported` = true（CI 证据见 PR） |
| YouTube 桌面 UA | 只有渐进式 mp4 → 360p；靠 v0.3.0 移动 UA 拿 HLS + 「在 Safari 中看高清」兜底 | DASH / MSE，与 Safari 同等清晰度（登录 / 机房 IP 风控除外） |
| 界面 | iPad idiom 整窗 77% 缩放，工具栏 / 缩放都要换算（`MioMacMetrics`） | 1:1，`pageZoom` = Safari 档位 |
| 原生控件 | UIKit 仿 Mac（actionSheet 横排，要 `MioActionList` 兜底） | NSToolbar / NSMenu / 侧边栏 / SwiftUI 设置窗口 |

## 2. v0.4.0 目标结构

```
┌──────────────────────── App = 浏览器 ────────────────────────┐
│ 平台壳（少量）  iOS: UIKit 标签控制器（保留现有 iPhone Safari 式布局）│
│                iPad / Mac: Safari macOS 式工具栏 + 侧边栏 + 标签条   │
│                Mac 用 AppKit（NSToolbar / NSSplitView / 菜单快捷键）  │
├────────────────────────────────────────────────────────────────┤
│ 共用 SwiftUI   设置页（Safari 分区 + Mio 分区）、侧边栏、模块 / 容器 /   │
│                用户脚本管理、阅读视图外观面板……                      │
├────────────────────────────────────────────────────────────────┤
│ WebView 层     MioWebViewHost：配置、数据存储（容器）、把模块脚本装进   │
│ （WebKit）     WKUserContentController、消息桥、内容规则             │
├────────────────────────────────────────────────────────────────┤
│ 模块           MioModule 协议：id / 设置项 / 注入脚本 / 页面菜单项 / 动作│
│                内置：MioCore、YouTube 防沉迷+SponsorBlock、翻译、阅读、 │
│                广告拦截、WebRTC、强制深色、存到 Mio……                 │
│                用户脚本 = 用户自装插件，走同一注入通道（MioUserScriptStore）│
├────────────────────────────────────────────────────────────────┤
│ 纯逻辑（Foundation，Linux 单测）  标签 / 容器 / 缩放 / UA / 翻译 / 阅读 / │
│                用户脚本解析与匹配 / 更新 / 地址栏输入 / 模块注册表        │
└────────────────────────────────────────────────────────────────┘
```

### 2.1 浏览器是本体，MioCore 是模块
- 启动即浏览器窗口（恢复上次标签）。MioCore 不再是根视图（`MioDesktop.swift` 的 Catalyst 根控制器、iOS 的 Capacitor 根视图都退役）。
- `MioCoreModule` 负责：默认主页 / 新标签页（`mio.tabs.newTabURL`，默认 `https://mio.300031.xyz/mio/nav`）、「打开 Mio 主页」菜单项；
  之后加 存到 MioCore（`www/mio-browser/mio-save.js`）、登录、同步（收藏 / 标签 / 设置）。骨架已实现前两项。
- 兼容：MioCore 页面里的 `window.MioDesktop.browser.open()` / Capacitor `MioBrowser.open()` 由 MioCore 模块注入一个小桥，打开新标签即可（几十行）。
- iOS 去掉 Capacitor 依赖（它只为 MioCore 根视图服务）：Info.plist / CapApp-SPM / `npx cap sync` 一起删掉，构建更快。

### 2.2 模块接口（已实现：`macos/Sources/MioMac/Kit/MioModule.swift`，单测 `MioModuleTests`）
```swift
protocol MioModule: AnyObject {
    var id: String { get }; var title: String { get }; var summary: String { get }
    var section: MioSettingsSection { get }        // 设置显示在哪个分区
    var enabledKey: String? { get }                 // 沿用 v0.3.x 的 key（升级不丢设置）；nil = 常开
    var defaultEnabled: Bool { get }
    var settings: [MioModuleSetting] { get }        // toggle / choice / text，设置页自动生成
    func scripts(prefs:) -> [MioModuleScript]       // source + documentStart/End + mainFrameOnly + world(.page / .isolated(name))
    func menuItems(page:prefs:) -> [MioModuleMenuItem]   // 按当前页面过滤
    func perform(_:page:prefs:) -> MioModuleAction  // openURL / evaluateJavaScript / openSettings / reload
}
```
- `MioModuleRegistry`：注册（同 id 不覆盖）、开关、收集启用模块的脚本 / 菜单项、执行动作。宿主只做「脚本 → WKUserScript、菜单项 → 菜单、动作 → 执行」。
- 关掉的模块**不注入任何东西**；设置变了宿主对所有标签重装脚本（`reinstallModuleScripts`），重新载入生效。
- 需要原生能力的模块（翻译的网络代发、广告拦截的内容规则、媒体的 Now Playing）再加可选扩展协议，例如
  `MioModuleMessageHandling`（WKScriptMessageHandlerWithReply 名字 + 处理函数）、`MioModuleContentRules`（WKContentRuleList）、
  `MioModuleLifecycle`（WebView 创建 / 导航完成 / 进入后台），由 WebView 层统一挂载。
- 已包装：`MioCoreModule`、`MioYouTubeFocusModule`（key `mio.browser.youtubeFocus*`）、`MioWebRTCModule`（`mio.webrtc.*`，在「隐私与安全」）。

| 模块 | 现有代码 | 包装要点 | 分区 |
|---|---|---|---|
| MioCore | `MioDesktop.swift`、`MioTabs` 新标签页 | 主页 / 新标签页、存到 Mio、登录、同步、兼容桥 | MioCore |
| YouTube 防沉迷 | `MioWebCompat.youtubeFocusScript` | ✅ 已包装 | 模块 |
| SponsorBlock / YouTube 媒体 | `MioMediaScripts`（脚本）+ `MioMedia.swift`（Now Playing、SponsorBlock 代取） | 脚本 + 消息桥 + 生命周期扩展 | 模块 |
| 翻译 | `mio-translate.js` + `MioTranslate.swift` 桥 + `MioTranslateCore` | 脚本 + 消息桥（URLSession、Keychain） | 模块 |
| 阅读 / 强制深色 / 存到 Mio | `www/mio-browser/*.js` + `MioPageTools.swift` + `MioReaderCore` | 独立 world 脚本 + 地址栏按钮 + 阅读视图（SwiftUI 外观面板） | 模块 / 网站设置（按站点深色） |
| 广告拦截 | `MioAdblockCore.swift`（已不依赖 UIKit，`tools/AdblockCheck` 已在 macOS 原生编译） | 内容规则扩展 + scriptlets / ExtendedCss 脚本 + 后台更新 | 隐私与安全 |
| WebRTC 防泄露 | `MioWebRTCGuard` | ✅ 已包装 | 隐私与安全 |
| 通行密钥提示、后台可见性伪造 | `MioWebCompat` / `MioMediaScripts` | 小模块；回车键兜底只在 iOS 宿主启用 | 高级 / 模块 |
| 用户脚本 | `MioUserScriptCore` + `MioUserScripts.swift` | **不是内置模块**：用户自装插件，管理界面在「用户脚本」分区，注入走同一 WebView 层（每脚本独立 WKContentWorld） | 用户脚本 |

### 2.3 界面与设置照搬 Safari
- **iPhone**：保留现在的 Safari 式布局（`feat/mobile-safari-layout` 那套 UIKit），只把功能挂钩换成模块注册表。
- **iPad / Mac**：Safari macOS 风格——统一工具栏（侧边栏按钮 · 后退 / 前进 · 居中地址栏 · 新标签 · …菜单）、可收起侧边栏（标签页 / 容器 / MioCore；以后加书签、阅读列表）、标签条。Mac 骨架已实现（AppKit 工具栏 + `NSSplitViewController`，侧边栏是 SwiftUI `MioSidebarView`）。iPad 用同一个 SwiftUI 侧边栏 + `UISplitViewController`。
- **设置分区**（`MioSettingsSection`，已实现 SwiftUI `MioSettingsView`，Mac 上是 ⌘, 设置窗口，iOS 上同一 View 放进设置页）：
  - Safari：通用（主页、默认缩放）· 标签页 · 自动填充（系统密码 / 通行密钥）· 搜索 · 隐私与安全（WebRTC、广告拦截、网站数据）· 网站设置（按站点缩放 / 深色 / 权限）· 高级（UA、网页检查器）
  - Mio：容器 · 用户脚本 · 模块（所有内置模块的开关与设置，自动生成）· MioCore（主页、登录、同步、存到 Mio）

### 2.4 iOS 与 macOS 共用 SwiftUI
- 共用：设置页、侧边栏、模块 / 容器 / 用户脚本管理、阅读外观面板、更新提示。只依赖 SwiftUI + Foundation（`Kit/` 下的文件已遵守）。
- 平台差异（少量）：iOS 标签控制器与 iPhone 底栏（UIKit，保留）、Mac 工具栏 / 菜单 / 窗口（AppKit），各自约 1–2 千行。
- WKWebView 两端 API 几乎一致：WebView 层写一份，`#if os(macOS)` 只用于 `pageZoom` 基准、下载面板、文件选择等极少处。

## 3. 骨架现状（`macos/`）

- SwiftPM 可执行 target `MioMac`，最低 macOS 14（`WKWebsiteDataStore(forIdentifier:)` 做容器），不改 `App.xcodeproj`（零 pbxproj 冲突）。
- `Sources/MioMac/Shared/`：符号链接到 `ios/App/App/` 的 11 个 Foundation-only 核心（iOS 编译原文件，Mac 编译同一份）。
- `Sources/MioMac/Kit/`：模块接口 + 内置模块 + SwiftUI 设置页 + SwiftUI 侧边栏（两端共用层的雏形）。
- AppKit 壳：窗口 / 工具栏 / 侧边栏 / 标签条 / 多标签 / 容器 / 按站点缩放 / 会话恢复 / ⌘点后台标签 / `window.open` / alert·confirm / 文件上传 / 菜单快捷键（⌘, ⌘N ⌘T ⌘L ⌘W ⇧⌘W ⇧⌘T ⌘R ⌘0 ⌘+ ⌘= ⌘- ⌃⌘S ⌃⌘F ⌘[ ⌘] ⇧⌘[ ⇧⌘] ⌘1…⌘9）。
- `macos/scripts/bundle.sh` → `Mio Preview.app`（`xyz.mio.mac.preview`，与 Catalyst 版并存），ad-hoc 签名。
- CI `mac-native` job：构建 + 冒烟（MSE 门槛、YouTube 格式记录、缩放、容器、模块、菜单、截图），不进 release。

## 4. 剩余工作量清单（Catalyst / UIKit → 新结构）

| 功能 | 现在 | v0.4.0 做法 | 估计 |
|---|---|---|---|
| WebView 层拆分 | `MioBrowser.swift`（1507 行）里 per-tab 安装一切 | `MioWebViewHost`（WebKit-only）：配置、容器数据存储、模块脚本 / 消息桥 / 内容规则挂载；iOS 标签控制器改用它 | 3–4 天 |
| 广告拦截 | `MioAdblockCore.swift` | 模块化（内容规则扩展）、SafariConverterLib 依赖进共享包、AdblockBundle 资源、后台更新（iOS BGTask / Mac `NSBackgroundActivityScheduler`） | 2 天 |
| 翻译 | `MioTranslate.swift`（710 行） | 模块 + 消息桥；设置项声明式，自动进「模块」分区 | 1.5 天 |
| 阅读 / 深色 / 存到 Mio | `MioPageTools.swift`（748 行） | 模块 + 阅读视图（第二个 WKWebView）+ SwiftUI 外观面板 | 2 天 |
| 媒体：PiP / 后台播放 / Now Playing / SponsorBlock | `MioMedia.swift`（399 行） | 模块 + 生命周期扩展；Mac：标准 `requestPictureInPicture()`、窗口后台不暂停、媒体键走 WebKit mediaSession，MPRemoteCommandCenter 兜底；iOS 行为不变 | 1.5 天 |
| 容器 UI | `MioContainerStore.swift`（410 行）+ `MioTabs` 菜单 | Store 的 WebKit 部分进 WebView 层；SwiftUI「容器」分区（改名 / 颜色 / 删除 / 站点规则）+ 标签右键菜单 | 1.5 天 |
| 用户脚本管理 | `MioUserScripts.swift`（1149 行） | 注入 + GM 桥进 WebView 层；SwiftUI 管理界面（列表 / 详情 / 编辑 / 更新 / `.user.js` 安装提示） | 3 天 |
| 设置页 | 各 `*SettingsViewController`（UIKit） | 已有 SwiftUI 骨架；逐个模块补设置项，iOS 设置页换成 `MioSettingsView` | 2 天 |
| 标签细节 | `MioTabs.swift`（1271 行） | Mac：拖动排序、右键菜单、锁定、标签概览；iPad：SwiftUI 侧边栏 + 现有标签条 | 2–3 天 |
| MioCore 模块 | `MioDesktop.swift`（555 行）、Capacitor | 主页 / 新标签页、存到 Mio、登录、同步、兼容桥；删 Capacitor | 2 天（同步另计） |
| 删掉的 | `MioYouTubeHD.swift`、`MioDesktopParity` 的 YouTube 旧 UA / Safari 兜底、`MioMacMetrics` 77% 换算、`MioActionList`、Catalyst 分支 | 原生 Mac 不需要 | -（减代码） |
| 更新器 | `MioUpdater.swift`（zip + SHA-256 + shell 替换） | 短期搬现有逻辑（`MioUpdateCore` 复用）；推荐 Sparkle 2（EdDSA appcast） | 1–2 天 |
| 签名 / 公证 / 分发 | ad-hoc zip / dmg | 见第 5 节 | 视账号 |

**合计约 4–5 周**单人（不含真机回归、同步功能）。复用纯逻辑 + JS 约 5,000 行；重写宿主约 4,000 行，其中约 1,000 行直接删除。

## 5. 签名、公证、分发
- 有 Apple Developer Program：Developer ID + Hardened Runtime + `notarytool` 公证 + staple；Sparkle 2 自动更新（EdDSA 私钥只放 CI secret）。**推荐**。
- 没有：继续 ad-hoc，首次「右键 → 打开」；现有 shell 替换式更新器可用。
- Mac App Store：需 App Sandbox，浏览器 + 广告拦截 + 用户脚本审核不确定，不作首发渠道。
- bundle id：预览 `xyz.mio.mac.preview`；正式版改回 `xyz.mio.app`，`mio.*` 设置与固定 UUID 数据存储有机会沿用——**需真机验证** Catalyst 与 AppKit 的 WebKit 数据目录是否一致，不一致则首启提示重新登录。更新器 bundle id 校验要允许 Catalyst → 原生 的一次切换。
- iOS 分发不变（SideStore / AltStore 源）。

## 6. v0.4.0 PR 拆分顺序（建 `release/0.4.0`，从 v0.3.4 发版后的 main 切出）

1. **CI 瘦身**：从 `build.yml` 删除 `android`、`android-emulator`、`windows` job 和 release 依赖；`android/`、`desktop/`、`native/mioadblock`（只给 Android 用）目录删除或移到 `archive/`（历史与 v0.3.4 tag 保留）；README 改成 Apple-only。先做，后面每个 PR 的 CI 都更快。
2. **共享层落位**：Foundation-only 核心从 `ios/App/App/` 移到 `apple/Shared/`（本地 Swift Package `MioKit`，需要 `public`），`Kit/`（模块接口、SwiftUI 设置 / 侧边栏）一并进去；iOS 工程、`tools/MioAppTests`、Mac target 都引用它（一次性 pbxproj 改动，等 `v034-mobile-layout` 合并后做）。
3. **原生 Mac target 入库**（本 PR 转正）：把 `macos/` 从 SwiftPM 可执行文件换成正式 macOS app target（同一 `App.xcodeproj` 新 target 或 XcodeGen），资源 / entitlements / Info.plist；CI `mac-native` 冒烟保留并成为 Mac 门槛。
4. **WebView 层 + 模块注册表接入 iOS**：`MioWebViewHost`；iOS 标签控制器改为从注册表装脚本；现有功能逐个以模块形式接入（先 YouTube 防沉迷 / WebRTC / 通行密钥 / 后台可见性），iOS 行为不变（iOS 冒烟 + 单测守住）。
5. **模块迁移（可并行，每个一个 PR）**：广告拦截 → 翻译 → 阅读 / 深色 / 存到 Mio → 媒体（SponsorBlock、PiP、Now Playing）。每个 PR 同时让 iOS 和 Mac 生效。
6. **SwiftUI 设置页替换**：iOS 设置页换成 `MioSettingsView`（Safari 分区 + Mio 分区），删掉各 `*SettingsViewController`；容器 / 用户脚本管理界面 SwiftUI 化。
7. **浏览器为本体 + MioCore 模块化**：App 启动进浏览器；MioCore 成为主页 / 新标签页模块 + 兼容桥；删除 `MioDesktop.swift` 根控制器和 Capacitor（`CapApp-SPM`、`capacitor.config.json`、`www/` 里只为 Capacitor 的部分）。
8. **iPad Safari macOS 式布局**：SwiftUI 侧边栏 + `UISplitViewController`，工具栏对齐 Mac；iPhone 布局保持。
9. **Mac 补齐**：标签拖动 / 右键菜单 / 概览、下载（`WKDownload`）、PiP / 媒体键真机验证；删除 YouTube 旧 UA / Safari 高清兜底、`MioYouTubeHD`、`MioMacMetrics`、`MioActionList`。
10. **分发切换**：Sparkle 2（或搬现有更新器）、Developer ID 签名 + 公证（若有账号）、bundle id 切回 `xyz.mio.app` + 数据迁移；release job 发布原生 Mac 包；删除 Catalyst 构建（`mac` job、`#if targetEnvironment(macCatalyst)` 分支）。
11. **v0.4.0 集成 + 发版**（集成负责人：版本号、release notes、tag）。

依赖关系：1 → 2 → 3/4（可并行）→ 5（并行）→ 6/7/8/9（可并行）→ 10 → 11。
