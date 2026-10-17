package xyz.mio.app.browser;

/**
 * 「跳转系统浏览器后自动关闭标签页」的判定（纯逻辑，无 Android 依赖，单测见 CloseAfterExternalTest）。
 *
 * Android 的「用系统浏览器打开」走 Intent.createChooser：startActivity 不抛异常只说明选择器弹出来了，
 * 用户还可能取消。所以：startActivity 成功 → 记下「待关闭」；浏览器真正盖住本页（onStop）才关闭；
 * 选择器取消回到本页（onResume）就清掉，不关闭。startActivity 抛异常（没有可用浏览器）不关闭。
 * 内置浏览器只有一个页面，关闭 = 与点 ✕ 一样 finish()，回到 Mio 主界面，App 不退出。
 */
public final class CloseAfterExternal {
    private boolean pending;

    /** startActivity 之后调用：launched = 没抛异常。返回是否进入待关闭。 */
    public boolean onLaunchResult(boolean enabled, boolean launched) {
        pending = enabled && launched;
        return pending;
    }

    /** 回到本页（选择器被取消 / 从外部浏览器切回）：不再关闭 */
    public void onResume() {
        pending = false;
    }

    /** 本页被外部浏览器盖住：返回是否应该关闭（一次性；旋转等配置变化不算） */
    public boolean onStop(boolean changingConfigurations) {
        if (changingConfigurations) return false;
        boolean close = pending;
        pending = false;
        return close;
    }

    public boolean isPending() {
        return pending;
    }
}
