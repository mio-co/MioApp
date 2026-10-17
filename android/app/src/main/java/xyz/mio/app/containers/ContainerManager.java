package xyz.mio.app.containers;

import android.content.Context;
import android.content.SharedPreferences;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.webkit.CookieManager;
import android.webkit.WebView;

import androidx.webkit.Profile;
import androidx.webkit.ProfileStore;
import androidx.webkit.WebViewCompat;
import androidx.webkit.WebViewFeature;

import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;

/**
 * 内置浏览器「容器」（登录状态隔离）：每个容器一个 WebView Profile（androidx.webkit MULTI_PROFILE），
 * Cookie / LocalStorage / IndexedDB / 缓存 / Service Worker 完全隔离；元数据、标签映射、锁定、站点规则存 SharedPreferences（mio.containers）。
 *
 * <p>标签管理器接入：
 * <pre>
 *   ContainerManager cm = ContainerManager.get(context);
 *   WebView wv = new WebView(context);
 *   cm.apply(wv, containerId);            // 必须紧跟在 new WebView 之后、任何 getSettings / loadUrl 之前
 *   cm.containerForNewTab(url, opener, requested) / childOf(parent, requested)   // 锁定继承
 *   cm.setTab(tabKey, containerId, locked) / getTab / setTabLocked / removeTab / retainTabs   // restore 用
 *   cm.addListener(listener)              // onContainerRemoved(id, tabKeys) → 关闭这些标签（destroy WebView 后 profile 才能删）
 *   cm.cookieManager(containerId)         // 该容器的 CookieManager（flush 等）
 * </pre>
 * - 默认容器（"default"）= Default profile（原来的浏览数据，不迁移、不丢登录）
 * - 系统 WebView 不支持 MULTI_PROFILE 时 isSupported() == false：只有默认容器，设置页提示更新 Android System WebView
 * - ProfileStore 只能在主线程用，且必须在本进程设置完 WebView 数据目录（BrowserActivity 的 setDataDirectorySuffix）之后
 */
public final class ContainerManager {
    private static final String TAG = "MioContainers";
    private static final String PREFS = "mio.containers";
    private static final String KEY_STATE = "state";
    public static final String PROFILE_PREFIX = "mio-c-";

    public interface Listener {
        /** 容器被删除（在删除 profile 之前、主线程）：关闭这些标签 / 该容器的所有 WebView */
        void onContainerRemoved(String containerId, List<String> tabKeys);
        /** 容器列表 / 名称 / 颜色 / 站点规则变化 */
        default void onContainersChanged() {}
    }

    private static ContainerManager instance;

    public static synchronized ContainerManager get(Context c) {
        if (instance == null) instance = new ContainerManager(c.getApplicationContext());
        return instance;
    }

    private final SharedPreferences prefs;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final List<Listener> listeners = new CopyOnWriteArrayList<>();
    private ContainerState state;
    private boolean purged;

    private ContainerManager(Context app) {
        prefs = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        state = ContainerState.parse(prefs.getString(KEY_STATE, null));
    }

    /** 系统 WebView 支持多 Profile（Android System WebView 较新版本） */
    public static boolean isSupported() {
        try {
            return WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE);
        } catch (Throwable t) {
            return false;
        }
    }

    public static String profileName(String containerId) {
        return ContainerState.DEFAULT_ID.equals(containerId) || containerId == null ? Profile.DEFAULT_PROFILE_NAME : PROFILE_PREFIX + containerId;
    }

    public synchronized ContainerState state() {
        return state;
    }

    private synchronized void save(boolean notify) {
        prefs.edit().putString(KEY_STATE, state.toJson()).apply();
        if (notify) main.post(() -> { for (Listener l : listeners) l.onContainersChanged(); });
    }

    public void addListener(Listener l) { listeners.add(l); }
    public void removeListener(Listener l) { listeners.remove(l); }

    // ------------------------------------------------------------ WebView

    /**
     * 让 WebView 使用容器的 Profile。必须在 new WebView 之后立即调用（WebView 还没加载任何东西）。
     * 默认容器 / 不支持 / 未知容器 → 什么都不做（Default profile）。返回实际使用的容器 id。
     */
    public String apply(WebView webView, String containerId) {
        String id = resolve(containerId);
        purgePendingIfNeeded();
        if (ContainerState.DEFAULT_ID.equals(id) || !isSupported()) return ContainerState.DEFAULT_ID;
        try {
            ProfileStore.getInstance().getOrCreateProfile(profileName(id));
            WebViewCompat.setProfile(webView, profileName(id));
            return id;
        } catch (Throwable t) {
            // WebView 已经用过 / Profile 创建失败：留在默认容器，不崩溃
            Log.w(TAG, "setProfile " + id + " failed", t);
            return ContainerState.DEFAULT_ID;
        }
    }

    /** 容器的 CookieManager（默认容器 / 不支持 → CookieManager.getInstance()） */
    public CookieManager cookieManager(String containerId) {
        String id = resolve(containerId);
        if (!ContainerState.DEFAULT_ID.equals(id) && isSupported()) {
            try {
                return ProfileStore.getInstance().getOrCreateProfile(profileName(id)).getCookieManager();
            } catch (Throwable t) {
                Log.w(TAG, "cookieManager " + id, t);
            }
        }
        return CookieManager.getInstance();
    }

    // ------------------------------------------------------------ 容器

    public synchronized List<ContainerState.Container> list() { return state.list(); }
    public synchronized ContainerState.Container container(String id) { return state.get(id); }
    public synchronized String resolve(String id) { return state.resolve(id); }

    public ContainerState.Container create(String name, String color) {
        ContainerState.Container c;
        synchronized (this) { c = state.create(name, color); }
        save(true);
        return c;
    }

    public ContainerState.Container update(String id, String name, String color) {
        ContainerState.Container c;
        synchronized (this) { c = state.update(id, name, color); }
        save(true);
        return c;
    }

    /**
     * 删除容器（主线程）：去掉元数据 → 通知监听者关闭该容器的标签 → 下一轮消息循环删除 Profile（Cookie、存储、缓存全部删掉）。
     * Profile 仍被 WebView 使用时删除会失败：重试几次，仍失败则清空 Cookie / 存储并留到下次启动删除。
     */
    public List<String> remove(String id) {
        List<String> keys;
        synchronized (this) { keys = state.remove(id); }
        save(true);
        for (Listener l : listeners) l.onContainerRemoved(id, keys);
        main.post(() -> deleteProfile(id, 0));
        return keys;
    }

    private void deleteProfile(String id, int attempt) {
        if (!isSupported()) {
            markRemoved(id);
            return;
        }
        String name = profileName(id);
        try {
            ProfileStore store = ProfileStore.getInstance();
            if (store.getProfile(name) == null || store.deleteProfile(name)) {
                markRemoved(id);
                Log.i(TAG, "profile deleted: " + name);
                return;
            }
        } catch (IllegalStateException inUse) {
            Log.w(TAG, "profile in use: " + name + " (attempt " + attempt + ")");
        } catch (Throwable t) {
            Log.w(TAG, "deleteProfile " + name, t);
        }
        if (attempt < 3) {
            main.postDelayed(() -> deleteProfile(id, attempt + 1), 1500);
            return;
        }
        // 仍被占用：先清掉登录状态和网站数据，Profile 留到下次启动（没有 WebView 用它时）再删
        try {
            Profile p = ProfileStore.getInstance().getProfile(name);
            if (p != null) {
                p.getCookieManager().removeAllCookies(null);
                p.getWebStorage().deleteAllData();
            }
        } catch (Throwable t) {
            Log.w(TAG, "clear " + name, t);
        }
    }

    private void markRemoved(String id) {
        synchronized (this) { state.markRemoved(id); }
        save(false);
    }

    /** 本进程第一次用容器时（还没有 WebView 用到被删的 Profile）：删掉上次没删干净的 Profile */
    private void purgePendingIfNeeded() {
        if (purged) return;
        purged = true;
        List<String> pending;
        synchronized (this) { pending = state.pendingRemovals(); }
        if (pending.isEmpty() || !isSupported()) return;
        for (String id : pending) {
            try {
                ProfileStore store = ProfileStore.getInstance();
                String name = profileName(id);
                if (store.getProfile(name) == null || store.deleteProfile(name)) markRemoved(id);
            } catch (Throwable t) {
                Log.w(TAG, "purge " + id, t);
            }
        }
    }

    // ------------------------------------------------------------ 标签 → 容器（restore 用）

    public ContainerState.TabContainer setTab(String key, String containerId, boolean locked) {
        ContainerState.TabContainer t;
        synchronized (this) { t = state.setTab(key, containerId, locked); }
        save(false);
        return t;
    }

    public synchronized ContainerState.TabContainer getTab(String key) { return state.getTab(key); }

    public ContainerState.TabContainer setTabLocked(String key, boolean locked) {
        ContainerState.TabContainer t;
        synchronized (this) { t = state.setTabLocked(key, locked); }
        save(false);
        return t;
    }

    public void removeTab(String key) {
        synchronized (this) { state.removeTab(key); }
        save(false);
    }

    public void retainTabs(Iterable<String> keys) {
        synchronized (this) { state.retainTabs(keys); }
        save(false);
    }

    public synchronized ContainerState.TabContainer childOf(ContainerState.TabContainer parent, String requested) {
        return state.childOf(parent, requested);
    }

    public synchronized ContainerState.TabContainer containerForNewTab(String url, ContainerState.TabContainer opener, String requested) {
        return state.containerForNewTab(url, opener, requested);
    }

    // ------------------------------------------------------------ 站点默认容器

    public String setSiteRule(String host, String containerId) {
        String h;
        synchronized (this) { h = state.setSiteRule(host, containerId); }
        save(true);
        return h;
    }

    public void removeSiteRule(String host) {
        synchronized (this) { state.removeSiteRule(host); }
        save(true);
    }

    public synchronized String containerForUrl(String url) { return state.containerForUrl(url); }
}
