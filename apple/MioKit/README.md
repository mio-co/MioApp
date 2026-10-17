# MioKit

Mio v0.4.0 的共享 Swift package：**A（iOS / iPadOS，`apple/ios` firefox-ios fork）** 和 **B（Mac 原生壳，`macos/`）** 共用的浏览器逻辑。
不依赖 UIKit / AppKit；WebKit 部分在 `#if canImport(WebKit)` 里，纯逻辑在 Linux 上也能 `swift test`。
界面各端自己画：MioKit 只给数据模型和动作。

- 平台：iOS 15+ / macOS 12+（容器的多数据存储需要 iOS 17 / macOS 14，旧系统自动退回只有默认容器）
- 依赖：AdGuard SafariConverterLib 4.3.1（只在 Apple 平台链接，GPL-3.0，与 v0.3.x 同版本）
- 设置：沿用 v0.3.x 的 UserDefaults key（升级不丢设置），新 key 用 `mio.kit.*` / `mio.core.*` / `mio.bridge.*` / `mio.userscripts.*` 前缀

```
Sources/MioKit/
  Core/            v0.3.x 的 Foundation 纯逻辑（从 ios/App/App 复制，加了 public）：用户脚本解析/匹配/运行时、容器状态、翻译、阅读/深色、
                   媒体脚本（SponsorBlock）、YouTube 防沉迷、WebRTC 防护、标签；MioKitSupport（资源、钥匙串、SHA-256、UA）
  Settings/        MioPrefs（UserDefaults / 内存）、MioExtensionSettingsModel（设置页数据模型）
  Modules/         MioModule 协议 + 注册表、内置模块、MioKitContainer（一站式组装）
  ContentBlocking/ 规则转换（AdGuard / 内置子集）、超 15 万条拆分、订阅下载与缓存、广告拦截模块
  UserScripts/     用户脚本引擎（安装/更新/启停/GM 值）、用户脚本模块
  Bridge/          MioCore 本机桥（来源校验、API v1、权限）、mio://home 模型
  Containers/      容器管理（状态持久化、数据存储 ID 映射、预置 个人/工作/购物/银行、图标）、容器模块、
                   MioContainerTabPolicy（新 web view 进哪个容器：恢复 / 菜单指定 / 弹窗继承 / 父标签继承 / 站点规则）
  WebKit/          WebKit 适配：MioWebViewModules、MioCoreBridgeHandler、MioSchemeHandler、MioContentBlocker、
                   MioContainerDataStores、MioUserScriptBridge、MioSaveRunner
  Resources/       js/（reader、dark、mio-save、mio-translate）、filters/（mio-basic 内置精简列表、mio-youtube）
```

## 接入

### A：iOS fork（Xcode 工程）

1. `Client.xcodeproj` → Package Dependencies → Add Local… → 选 `apple/MioKit`（相对路径，提交工程文件即可）。
2. Client target 链接 `MioKit`。构建命令加 `-skipPackagePluginValidation`（SafariConverterLib 带一个生成版本号的构建插件）。

### B：Mac 原生壳（SwiftPM）

```swift
// macos/Package.swift
dependencies: [.package(path: "../apple/MioKit")],
targets: [.executableTarget(name: "MioMac", dependencies: [.product(name: "MioKit", package: "MioKit")])]
```

`macos/Sources/MioMac/Kit/MioModule*.swift`、`Shared/` 的符号链接可以删掉，改为 `import MioKit`（接口同名：`MioModule`、`MioModuleRegistry`、`MioSettingsSection`、`MioPrefs`、`MioMemoryPrefs`……，差别见下面「与 feat/mac-native 草稿的差异」）。

## 一次性组装（App 启动）

```swift
import MioKit

let kit = MioKitContainer(appVersion: "0.4.0")      // UserDefaults.standard + 默认目录
let blocker = MioContentBlocker(manager: kit.filters)
kit.adblock.recompile = { await blocker.reload() }
Task { await blocker.prepare() }                    // 先加载已编译规则（秒开），需要时编译；每天检查一次订阅
let dataStores = MioContainerDataStores(manager: kit.containers)   // iOS fork：defaultStore: { .default() }（默认容器沿用 Firefox 的存储）
kit.containers.seedPresetsIfNeeded()                                 // 首次启动建 个人 / 工作 / 购物 / 银行（已有自建容器则跳过）
kit.bridge.delegate = myBridgeHost                  // MioCoreBridgeDelegate
kit.media.onMediaState = { state in /* iOS: MPNowPlayingInfoCenter 兜底（页面没有 mediaSession 时） */ }
```

## 每个 WebView（标签）

```swift
let config = WKWebViewConfiguration()
config.websiteDataStore = dataStores.dataStore(for: tab.containerID)          // 容器隔离；"private" = 无痕
config.setURLSchemeHandler(MioSchemeHandler(kit: kit), forURLScheme: "mio")  // mio://home / offline / about
let mods = MioWebViewModules(kit: kit, controller: config.userContentController, blocker: blocker)
mods.hostScripts = myOwnUserScripts       // 宿主自己的 WKUserScript（重装时一起装回）
mods.userScriptBridge.host = myUserScriptHost                              // MioUserScriptHost（GM_openInTab / 剪贴板 / @connect 询问）
mods.install()                            // 装全部启用模块的脚本 + 消息通道 + MioCore 桥
let webView = WKWebView(frame: .zero, configuration: config)
mods.webView = webView                    // 同时交给 userScriptBridge
```

| 时机 | 宿主调用 |
|---|---|
| 主框架导航开始（`decidePolicyFor` 主框架 / `didStartProvisionalNavigation`） | `mods.willNavigateMainFrame(to: url)`（按广告拦截白名单挂 / 卸 WKContentRuleList；GM 值变了自动重装脚本） |
| 收到 `.mioSettingsDidChange`（名字同 v0.3.x `mio.browser.settingsDidChange`） | 对每个标签 `mods.install()`（对之后加载的页面生效） |
| 收到 `.mioContentRulesDidChange`（规则编译完成） | 对每个标签 `mods.applyContentRules(topURL: webView.url)` |
| MioCore 打不开（`didFailProvisionalNavigation`，目标是 MioCore） | `webView.load(URLRequest(url: kit.home.offlineURL(failed: url)))` |
| 关闭标签 | `mods.detach()` |
| 进入后台 | `kit.translate.cache.flush()` |

## 地址栏 / 主页 / 新标签页

- 新标签页 / 主页：`kit.home.newTabURL`（默认 `mio://home`；v0.3.x 用户在 `mio.tabs.newTabURL` 设过别的网站则沿用）。
- `mio://home` 由 `MioSchemeHandler` 返回一个小页面，立即 `location.replace` 到 MioCore 首页（默认 `https://mio.300031.xyz/mio/nav`，不留历史）。
  不用 iframe 嵌：WebKit 会把 iframe 里的 MioCore 当第三方，登录 Cookie 被 ITP 拦。
- 地址栏显示：`kit.home.addressBarText(for: url)` → 主页（`mio://home` 或 MioCore 首页）返回 `"Mio"`；其他 `mio://` 返回原样；普通网页返回 nil（照常显示）。
- 设置：`mio.core.origin`（MioCore 地址，默认 `https://mio.300031.xyz`，只收 https，本机调试允许 http://localhost）、`mio.core.homePath`（默认 `/mio/nav`）。

## Cloudflare Access（MioCore 在 Access 后面）

MioCore 站点（默认 `https://mio.300031.xyz`）可以挡在 Cloudflare Access 后面：`mio://home` → `/mio/nav` → 302 到
`https://<team>.cloudflareaccess.com/cdn-cgi/access/login/…&redirect_url=%2Fmio%2Fnav` → 身份提供商（Google / GitHub OAuth 或一次性验证码邮件）
→ `/cdn-cgi/access/authorized` → 回到 `/mio/nav`。全部在当前标签内完成。`MioAccessAuth`（纯逻辑）+ `MioAccessCookieVault`（WebKit）：

| 宿主时机 | 调用 |
|---|---|
| `decidePolicyFor`（主框架 http/https） | `MioAccessAuth.isAuthFlowURL(url, prefs:)` → 在当前 WebView 放行，不走通用链接 / 外部 App；iOS 另外按 `needsSafariUserAgent` / 宿主的 auth UA 换 Safari UA |
| `createWebViewWith` | `popupDisposition(opener: webView.url, target: request.url, prefs:) == .openerTab` → `webView.load(request)`，返回 nil（不开弹窗标签） |
| 主框架 `didFinish`（默认容器） | `vault.didFinishMainFrame(url)`：回到 MioCore → 备份 Access Cookie 到钥匙串；`/cdn-cgi/access/logout` → 清空 |
| App 启动 | `await vault.restore()`（补回没落盘的 Access Cookie）；Mac 另外 `migrateOnce(from: .default())`（v0.3.x Catalyst 主界面的登录态） |
| 进入后台 / 失去焦点 | `await vault.backUp()` |
| CI 冒烟 | `MioAccessAuth.homeStatus(landedOn:home:)` → `"ok"` / `"access-login"`（没登录，不算失败）/ `"other"` |

- 广告拦截：Access / 身份提供商页面不挂内容规则（`MioAdblockModule.shouldApplyContentRules`）。
- 备份只收 `CF_Authorization` / `CF_Binding` / `CF_AppSession` / `CF_Session` / `CF_Device`，只限 MioCore 主机和 `*.cloudflareaccess.com`，
  只收带过期时间的；钥匙串不可用时不退回 UserDefaults（`MioKeychainSecretStore.keychainOnlyNames`）。

## 菜单 / 分享 / 动作

```swift
let page = MioPageContext(url: webView.url, title: webView.title ?? "", containerID: tab.containerID)
for item in kit.registry.menuItems(page: page) { /* item.placement == .pageMenu → 「…」菜单；.share → 分享菜单；item.checked → 勾选 */ }
let rest = await mods.perform(item, page: page)   // WebKit 能做的（evaluateJavaScript / runScript + 结果回调）已执行
switch rest {
case .openURL(let url, let newTab): …
case .openSettings(let section): …                 // 打开设置到某分区
case .reload: mods.install(); webView.reload()
case .host(.showReader(let articleJSON)): …        // reader.js 提取结果：{ url, title, article, page }，page 是阅读视图 HTML
case .host(.saveToMio(let kind, let payloadJSON)): // 交给 MioSaveRunner（默认容器的数据存储 = 已登录 MioCore）
    let r = await saveRunner.save(kind: kind, payloadJSON: payloadJSON); toast(MioSaveKind.message(for: r).text)
case .host(.reopenInContainer(let id)): …
case .host(.installUserScript(let url)): let pkg = try await MioUserScriptInstaller.prepare(url: url); /* 确认界面 */ kit.userScripts.install(pkg)
case .host(.toast(let s)): …
default: break
}
```

内置菜单项：打开 Mio 主页、保存到 Mio / 存为笔记 / 在另一台设备继续（MioCore）、翻译此页 / 显示原文 / 总是翻译此网站、阅读视图、在此网站强制深色、
在此网站允许 WebRTC、在此网站关闭拦截、在容器中重新打开 / 总在此容器打开、安装此用户脚本、YouTube 防沉迷设置。

## 设置页（「Mio 扩展」）

```swift
let model = kit.settingsModel
for group in model.groups() {              // 每个模块一组；或 groups(in: .privacy) 只取某分区
    // group.title / summary / symbol / enabled
    for row in group.rows {                // 第一行（若有）是模块总开关 role == .moduleToggle；模块关掉时只有这一行
        switch row.setting.kind {
        case .toggle: Toggle(row.setting.title, isOn: row.value.boolValue)       → model.apply(row, .bool(new))
        case .choice(let options, _): Picker(options.map { $0.label })            → model.apply(row, option.value)
        case .text(_, let placeholder, let secure): TextField / SecureField       → model.apply(row, .string(new))
        case .stringList(let placeholder): 可增删列表                              → model.apply(row, .strings(list))
        case .action(let title): Button(title) { Task { toast(await model.trigger(row)) } }
        case .info: Text(row.detail)
        }
        // row.setting.footer：分组脚注
    }
}
```
`apply` 校验类型 / 选项后写 prefs 并发 `.mioSettingsDidChange`；`visibleWhen` 条件变化后重新取 `groups()` 即可。
例外：翻译 API Key 是 `.text(secure: true)`，宿主调用 `kit.translate.setAPIKey(_:)` 存钥匙串（不要用 `apply` 写进 UserDefaults）。

分区（`MioSettingsSection`）：通用 · 标签页 · 自动填充 · 搜索 · 隐私与安全 · 网站设置 · 高级（Firefox / Safari 式）+ Mio 扩展 · 容器 · 用户脚本 · MioCore。

## 模块一览

| id | 模块 | 分区 | 开关 key | 主要设置 | 原生通道 |
|---|---|---|---|---|---|
| `miocore` | MioCore（主页、保存到 Mio） | MioCore | 常开 | `mio.core.origin`、`mio.core.homePath`、`mio.save.category` | 桥 `mio`（见下） |
| `adblock` | 广告 / 跟踪拦截 | 隐私与安全 | `mio.adblock.enabled` | `mio.adblock.allowlist`、`mio.adblock.list.<id>`、`mio.adblock.customLists`、立即更新 | 内容规则 |
| `webrtc` | WebRTC 防泄露 | 隐私与安全 | `mio.webrtc.enabled` | `mio.webrtc.allowlist` | — |
| `youtubeFocus` | YouTube 防沉迷 | Mio 扩展 | `mio.browser.youtubeFocus` | `…Interval`、`…Playables` | — |
| `media` | YouTube 媒体增强 | Mio 扩展 | `mio.kit.module.media.enabled` | `mio.browser.backgroundPlayback`、`mio.media.pipButton`、`mio.media.nowPlaying` | `mioMedia`（sbFetch / state） |
| `sponsorBlock` | SponsorBlock | Mio 扩展 | `mio.media.sponsorBlock` | `mio.media.sb.<分类>` | （在 media 脚本里） |
| `translate` | 翻译 | Mio 扩展 | `mio.kit.module.translate.enabled` | `mio.translate.*`、API Key（钥匙串） | `mioTranslate`（token 校验） |
| `pageTools` | 阅读 / 强制深色 | Mio 扩展 | `mio.kit.module.pageTools.enabled` | `mio.dark.global`、`mio.dark.sites`、`mio.reader.*` | `mioDark`（world `mio-dark`） |
| `userScripts` | 用户脚本 | 用户脚本 | `mio.userscripts.enabled` | 检查全部更新 | `mioUserScript`（每脚本 world） |
| `containers` | 容器 | 容器 | `mio.kit.module.containers.enabled` | 状态 `mio.containers.state` | — |

v0.3.x 没有总开关的功能（媒体、翻译、阅读/深色、用户脚本、容器）新 key 默认开 = 行为不变。
注入顺序 = 注册顺序（YouTube 防沉迷在媒体脚本之前，见 `MioMediaScripts` 注释）。

### 扩展协议

```swift
protocol MioModule: AnyObject            // id/title/summary/symbol/section/enabledKey/defaultEnabled/settings/scripts/menuItems/perform/
                                          // handleScriptResult/performSettingAction/settingStatus（除 id 等外都有默认实现）
protocol MioModuleMessageHandling        // messageEndpoints(prefs:) + handle(_ MioScriptMessage) async -> MioScriptReply
protocol MioModuleContentRules           // shouldApplyContentRules(topURL:prefs:)
```
新模块：实现协议 → `kit.registry.register(myModule)`（同 id 不覆盖内置）。

## 广告拦截

- 内置（离线可用，不可关）：`mio-basic`（Mio 精简：常见广告网络与统计）、`mio-youtube`（v0.3.x 的 YouTube 补充）。
- 订阅（默认全开，与 v0.3.x 相同）：AdGuard Base / 移动广告 / 跟踪保护 / EasyList / EasyPrivacy / AdGuard 中文（`filters.adtidy.org/ios/filters/<id>_optimized.txt`）；
  可选：EasyList China（默认关，已包含在 AdGuard 中文里）。自定义订阅：`mio.adblock.customLists`（https，EasyList / AdGuard 语法）。
- 拆行：列表是 CRLF，一律用 `MioFilterText.lines`（按 UTF-8 字节拆）。**不要用 `split(whereSeparator: { $0 == "\n" })`**：Swift 把 "\r\n" 当一个 Character，
  v0.4.0 因此把每份订阅读成一行注释、编出 0 条规则（设置页只显示内置的约 46 条）。
- 下载：ETag / Last-Modified 条件请求，HTML（门户页）拒收；单个列表网络错误 / 5xx / 429 重试 2 次（2 s、6 s）；文件在 `Application Support/MioKit/ContentBlocking/lists/`，状态 `state.json`。
- 更新节奏（`MioFilterManager.nextCheckDate` + `MioContentBlocker`）：订阅缺失（首次启动 / 刚打开开关）→ 立即下载；之后上次成功 + 24 小时；
  失败按 1 → 5 → 15 → 60 分钟退避（失败不再记成「已检查」）。检查时机：启动、回到前台（didBecomeActive）、运行中每 30 分钟、设置变化（`mio.adblock.*`）。
  所有下载 / 编译在 `MioContentBlocker` 里串行，后来的请求合并到下一轮（不丢）。设置页「立即更新」走 `manager.refreshHandler`。
- 转换：Apple 平台用 SafariConverterLib（`MioAdGuardFilterConverter`，参数同 v0.3.x）；Linux / 退路用 `MioBasicFilterConverter`（子集）。
  网络规则 + `##` 元素隐藏（`css-display-none`）进 WKContentRuleList；scriptlet（`#%#//scriptlet(...)`、`##+js(...)`）/ 扩展 CSS（`#?#`、`#$#`）/ JS 规则进高级规则。
- 高级规则（`MioAdvancedRules.swift`）：SafariConverterLib 的 FilterEngine 按页面地址查 → `MioAdvancedScript.build` 拼 JS（AdGuard Scriptlets 2.5.1 / ExtendedCss 2.3.0，
  `Resources/adguard/`，更新用 `scripts/update-adguard-assets.sh`）→ `MioWebViewModules` 注入 page world：主框架在 `willNavigateMainFrame` 预先查好、
  document-start 按主机名分发（比页面脚本早）；iframe / 没准备到的主框架在隔离世界 `mio-adblock` 发消息、原生 `evaluateJavaScript(in: frame)`。
- 拆分：单个 WKContentRuleList 上限 15 万条；超了把源规则对半拆（递归），**例外规则（@@ / #@#）每一片都保留**。每片标识 `mio.kit.<list>.<part>`。
- 缓存：按（列表文本 SHA-256 + `MioFilterManager.compileFormat`）；格式变了（v0.4.0 = 1，现在 2）旧的空表自动重编；关掉的列表 / 多余分片自动删。
- 状态：设置页「状态」= 已加载 N 条（内容规则 X · 高级 Y）· 跳过 M 条 · 上次更新 …；「各列表」逐个列出版本、条数、错误；「立即更新」按钮。
- 白名单站点 / Access 登录页：不挂规则、不注入（与 v0.3.x 相同做法，切换不需要重编）。
- 自检：`MioAdblockProbe`（CI 冒烟：>1 万条、请求被拦、## 隐藏、真实列表里的 set-constant 生效；adblock.turtlecute.org 打分 + 截图）。

## 用户脚本

- 兼容 `==UserScript==` 元数据：`@name @namespace @version @match @include @exclude @exclude-match @run-at @grant @require @resource @connect @noframes @updateURL @downloadURL`。
- GM API：`GM_getValue / setValue / deleteValue / listValues / xmlhttpRequest / addStyle / addElement / openInTab / setClipboard / registerMenuCommand / getResourceText / getResourceURL / notification / info`，以及 `GM.*` Promise 版。
- `@grant none` → 页面世界；否则每个脚本独立 `WKContentWorld`（`mio.userscript.<id>`），原生通道只注册在它自己的 world。
- `GM_xmlhttpRequest`：同源直接发；`@connect` 声明过的问用户（`MioUserScriptHost.userScriptAskConnect`，可记住）；没声明的拒绝。
- 安装：`MioUserScriptInstaller.prepare(url:)` / `prepare(code:sourceURL:)`（@require / @resource 全部下载成功才装，支持 `#sha256=` 校验）→ `kit.userScripts.install(pkg)`。
- 更新：`checkUpdate(_:)` / `updateAll(engine)`；启停 `setEnabled`；排序 `move`；删除 `delete`。
- 存储与 v0.3.x 相同（`Application Support/MioUserScripts/scripts.json` + `values/<id>.json`），升级后脚本和 GM 值都在。

## 容器

- `kit.containers`（`MioContainerManager`）：增删改、站点规则（「总在此容器打开」）、标签映射（会话恢复）、锁定继承；状态 key `mio.containers.state`（JSON 同 v0.3.x）。
- `MioContainerDataStores.dataStore(for:)`：容器 id → `WKWebsiteDataStore(forIdentifier:)`；默认容器 = v0.3.x 固定 UUID `6D696F00-6272-6F77-7365-720000000001`（登录不丢）；`private` = 不落盘。
- 删除：`try kit.containers.remove(id)` → 发 `.mioContainerWillRemove`（宿主关掉这些标签）→ `await dataStores.purge(id)`。

## MioCore 本机桥（API v1）

只对 **MioCore 来源**（`mio.core.origin`，默认 `https://mio.300031.xyz`）和 **`mio://` 内置页**开放。校验看发消息 frame 的 `securityOrigin`：协议 + 主机 + 端口完全一致；不认子域名、http 降级、别的端口、iframe（含同源 iframe）、不透明来源。

```js
// 页面（MioCore）
const info = await window.Mio.call('getDeviceInfo')
// 等价于：
const r = await window.webkit.messageHandlers.mio.postMessage({ v: 1, id: '1', method: 'getDeviceInfo', params: {} })
// r = { v: 1, id: '1', ok: true, result: {…} } | { v: 1, id: '1', ok: false, error: { code, message } }
```

| 方法 | 参数 | 结果 | 权限 | 状态 |
|---|---|---|---|---|
| `ping` | — | `{ pong, api, apiVersions, methods }` | basic | ✅ |
| `getDeviceInfo` | — | `{ platform, model, osVersion, appVersion, appBuild, locale, api, apiVersions, permissions }` | basic | ✅ |
| `openTab` | `{ url, background? }`（http(s) / mio://） | `{ opened: true }` | tabs | ✅ |
| `saveToMio` | `{ kind: bookmark\|note\|clip, payload: { url, title, selection?, article? } }` | mio-save.js 的结果 | save | ✅（mio:// 页不可用） |
| `photos.list` / `photos.sync` | 待定 | | photos | TODO（not_implemented） |
| `device.control` | 待定 | | deviceControl | TODO |
| `files.pick` | 待定 | | files | TODO |

错误码：`forbidden`（来源不对）、`unsupported_version`、`unknown_method`、`bad_request`、`permission_denied`、`not_implemented`、`failed`。
权限：basic / tabs / save 默认给允许来源；photos / deviceControl / files 必须用户明确允许（`MioCoreBridgeDelegate.bridgeRequestPermission`，记在 `mio.bridge.grants`，按来源分开）。
版本：`v` 是主版本；新方法只加不改，改语义升 v；页面先 `ping` 看 `apiVersions`。
兼容：`window.MioDesktop.browser.open(url)`（v0.3.x MioCore 页面用的）→ `openTab`。

宿主实现 `MioCoreBridgeDelegate`：`bridgeDeviceInfo()`、`bridgeOpenTab(_:background:)`、`bridgeSaveToMio(kind:payload:)`（通常转给 `MioSaveRunner`）、`bridgeRequestPermission(_:origin:)`。

## 与 feat/mac-native 草稿（`macos/Sources/MioMac/Kit/MioModule.swift`）的差异

- 全部 `public`；`MioSettingsSection.modules` 改名 `.extensions`（标题「Mio 扩展」）。
- `MioModuleSetting.Kind.choice` 的选项是 `[MioChoiceOption]`（值 `MioPrefValue`：int / string），新增 `.stringList` / `.action` / `.info`、`secure` 文本、`visibleWhen`。
- `MioModuleScript.world` 类型 `MioScriptWorld`（`.page` / `.isolated(name)`）。
- `MioModuleAction` 新增 `.runScript(MioScriptCall)`（callAsyncJavaScript + 结果回模块）、`.host(MioHostCommand)`；`.evaluateJavaScript` 带 world。
- 新模块默认开关 key 前缀 `mio.kit.module.<id>.enabled`（草稿是 `mio.module.<id>.enabled`，草稿未发版，无需迁移）。
- `MioCoreModule` 的主页改为 `mio://home`；草稿的 `mio.tabs.newTabURL` 只用于迁移。

## 测试

```
cd apple/MioKit && swift test          # macOS：含 WebKit 测试；Linux：纯逻辑部分
```
- 纯逻辑：注册表 / 设置模型、内置模块与 v0.3.x key、桥来源校验与分发、mio:// 路由、规则转换 / 拆分 / 订阅缓存（假 HTTP + 假编译器）、用户脚本安装 / 完整性 / 更新、容器、
  以及从 `tools/MioAppTests` 复制来的 v0.3.x 核心单测。
- macOS WebKit（`MioWebKitTests`）：真实 `WKContentRuleListStore` 编译内置列表（AdGuard 转换器）、16 万条拆成两片并逐片编译、真实 `WKWebView` 里其他来源 / 子域名 / http 降级 / iframe 调桥被拒、MioCore 来源放行、`mio://about`。
- CI：`build.yml` 的 `miokit`（macOS：swift test + iOS 模拟器编译检查）和 `miokit-linux`。

## 剩余工作（TODO）

- 后台更新调度：iOS `BGAppRefreshTask`（App 不在前台时更新订阅；现在是启动 / 回到前台 / 运行中定时检查）。
- Scriptlets 运行库远程更新（v0.3.x 有，现在只用包内 2.5.1）。
- 相册同步、控制设备、文件：桥接口与权限已定义，方法实现 + 宿主授权界面待做。
- 阅读视图外观面板、容器 / 用户脚本管理界面：各端 UI（数据都在这里）。
- 翻译的「译为…」语言选择器、YouTube 双语开关的 UI 入口（设置已在模型里）。
- `Core/` 是从 `ios/App/App` 复制的；v0.3.x 代码冻结后以这里为准，`tools/MioAppTests` 的同名测试可在 A 接入后删除。

## 许可

- MioKit 代码随仓库（MioApp）许可发布；iOS 版基于 Mozilla firefox-ios（MPL-2.0），`mio://about` 写明来源与「与 Mozilla 无关」。
- SafariConverterLib：GPL-3.0（AdGuard）；SponsorBlock 数据：CC BY-NC-SA 4.0（sponsor.ajay.app）。见仓库 NOTICE。
