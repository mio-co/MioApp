# MioApp

MioCore（https://mio.300031.xyz）的 iOS 壳 App，基于 Capacitor 8。

- App 直接加载线上站点，MioCore 部署新版后 App 自动生效，无需重新打包。
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

## 已知限制

- WKWebView 不支持网页里的文件下载，快传取件下载可能无效（后续可加原生下载插件）。
- 不能后台运行，也不能自动读取相册。
