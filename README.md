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

## 已知限制

- WKWebView 不支持网页里的文件下载，快传取件下载可能无效（后续可加原生下载插件）。
- 不能后台运行，也不能自动读取相册。
