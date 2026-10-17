# Mac：Mac Catalyst → 原生 macOS（AppKit + WKWebView）迁移评估

状态：可行性验证 + 骨架（`feat/mac-native`，draft PR，不发版）。目标：Apple 端（iPhone / iPad / Mac）只用一个 WebKit 引擎，一套 Swift 代码。
Windows（Electron）和 Android（Capacitor）不再开发。

## 1. 为什么要迁

| | Mac Catalyst（现在） | 原生 AppKit（本分支） |
|---|---|---|
| WebKit 配置 | iOS 版配置（Catalyst 进程编译时就没有 MSE） | 与 Safari 相同 |
| `typeof MediaSource` / `ManagedMediaSource` | `undefined` / `undefined`（私有偏好 `_setMediaSourceEnabled:` 设成 true 也没用，见 `MioBrowser.swift` `enableMediaSource` 注释） | `function` / `function`（CI 证据见 PR） |
| YouTube 桌面 UA | 只有渐进式 mp4 → 360p；靠 v0.3.0 移动 UA 拿 HLS（`MioYouTubeCompat.legacyMacUserAgent`）+「在 Safari 中看高清」兜底 | DASH/MSE，与 Safari 同样的清晰度（登录 / 机房 IP 限制除外） |
| 界面 | iPad idiom 整窗 77% 缩放，工具栏 / 缩放都要换算（`MioMacMetrics`） | 1:1，`pageZoom` 直接 = Safari 档位 |
| 原生控件 | UIKit 仿 Mac（actionSheet 变横排，要 `MioActionList` 兜底） | NSToolbar / NSMenu / NSPopover 原生 |

## 2. 骨架做了什么（`macos/`）

- **SwiftPM 可执行 target `MioMac`**，最低 macOS 14（`WKWebsiteDataStore(forIdentifier:)` 做容器）。不改 `App.xcodeproj`，零 pbxproj 冲突。
- **共享核心**：`macos/Sources/MioMac/Shared/*.swift` 是指向 `ios/App/App/` 的符号链接（与 `tools/MioAppTests` 同一手法），iOS target 编译原文件、Mac 编译同一份：
  `MioTabsCore`、`MioContainerCore`、`MioDesktopParityCore`（缩放档位 / 站点表）、`MioWebCompat`（UA、YouTube 防沉迷脚本等）、`MioWebRTCGuard`（纯逻辑 + 脚本）、
  `MioUserScriptCore`、`MioTranslateCore`、`MioReaderCore`、`MioMediaScripts`、`MioUpdateCore`、`MioCloseAfterExternal`。
- **AppKit 壳**（新文件，约 900 行）：
  - `MioMacBrowserWindow.swift`：统一工具栏（后退 / 前进 / 居中地址栏 / 新标签 / … 菜单），工具栏下标签条，多标签（`MioTabStore`），⌘点链接后台打开，
    `window.open` → 新标签，`alert / confirm / <input type=file>`，按站点缩放（`mio.zoom.sites`，与 Catalyst 同 key、同档位），会话恢复（只建当前标签的 WebView）。
  - `MioMacWebKit.swift`：容器 → `WKWebsiteDataStore(forIdentifier:)`（默认容器用与 iOS 相同的固定 UUID），桌面 Safari UA，注入 YouTube 防沉迷 + WebRTC 防泄露（读 iOS 同名设置 key）。
  - `MioMacApp.swift`：主菜单 + 快捷键 ⌘N ⌘T ⌘L ⌘W ⇧⌘W ⇧⌘T ⌘R ⌘0 ⌘+ ⌘= ⌘- ⌃⌘F ⌘[ ⌘] ⇧⌘[ ⇧⌘] ⌘1…⌘9。
  - `MioMacAddressInput.swift`：地址栏输入规则（纯 Foundation，`tools/MioAppTests` 里单测）。
  - `MioMacSmoke.swift`：CI 冒烟（见 PR 描述）。
- **打包**：`macos/scripts/bundle.sh` → `Mio Preview.app`（bundle id `xyz.mio.mac.preview`，与现有 Catalyst 版 `xyz.mio.app` 并存），ad-hoc 签名。
- **CI**：`build.yml` 新增 `mac-native` job（不进 release 的 needs）。

## 3. 剩余迁移工作量（Catalyst / UIKit → AppKit 要重写的部分）

行数 = 现有 UIKit 文件规模，供估算参考。「复用」= 纯逻辑 / JS 不动，只重写宿主。

| 功能 | 现在在哪 | macOS 上怎么做 | 估计 |
|---|---|---|---|
| **广告拦截**（AdGuard 规则 → WKContentRuleList、Scriptlets、ExtendedCss、后台更新） | `MioAdblockCore.swift`（1013 行，已不依赖 UIKit；`tools/AdblockCheck` 已在 macOS 原生编译） | 直接链接：Package.swift 加 SafariConverterLib 依赖 + 资源打包（AdblockBundle）；后台刷新从 BGTaskScheduler 改成 `NSBackgroundActivityScheduler` | 1–2 天 |
| **内置浏览器其余挂钩**（回车兜底不需要；通行密钥提示、后台可见性伪造、站点权限、下载） | `MioBrowser.swift`（1507 行，UIKit） | 拆出 WebView 级「功能安装器」（脚本 / 消息处理器 / 内容规则）为平台无关文件，iOS 与 Mac 的 tab 控制器都调用；下载用 `WKDownload` + NSSavePanel | 3–4 天 |
| **画中画** | iOS：`AVPictureInPictureController` 系统行为 + 页面 PiP 按钮（`MioMedia.swift` 399 行） | macOS WKWebView 支持标准 `requestPictureInPicture()` / `webkitSetPresentationMode('picture-in-picture')`，页面按钮脚本（MioMediaScripts）直接复用；需真机验证 YouTube 上的按钮 | 0.5–1 天 |
| **后台播放 / Now Playing** | iOS：音频会话 + 可见性伪造 + `MPNowPlayingInfoCenter`/`MPRemoteCommandCenter` | macOS 窗口在后台不暂停媒体，可见性伪造只需在窗口最小化 / 标签切走时；媒体键：WebKit 自带 mediaSession → 控制中心；MPRemoteCommandCenter 在 macOS 也可用作兜底 | 1 天 |
| **阅读模式 UI / 强制深色 / 存到 Mio** | `MioPageTools.swift`（748 行 UIKit）；JS 在 `www/mio-browser/*.js`，逻辑在 `MioReaderCore` | JS / 逻辑复用；阅读视图用第二个 WKWebView 叠在标签上 + 地址栏按钮 + 外观 NSPopover | 2 天 |
| **翻译**（双语对照、划词、YouTube 双语字幕，原生代发请求，Key 存钥匙串） | `MioTranslate.swift`（710 行，桥是 WebKit、设置页是 UIKit） | 桥（`WKScriptMessageHandlerWithReply`、URLSession、Keychain）基本可原样搬；设置页改 SwiftUI；`mio-translate.js` 打进资源 | 1.5 天 |
| **容器 UI**（新建 / 改名 / 颜色 / 删除、站点规则、锁定标签） | `MioContainerStore.swift`（410 行，含删除重试）+ `MioTabs.swift` 菜单 | Store 的 WebKit 部分可复用（去掉 UIKit 通知即可）；UI 改 SwiftUI 设置页 + 标签右键菜单 | 1.5 天 |
| **用户脚本管理 UI**（安装 / 更新 / 编辑 / GM API / 每脚本 WKContentWorld） | `MioUserScripts.swift`（1149 行：注入 + 消息桥是 WebKit，管理界面是 UIKit） | 注入 + GM 桥拆成平台无关文件复用；管理 UI 用 SwiftUI（列表、详情、代码编辑用 NSTextView）；`.user.js` 拦截安装提示 | 3 天 |
| **标签概览 / 标签条细节**（拖动排序、右键菜单、锁定、关闭其他、固定 MioCore 标签） | `MioTabs.swift`（1271 行） | 骨架已有基础标签条；补拖动（NSDraggingSource）、右键菜单、概览（可后做） | 2 天 |
| **设置** | 各 `*SettingsViewController`（UITableViewController） | 一个 SwiftUI `Settings` 场景（⌘,），各功能一个 section；key 前缀不变（`mio.*`） | 2 天 |
| **MioCore 主界面 + `window.MioDesktop` 桥** | `MioDesktop.swift`（555 行） | 原生版可以「浏览器优先」：MioCore（/mio/nav）就是新标签页 / 固定标签，站外链接本来就在同一个浏览器里；保留 `window.MioDesktop.browser.open` 兼容（几十行） | 0.5–1 天 |
| **YouTube 高清兜底** | `MioDesktopParity.swift` 的旧 UA / Safari 按钮、`MioYouTubeHD.swift` 诊断 | **删除**（MSE 可用后不需要；保留「在 Safari 中打开」通用菜单项即可） | -（减代码） |
| **ActionList（actionSheet 替代）** | `MioActionList.swift` | 不需要，NSMenu / NSPopover 原生 | -（减代码） |
| **更新器** | `MioUpdater.swift`（Catalyst：下载 zip → SHA-256 → shell 脚本替换 .app） | 短期：同一套逻辑可搬到 AppKit（`MioUpdateCore` 复用，只换弹窗）；长期推荐 **Sparkle 2**（EdDSA 签名 appcast，增量更新，标准 UI） | 搬现有逻辑 1 天；Sparkle 1–2 天 |
| **签名 / 公证 / 分发** | 现在 ad-hoc 签名 zip / dmg，用户要右键打开 | 见第 4 节 | 取决于是否有 Developer ID |

**合计约 3–4 周**单人工作量（不含真机回归）。复用的纯逻辑 + JS 约 5,000 行，需要重写的 UIKit 宿主约 4,000 行，其中约 1,000 行（YouTube 兜底、ActionList、77% 换算）直接删除。

## 4. 签名、公证、分发

- **有 Apple Developer Program（$99/年）**：Developer ID Application 签名 + Hardened Runtime + `notarytool` 公证 + staple，dmg / zip 用户双击即可打开；Sparkle 2 自动更新（appcast 放 GitHub Releases / Pages，EdDSA 私钥只放 CI secret）。这是推荐路线。
- **没有付费账号**：继续 ad-hoc 签名，Gatekeeper 首次需要「右键 → 打开」或 `xattr -dr com.apple.quarantine`；现有 shell 替换式更新器可用（Sparkle 也能用，只是没有公证）。
- **Mac App Store**：需要 App Sandbox（容器数据目录、下载、用户脚本跨域请求要权限审查），审核对「浏览器 + 广告拦截 + 用户脚本」不确定，不推荐作为首发渠道。
- **bundle id**：预览版 `xyz.mio.mac.preview`。正式替换 Catalyst 时改回 `xyz.mio.app`，这样 UserDefaults（`mio.*` 设置、容器列表、缩放表）和 `WKWebsiteDataStore(forIdentifier:)` 的数据（默认容器用同一个固定 UUID）有机会直接沿用——**需要真机验证** Catalyst 与 AppKit 进程的 WebKit 数据目录是否一致；不一致时第一次启动做一次迁移提示（重新登录）。
- 更新器的 bundle id 校验（`mac-install-script.mjs`）要允许 Catalyst → 原生 的一次性切换。

## 5. 一套 Swift 代码的路线

1. **现在（本 PR）**：Mac 原生 target 通过符号链接编译与 iOS 相同的核心文件。iOS target 不变。
2. **共享包**：把 `ios/App/App/` 下的 Foundation-only 核心物理移动到 `Shared/`（或本地 Swift Package `MioKit`，需要给 API 加 `public`），iOS 工程引用它（一次性的 pbxproj 改动，等 `v034-mobile-layout` 合并后再做，避免冲突）。
3. **WebKit 层共享**：WKWebView 的配置、脚本注入、消息桥（广告拦截、用户脚本、翻译、媒体、阅读）从 `MioBrowserViewController` 中拆成 `MioWebViewFeatures`（只依赖 WebKit），iOS 与 Mac 的标签控制器都调用它。
4. **UI 层**：iOS 保持 UIKit；Mac 用 AppKit 壳 + SwiftUI 设置页。（可选：将来设置页 iOS 也改 SwiftUI，两端共用。）
5. **Xcode 工程**：发版前把 `macos/` 从 SwiftPM 可执行文件换成正式 macOS app target（或 XcodeGen 生成），以便资源目录、entitlements、Sparkle、Developer ID 签名。可以放在同一个 `App.xcodeproj`（新 target）或独立 `Mac.xcodeproj`。

## 6. 推荐 PR 拆分（都以 `release/0.4.0` 为 base）

1. **#1 本 PR**：可行性 + 骨架 + CI MSE 冒烟（draft）。
2. **#2 Shared 核心**：物理移动 Foundation-only 核心到 `Shared/`，iOS 工程、`tools/MioAppTests`、`macos/` 都引用同一位置。
3. **#3 广告拦截上 Mac 原生**：SafariConverterLib 依赖、AdblockBundle 资源、规则更新；CI 复用 `adblock-check` 的 YouTube 开 / 关对比。
4. **#4 WebView 功能层拆分**：`MioWebViewFeatures`（用户脚本、翻译桥、媒体脚本、阅读 / 深色 / 存到 Mio、WebRTC、通行密钥提示），iOS 行为不变（iOS 冒烟 + 单测守住）。
5. **#5 Mac 原生 UI 补齐**：SwiftUI 设置窗口、容器 / 用户脚本 / 翻译设置、阅读视图、标签条拖动 + 右键菜单、下载。
6. **#6 媒体**：PiP、后台 / 媒体键、YouTube 高清真机验证；删除 YouTube 旧 UA / Safari 高清兜底和 `MioYouTubeHD` 诊断。
7. **#7 分发**：正式 macOS app target、Sparkle 2（或搬现有更新器）、Developer ID 签名 + 公证（若有账号）、bundle id 切回 `xyz.mio.app` + 数据迁移、release job 改为发布原生 Mac 包。
8. **#8 清理**：移除 Catalyst 构建（`mac` job、`#if targetEnvironment(macCatalyst)` 分支、`MioDesktop*`、`MioMacMetrics`、`MioActionList`）、Windows / Android 目录与 CI job（用户已决定停止开发）。
