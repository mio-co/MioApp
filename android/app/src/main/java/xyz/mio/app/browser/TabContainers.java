package xyz.mio.app.browser;

import android.content.Context;
import android.webkit.WebView;

import java.util.ArrayList;
import java.util.List;

import xyz.mio.app.containers.ContainerManager;
import xyz.mio.app.containers.ContainerState;

/**
 * 标签容器（登录隔离）的接入点。{@link #useContainerManager} 注册转调 {@link ContainerManager}（#15）的 {@link Provider}：
 * 容器列表、androidx.webkit Profile 绑定、新标签选容器（锁定的打开者 > 显式指定 > 站点默认容器 > 未锁定的打开者 > 默认）、
 * 标签映射（key = "t&lt;id&gt;"）。系统 WebView 不支持 MULTI_PROFILE 时只有默认容器，相关菜单不显示。
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
        /** 新建的 WebView 绑定容器的 Profile（在任何加载之前调用），返回实际使用的容器 id */
        String bind(WebView webView, String containerId);
        /** 新标签的 { 容器 id, "1" = 锁定 / "0" } */
        default String[] forNewTab(String url, String openerContainer, boolean openerLocked, boolean hasOpener, String requested) {
            if (hasOpener && openerLocked) return new String[]{openerContainer, "1"};
            if (requested != null) return new String[]{requested, "0"};
            return new String[]{hasOpener ? openerContainer : TabsCore.DEFAULT_CONTAINER, "0"};
        }
        default void setTab(String key, String containerId, boolean locked) {}
        default void removeTab(String key) {}
        default void retainTabs(List<String> keys) {}
    }

    private static Provider provider;

    public static void setProvider(Provider p) { provider = p; }

    /** 用 ContainerManager 做 provider（BrowserActivity.onCreate 调用；重复调用无副作用） */
    public static void useContainerManager(Context ctx) {
        if (provider != null) return;
        final ContainerManager cm = ContainerManager.get(ctx);
        setProvider(new Provider() {
            @Override
            public boolean supported() { return ContainerManager.isSupported(); }

            @Override
            public List<Info> list(Context c) {
                List<Info> out = new ArrayList<>();
                // 系统不支持多 Profile：只有默认容器
                List<ContainerState.Container> all = cm.list();
                for (ContainerState.Container x : all) {
                    if (!supported() && !ContainerState.DEFAULT_ID.equals(x.id)) continue;
                    out.add(new Info(x.id, x.name, ContainerState.argb(x.color)));
                }
                return out;
            }

            @Override
            public String bind(WebView webView, String containerId) { return cm.apply(webView, containerId); }

            @Override
            public String[] forNewTab(String url, String openerContainer, boolean openerLocked, boolean hasOpener, String requested) {
                ContainerState.TabContainer opener = hasOpener ? new ContainerState.TabContainer(openerContainer, openerLocked) : null;
                ContainerState.TabContainer r = cm.containerForNewTab(url, opener, requested);
                return new String[]{r.containerId, r.locked ? "1" : "0"};
            }

            @Override
            public void setTab(String key, String containerId, boolean locked) { cm.setTab(key, containerId, locked); }

            @Override
            public void removeTab(String key) { cm.removeTab(key); }

            @Override
            public void retainTabs(List<String> keys) { cm.retainTabs(keys); }
        });
    }

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

    /** 会话恢复时认识的容器 id（已删除的容器 → 默认容器）；null = 不改写 */
    public static List<String> knownIds() {
        // 未接入 / 系统不支持多 Profile（不能新建 / 删除容器）：保留会话里的容器 id，等 WebView 更新后照常可用
        if (provider == null || !supported()) return null;
        List<String> ids = new ArrayList<>();
        try {
            for (Info i : provider.list(null)) ids.add(i.id);
        } catch (Exception e) {
            return null;
        }
        return ids;
    }

    /** 容器模块里的标签 key */
    public static String key(long tabId) { return "t" + tabId; }

    /** 新标签的 { 容器 id, "1" = 锁定 / "0" }；opener = 打开它的标签（可空），requested = 显式指定（可空） */
    static String[] forNewTab(String url, TabsCore.Tab opener, String requested) {
        String[] fallback = opener != null && opener.locked ? new String[]{opener.containerId, "1"}
                : new String[]{requested != null ? requested : opener != null ? opener.containerId : TabsCore.DEFAULT_CONTAINER, "0"};
        if (provider == null) return fallback;
        try {
            String[] r = provider.forNewTab(url, opener != null ? opener.containerId : null, opener != null && opener.locked, opener != null, requested);
            return r != null && r.length == 2 && r[0] != null ? r : fallback;
        } catch (Exception e) {
            return fallback;
        }
    }

    static void mirror(TabsCore.Tab t) {
        if (provider == null || t == null) return;
        try { provider.setTab(key(t.id), t.containerId, t.locked); } catch (Exception ignored) {}
    }

    static void removeTab(long id) {
        if (provider == null) return;
        try { provider.removeTab(key(id)); } catch (Exception ignored) {}
    }

    /** 恢复会话后：容器模块的标签映射只保留现在的标签，并按会话重写（容器 / 锁定以会话为准） */
    static void retainTabs(List<TabsCore.Tab> list) {
        if (provider == null) return;
        List<String> keys = new ArrayList<>();
        for (TabsCore.Tab t : list) keys.add(key(t.id));
        try { provider.retainTabs(keys); } catch (Exception ignored) {}
        for (TabsCore.Tab t : list) mirror(t);
    }

    /** 绑定 Profile，返回实际使用的容器 id（默认 / 不支持 / 失败 → default） */
    static String bind(WebView wv, String containerId) {
        if (provider == null || containerId == null || TabsCore.DEFAULT_CONTAINER.equals(containerId)) return TabsCore.DEFAULT_CONTAINER;
        try {
            String used = provider.bind(wv, containerId);
            return used != null ? used : TabsCore.DEFAULT_CONTAINER;
        } catch (Exception ignored) {
            // 绑定失败：用默认 Profile
            return TabsCore.DEFAULT_CONTAINER;
        }
    }
}
