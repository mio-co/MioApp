package xyz.mio.app.browser;

import android.content.Context;
import android.webkit.WebView;

import java.util.ArrayList;
import java.util.List;

/**
 * 标签容器（登录隔离）的接入点：feat/containers-core 实现 {@link Provider}（容器列表 + androidx.webkit Profile 绑定），
 * 在 Application / BrowserActivity 启动前 {@link #setProvider} 注册。未接入时只有默认容器，相关菜单不显示，
 * WebView 用浏览器进程的默认 Profile（与原来相同）。
 */
public final class TabContainers {
    private TabContainers() {}

    public static final class Info {
        public final String id;
        public final String name;
        public final int color;

        public Info(String id, String name, int color) {
            this.id = id;
            this.name = name;
            this.color = color;
        }
    }

    public interface Provider {
        /** 是否可用（WebViewFeature.MULTI_PROFILE） */
        boolean supported();
        /** 容器列表，含默认容器 */
        List<Info> list(Context c);
        /** 新建的 WebView 绑定容器的 Profile（在任何加载之前调用） */
        void bind(WebView webView, String containerId);
    }

    private static Provider provider;

    public static void setProvider(Provider p) { provider = p; }

    public static boolean supported() { return provider != null && provider.supported(); }

    public static List<Info> list(Context c) {
        if (provider == null) return new ArrayList<>();
        try {
            List<Info> l = provider.list(c);
            return l != null ? l : new ArrayList<>();
        } catch (Exception e) {
            return new ArrayList<>();
        }
    }

    public static Info find(Context c, String id) {
        for (Info i : list(c)) if (i.id.equals(id)) return i;
        return null;
    }

    /** 会话恢复时认识的容器 id；未接入 → null（不改写） */
    public static List<String> knownIds() {
        if (provider == null) return null;
        return null;
    }

    static void bind(WebView wv, String containerId) {
        if (provider == null || containerId == null || TabsCore.DEFAULT_CONTAINER.equals(containerId)) return;
        try {
            provider.bind(wv, containerId);
        } catch (Exception ignored) {
            // 绑定失败：用默认 Profile
        }
    }
}
