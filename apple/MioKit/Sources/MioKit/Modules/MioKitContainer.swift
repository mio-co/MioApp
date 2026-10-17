// MioKitContainer.swift — 一站式组装：设置存储 + 全部内置模块 + 注册表 + 各管理器。A（iOS）和 B（Mac）各建一个，App 生命周期内共享。
//
//   let kit = MioKitContainer()                       // UserDefaults.standard + 默认目录
//   kit.registry.scripts() / menuItems(page:) / perform(...)
//   kit.settingsModel.groups()                        // 「Mio 扩展」设置页数据
//   kit.bridge.delegate = self                        // MioCore 本机桥
//   kit.home.newTabURL                                // mio://home（或 v0.3.x 自定义的新标签页）

import Foundation

public final class MioKitContainer {
    public let prefs: MioPrefs
    public let registry: MioModuleRegistry
    public let settingsModel: MioExtensionSettingsModel
    public let filters: MioFilterManager
    public let userScripts: MioUserScriptEngine
    public let containers: MioContainerManager
    public let bridge: MioCoreBridge
    public var home: MioHomeModel { MioHomeModel(prefs: prefs, appVersion: appVersion) }
    public var appVersion: String { didSet { userScripts.appVersion = appVersion } }

    // 内置模块（按设置页顺序注册）
    public let mioCore = MioCoreModule()
    public let adblock: MioAdblockModule
    public let webRTC = MioWebRTCModule()
    public let youtubeFocus = MioYouTubeFocusModule()
    public let media = MioMediaModule()
    public let sponsorBlock = MioSponsorBlockModule()
    public let translate: MioTranslateModule
    public let pageTools = MioPageToolsModule()
    public let userScriptsModule: MioUserScriptsModule
    public let containersModule: MioContainersModule

    public init(prefs: MioPrefs = UserDefaults.standard,
                appVersion: String = MioKitInfo.version,
                filterDirectory: URL = MioFilterManager.defaultDirectory(),
                userScriptDirectory: URL = MioUserScriptEngine.defaultDirectory(),
                secrets: MioSecretStore = MioKeychainSecretStore.shared,
                translateCache: MioTranslateCache = MioTranslateCache()) {
        self.prefs = prefs
        self.appVersion = appVersion
        filters = MioFilterManager(directory: filterDirectory, prefs: prefs)
        userScripts = MioUserScriptEngine(directory: userScriptDirectory, appVersion: appVersion)
        containers = MioContainerManager(prefs: prefs)
        bridge = MioCoreBridge(prefs: prefs)
        adblock = MioAdblockModule(manager: filters)
        translate = MioTranslateModule(secrets: secrets, cache: translateCache)
        userScriptsModule = MioUserScriptsModule(engine: userScripts)
        containersModule = MioContainersModule(manager: containers)
        // 注入顺序 = 注册顺序：YouTube 防沉迷要在媒体脚本之前（它在 window 捕获阶段的可见性监听先注册，见 MioMediaScripts 注释）
        registry = MioModuleRegistry(prefs: prefs, modules: [
            mioCore, adblock, webRTC, youtubeFocus, media, sponsorBlock, translate, pageTools, userScriptsModule, containersModule,
        ])
        settingsModel = MioExtensionSettingsModel(registry: registry)
    }
}
