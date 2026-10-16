import UIKit
import Capacitor

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        // 只在这里建窗口和根控制器（Info.plist 不再声明 UISceneStoryboardFile，避免 storyboard 再建一个 bridge）。
        // 根控制器用 MioBridgeViewController：启动遮罩 + 导航错误过滤（v0.1.1 写了但这里用的是 CAPBridgeViewController，没生效）
        let window = UIWindow(windowScene: windowScene)
        window.backgroundColor = MioShellTheme.background
        window.rootViewController = MioBridgeViewController()
        self.window = window
        window.makeKeyAndVisible()

        SceneDelegateProxy.shared.scene(scene, willConnectTo: session, options: connectionOptions)
    }

    // 使用 UIScene 生命周期时 AppDelegate 的 applicationDidBecomeActive / DidEnterBackground 不会被调用
    func sceneDidBecomeActive(_ scene: UIScene) {
        // 长时间挂在后台后回到前台：超过 24 小时就检查规则更新
        if MioAdblock.shared.needsUpdateCheck && MioAdblock.shared.snapshot.busy == nil {
            MioAdblock.shared.checkForUpdates(force: false)
        }
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        MioAdblockBackground.schedule()
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        SceneDelegateProxy.shared.scene(scene, openURLContexts: URLContexts)
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        SceneDelegateProxy.shared.scene(scene, continue: userActivity)
    }
}
