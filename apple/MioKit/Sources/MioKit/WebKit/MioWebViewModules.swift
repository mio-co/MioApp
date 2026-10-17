// MioWebViewModules.swift — WebKit 适配：把注册表里的模块装进一个 WKWebView（脚本、消息通道、内容规则、MioCore 桥、用户脚本 GM 通道），
// 并执行 MioModuleAction 里 WebKit 能直接做的部分。A（iOS Tab）和 B（Mac 标签）每个 WebView 一个实例。
//
//   let config = WKWebViewConfiguration()
//   config.websiteDataStore = dataStores.dataStore(for: containerID)
//   config.setURLSchemeHandler(MioSchemeHandler(kit: kit), forURLScheme: "mio")
//   let mods = MioWebViewModules(kit: kit, controller: config.userContentController, blocker: blocker)
//   mods.hostScripts = [...]          // 宿主自己的 WKUserScript（重装时一起装回去）
//   mods.install()                    // WebView 创建前
//   let wv = WKWebView(frame: .zero, configuration: config); mods.webView = wv
//   导航开始（主框架）：mods.willNavigateMainFrame(to: url)   → 内容规则按白名单增减；GM 值变了自动重装
//   收到 .mioSettingsDidChange：mods.install()（对之后加载的页面生效）
//   菜单动作：let rest = await mods.execute(action, page:)  → 返回宿主要处理的（openURL / openSettings / host / reload）

#if canImport(WebKit)
import Foundation
import WebKit

@MainActor
public final class MioWebViewModules: NSObject {
    public let kit: MioKitContainer
    public let controller: WKUserContentController
    public weak var webView: WKWebView? { didSet { userScriptBridge.webView = webView } }
    public weak var blocker: MioContentBlocker?
    /// 宿主自己的脚本（WKUserContentController 不能单独删脚本，重装时一起装回）
    public var hostScripts: [WKUserScript] = []
    public let bridgeHandler: MioCoreBridgeHandler
    public let userScriptBridge: MioUserScriptBridge
    private var endpoints: Set<MioMessageEndpoint> = []
    private var appliedLists: [String: WKContentRuleList] = [:]
    private var seenValuesVersion = 0

    public init(kit: MioKitContainer, controller: WKUserContentController, blocker: MioContentBlocker? = nil) {
        self.kit = kit
        self.controller = controller
        self.blocker = blocker
        bridgeHandler = MioCoreBridgeHandler(bridge: kit.bridge)
        userScriptBridge = MioUserScriptBridge(engine: kit.userScripts, controller: controller)
        super.init()
        seenValuesVersion = kit.userScripts.valuesVersion
        bridgeHandler.attach(to: controller)
    }

    /// 装（或重装）全部启用模块的脚本 + 消息通道。设置变化后调用；对之后加载的页面生效
    public func install() {
        controller.removeAllUserScripts()
        controller.addUserScript(bridgeHandler.shimUserScript())
        hostScripts.forEach(controller.addUserScript)
        for (_, s) in kit.registry.scripts() { controller.addUserScript(Self.userScript(s)) }
        syncEndpoints()
        userScriptBridge.sync(enabled: kit.registry.isEnabled(kit.userScriptsModule.id))
    }

    public func detach() {
        for e in endpoints { controller.removeScriptMessageHandler(forName: e.name, contentWorld: Self.world(e.world)) }
        endpoints = []
        userScriptBridge.detach()
        bridgeHandler.detach(from: controller)
        for (_, l) in appliedLists { controller.remove(l) }
        appliedLists = [:]
    }

    public static func userScript(_ s: MioModuleScript) -> WKUserScript {
        WKUserScript(source: s.source, injectionTime: s.injection == .documentStart ? .atDocumentStart : .atDocumentEnd,
                     forMainFrameOnly: s.mainFrameOnly, in: world(s.world))
    }

    public static func world(_ w: MioScriptWorld) -> WKContentWorld {
        switch w {
        case .page: return .page
        case .isolated(let n): return .world(name: n)
        }
    }

    private func syncEndpoints() {
        let want = Set(kit.registry.messageEndpoints().map { $0.endpoint })
        for e in endpoints.subtracting(want) { controller.removeScriptMessageHandler(forName: e.name, contentWorld: Self.world(e.world)) }
        for e in want.subtracting(endpoints) {
            controller.addScriptMessageHandler(MioModuleMessageProxy(self, endpoint: e), contentWorld: Self.world(e.world), name: e.name)
        }
        endpoints = want
    }

    /// 主框架即将导航：按白名单挂 / 卸内容规则；GM 值变过就重装脚本
    public func willNavigateMainFrame(to url: URL?) {
        applyContentRules(topURL: url)
        userScriptBridge.willNavigateMainFrame()
        if kit.userScripts.valuesVersion != seenValuesVersion {
            seenValuesVersion = kit.userScripts.valuesVersion
            install()
        }
    }

    public func applyContentRules(topURL: URL?) {
        let wanted: [String: WKContentRuleList] = kit.registry.contentRuleModules(topURL: topURL).isEmpty ? [:] : (blocker?.ruleLists ?? [:])
        for (id, l) in appliedLists where wanted[id] !== l { controller.remove(l); appliedLists[id] = nil }
        for (id, l) in wanted where appliedLists[id] == nil { controller.add(l); appliedLists[id] = l }
    }

    public var appliedRuleListIdentifiers: [String] { appliedLists.keys.sorted() }

    // MARK: 消息

    func handle(_ info: MioWKMessageInfo, endpoint: MioMessageEndpoint) async -> MioScriptReply {
        let m = MioScriptMessage(endpoint: endpoint, body: info.body, isMainFrame: info.isMainFrame,
                                 origin: info.origin ?? MioFrameOrigin(scheme: "about", host: ""), pageURL: info.url ?? webView?.url)
        return await kit.registry.handle(m)
    }

    // MARK: 动作

    /// 执行 WebKit 能直接做的动作（evaluateJavaScript / runScript，结果再交回模块）；其余原样返回给宿主
    public func execute(_ action: MioModuleAction, moduleID: String, page: MioPageContext) async -> MioModuleAction {
        switch action {
        case .evaluateJavaScript(let js, let w):
            guard let wv = webView else { return .none }
            _ = await Self.evaluate(wv, js, world: Self.world(w))
            return .none
        case .runScript(let call):
            guard let wv = webView else { return .none }
            let result = await Self.callAsync(wv, call.body, arguments: call.arguments, world: Self.world(call.world))
            guard let h = call.resultHandler else { return .none }
            let next = kit.registry.handleScriptResult(moduleID: moduleID, handler: h, result: result, page: page)
            return await execute(next, moduleID: moduleID, page: page)
        default:
            return action
        }
    }

    /// 菜单项：perform + execute
    public func perform(_ item: MioModuleMenuItem, page: MioPageContext) async -> MioModuleAction {
        await execute(kit.registry.perform(item, page: page), moduleID: item.moduleID, page: page)
    }

    /// evaluateJavaScript（completion 版本：结果为 undefined / 不支持的类型时不会崩，返回 nil）
    public static func evaluate(_ wv: WKWebView, _ js: String, world: WKContentWorld) async -> Any? {
        await withCheckedContinuation { c in
            wv.evaluateJavaScript(js, in: nil, in: world) { r in c.resume(returning: try? r.get()) }
        }
    }

    public static func callAsync(_ wv: WKWebView, _ body: String, arguments: [String: Any], world: WKContentWorld) async -> Any? {
        await withCheckedContinuation { c in
            wv.callAsyncJavaScript(body, arguments: arguments, in: nil, in: world) { r in c.resume(returning: try? r.get()) }
        }
    }
}

/// 从 WKScriptMessage 取出的纯值（在 WebKit 回调里立即取，之后切到 MainActor 处理；不跨线程传 WKScriptMessage）
struct MioWKMessageInfo {
    let body: Any
    let worldName: String?
    let isMainFrame: Bool
    let origin: MioFrameOrigin?
    let url: URL?

    init(_ message: WKScriptMessage) {
        body = message.body
        worldName = message.world.name
        isMainFrame = message.frameInfo.isMainFrame
        let o = message.frameInfo.securityOrigin
        origin = (o.host.isEmpty && o.protocol.lowercased() != "mio") ? nil : MioFrameOrigin(scheme: o.protocol, host: o.host, port: o.port)
        url = message.frameInfo.request.url
    }
}

/// WKUserContentController 强引用 handler：弱引用转发（普通 NSObject，不标 actor：兼容新旧 SDK 的 WebKit 隔离标注）
final class MioModuleMessageProxy: NSObject, WKScriptMessageHandlerWithReply {
    weak var owner: MioWebViewModules?
    let endpoint: MioMessageEndpoint
    init(_ owner: MioWebViewModules, endpoint: MioMessageEndpoint) { self.owner = owner; self.endpoint = endpoint }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        let info = MioWKMessageInfo(message)
        let e = endpoint
        Task { @MainActor [weak o = self.owner] in
            guard let owner = o else { replyHandler(nil, "browser closed"); return }
            switch await owner.handle(info, endpoint: e) {
            case .value(let v): replyHandler(v, nil)
            case .error(let s): replyHandler(nil, s)
            }
        }
    }
}
#endif
