package xyz.mio.app.browser;

import org.json.JSONArray;
import org.json.JSONObject;

import java.net.URI;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.List;
import java.util.Locale;

/**
 * 内置浏览器多标签页的纯逻辑（无 Android 依赖，单测见 TabsCoreTest）。
 * 与 Windows 的 desktop/src/tabs-core.js、iOS / Mac 的 MioTabsCore.swift 同一套规则和同一种持久化格式：
 * 新标签插在当前标签右边（从当前标签打开的后台标签按打开顺序排在一起）；关闭当前 → 右边，没有就左边；
 * 最近关闭最多 20 个可恢复；上限 50 个；超过「同时加载」上限按最近使用卸载后台标签；
 * 容器（feat/containers-core 接入）：子标签继承容器，锁定的标签连锁定一起继承且不能改容器。
 */
public final class TabsCore {
    public static final String DEFAULT_CONTAINER = "default";
    public static final String DEFAULT_NEW_TAB_URL = "https://mio.300031.xyz/mio/nav";
    public static final int MAX_TABS = 50;
    public static final int MAX_CLOSED = 20;
    static final int MAX_TITLE = 300;

    public static final class Tab {
        public final long id;
        public String url;
        public String title;
        public Long openerId;
        public String containerId;
        public boolean locked;
        long lastActive;

        Tab(long id, String url, String title, Long openerId, String containerId, boolean locked) {
            this.id = id;
            this.url = url;
            this.title = title;
            this.openerId = openerId;
            this.containerId = containerId;
            this.locked = locked;
        }
    }

    public static final class Closed {
        public final String url, title, containerId;
        public final int index;
        public final boolean locked;

        Closed(String url, String title, int index, String containerId, boolean locked) {
            this.url = url;
            this.title = title;
            this.index = index;
            this.containerId = containerId;
            this.locked = locked;
        }
    }

    /** 新建标签的选项 */
    public static final class Opts {
        public String title;
        public boolean activate = true;
        public boolean fromActive;
        public Integer index;
        public String containerId;
        public boolean locked;
        public boolean noOpener;

        public static Opts make() { return new Opts(); }
        public Opts title(String t) { title = t; return this; }
        public Opts activate(boolean a) { activate = a; return this; }
        public Opts fromActive(boolean f) { fromActive = f; return this; }
        public Opts index(int i) { index = i; return this; }
        public Opts container(String c) { containerId = c; return this; }
        public Opts locked(boolean l) { locked = l; return this; }
    }

    public interface LoadedCheck { boolean isLoaded(Tab t); }

    public final int maxTabs;
    public final int maxClosed;
    private final List<Tab> tabs = new ArrayList<>();
    private final List<Closed> closed = new ArrayList<>();
    private Long activeId;
    private long nextId = 1;
    private long clock;

    public TabsCore() { this(MAX_TABS, MAX_CLOSED); }

    public TabsCore(int maxTabs, int maxClosed) {
        this.maxTabs = maxTabs;
        this.maxClosed = maxClosed;
    }

    // ------------------------------------------------------------------ helpers

    public static boolean isHttp(String url) {
        if (url == null) return false;
        try {
            URI u = new URI(url.trim());
            String s = u.getScheme();
            return s != null && (s.equalsIgnoreCase("http") || s.equalsIgnoreCase("https")) && u.getHost() != null && !u.getHost().isEmpty();
        } catch (Exception e) {
            return false;
        }
    }

    /** 显示用域名：小写、去掉 www. */
    public static String displayHost(String url) {
        if (!isHttp(url)) return "";
        try {
            String h = new URI(url.trim()).getHost().toLowerCase(Locale.ROOT);
            if (h.endsWith(".")) h = h.substring(0, h.length() - 1);
            if (h.startsWith("www.")) h = h.substring(4);
            return h;
        } catch (Exception e) {
            return "";
        }
    }

    /** 新标签页地址设置：空 → 默认；补 https://；不是 http(s) → null */
    public static String normalizeNewTabUrl(String input) {
        String s = input == null ? "" : input.trim();
        if (s.isEmpty()) return DEFAULT_NEW_TAB_URL;
        boolean hasScheme = s.matches("^[A-Za-z][A-Za-z0-9+.-]*:.*");
        boolean hostPort = s.matches("^[^\\s/:]+:[0-9]+(/.*)?$");
        if (!hasScheme || hostPort) s = "https://" + s;
        if (!isHttp(s)) return null;
        try {
            URI u = new URI(s);
            String h = u.getHost();
            if (!h.contains(".") && !h.equals("localhost")) return null;
            if (u.getRawPath() == null || u.getRawPath().isEmpty()) {
                u = new URI(u.getScheme(), u.getRawAuthority(), "/", u.getRawQuery(), u.getRawFragment());
                return u.toString();
            }
            return s;
        } catch (Exception e) {
            return null;
        }
    }

    public static String cleanTitle(String t) {
        String s = t == null ? "" : t.replaceAll("\\s+", " ").trim();
        return s.length() > MAX_TITLE ? s.substring(0, MAX_TITLE) : s;
    }

    public static String cleanContainer(String c) {
        String s = c == null ? "" : c.trim();
        return s.matches("^[A-Za-z0-9_-]{1,64}$") ? s : DEFAULT_CONTAINER;
    }

    // ------------------------------------------------------------------ queries

    public int size() { return tabs.size(); }
    public boolean isEmpty() { return tabs.isEmpty(); }
    public boolean canAdd() { return tabs.size() < maxTabs; }
    public boolean hasClosed() { return !closed.isEmpty(); }
    public List<Tab> tabs() { return Collections.unmodifiableList(tabs); }
    public List<Closed> closed() { return Collections.unmodifiableList(closed); }
    public Long activeId() { return activeId; }
    public Tab active() { return activeId == null ? null : get(activeId); }
    public int activeIndex() { return activeId == null ? -1 : indexOf(activeId); }

    public Tab get(long id) {
        for (Tab t : tabs) if (t.id == id) return t;
        return null;
    }

    public int indexOf(long id) {
        for (int i = 0; i < tabs.size(); i++) if (tabs.get(i).id == id) return i;
        return -1;
    }

    // ------------------------------------------------------------------ mutations

    public Tab add(String url, Opts o) {
        if (o == null) o = new Opts();
        if (!canAdd()) return null;
        Long openerId = o.noOpener ? null : (o.fromActive ? activeId : null);
        Tab opener = openerId == null ? null : get(openerId);
        String container = cleanContainer(o.containerId);
        boolean locked = o.locked;
        if (opener != null && o.fromActive) {
            if (opener.locked) {
                container = opener.containerId;
                locked = true;
            } else if (o.containerId == null) {
                container = opener.containerId;
            }
        }
        Tab t = new Tab(nextId++, url == null ? "" : url, cleanTitle(o.title), openerId, container, locked);
        int at;
        if (o.index != null) {
            at = Math.max(0, Math.min(tabs.size(), o.index));
        } else {
            int ai = activeIndex();
            if (ai < 0) {
                at = tabs.size();
            } else {
                at = ai + 1;
                if (t.openerId != null && t.openerId.equals(activeId)) {
                    while (at < tabs.size() && activeId.equals(tabs.get(at).openerId)) at++;
                }
            }
        }
        tabs.add(at, t);
        if (o.activate || activeId == null) select(t.id);
        return t;
    }

    public boolean select(long id) {
        Tab t = get(id);
        if (t == null) return false;
        if (activeId != null && activeId != id) {
            for (Tab x : tabs) if (activeId.equals(x.openerId) && x.id != id) x.openerId = null;
        }
        activeId = id;
        t.lastActive = ++clock;
        return true;
    }

    public boolean selectIndex(int i) {
        return i >= 0 && i < tabs.size() && select(tabs.get(i).id);
    }

    public boolean selectRelative(int delta) {
        if (tabs.isEmpty()) return false;
        int n = tabs.size();
        int i = Math.max(0, activeIndex());
        return selectIndex(((i + delta) % n + n) % n);
    }

    public boolean update(long id, String url, String title) {
        Tab t = get(id);
        if (t == null) return false;
        boolean changed = false;
        if (url != null && !url.equals(t.url)) { t.url = url; changed = true; }
        if (title != null) {
            String c = cleanTitle(title);
            if (!c.equals(t.title)) { t.title = c; changed = true; }
        }
        return changed;
    }

    public boolean setContainer(long id, String containerId) {
        Tab t = get(id);
        if (t == null || t.locked) return false;
        String c = cleanContainer(containerId);
        if (c.equals(t.containerId)) return false;
        t.containerId = c;
        return true;
    }

    public boolean setLocked(long id, boolean locked) {
        Tab t = get(id);
        if (t == null || t.locked == locked) return false;
        t.locked = locked;
        return true;
    }

    /** 删除容器：关闭它的标签（返回 id），最近关闭里它的条目也删掉 */
    public List<Long> removeContainer(String containerId) {
        String c = cleanContainer(containerId);
        List<Long> ids = new ArrayList<>();
        if (c.equals(DEFAULT_CONTAINER)) return ids;
        for (Tab t : tabs) if (t.containerId.equals(c)) ids.add(t.id);
        for (Long id : ids) close(id);
        for (java.util.Iterator<Closed> it = closed.iterator(); it.hasNext(); ) if (it.next().containerId.equals(c)) it.remove();
        return ids;
    }

    /** 关闭：返回被关的标签（不存在 → null）；关的是当前标签时激活右边 / 左边 */
    public Tab close(long id) {
        int i = indexOf(id);
        if (i < 0) return null;
        Tab t = tabs.remove(i);
        if (isHttp(t.url)) {
            closed.add(new Closed(t.url, t.title, i, t.containerId, t.locked));
            while (closed.size() > maxClosed) closed.remove(0);
        }
        for (Tab x : tabs) if (x.openerId != null && x.openerId == id) x.openerId = null;
        if (activeId != null && activeId == id) {
            activeId = null;
            if (i < tabs.size()) select(tabs.get(i).id);
            else if (i - 1 >= 0 && i - 1 < tabs.size()) select(tabs.get(i - 1).id);
        }
        return t;
    }

    public Tab reopenClosed() {
        if (closed.isEmpty() || !canAdd()) return null;
        Closed c = closed.remove(closed.size() - 1);
        Opts o = Opts.make().title(c.title).index(c.index).container(c.containerId).locked(c.locked);
        o.noOpener = true;
        return add(c.url, o);
    }

    public boolean move(int from, int to) {
        if (from < 0 || from >= tabs.size()) return false;
        int dest = Math.max(0, Math.min(tabs.size() - 1, to));
        if (dest == from) return false;
        Tab t = tabs.remove(from);
        tabs.add(dest, t);
        return true;
    }

    public List<Long> toUnload(int maxLoaded, LoadedCheck check) {
        List<Tab> loaded = new ArrayList<>();
        for (Tab t : tabs) if (check.isLoaded(t)) loaded.add(t);
        int extra = loaded.size() - Math.max(1, maxLoaded);
        List<Long> out = new ArrayList<>();
        if (extra <= 0) return out;
        List<Tab> cand = new ArrayList<>();
        for (Tab t : loaded) if (activeId == null || t.id != activeId) cand.add(t);
        Collections.sort(cand, new Comparator<Tab>() {
            @Override
            public int compare(Tab x, Tab y) { return Long.compare(x.lastActive, y.lastActive); }
        });
        for (int i = 0; i < Math.min(extra, cand.size()); i++) out.add(cand.get(i).id);
        return out;
    }

    // ------------------------------------------------------------------ persistence

    public String serialize() {
        try {
            JSONArray arr = new JSONArray();
            int active = 0, k = 0;
            for (Tab t : tabs) {
                if (!isHttp(t.url)) continue;
                if (activeId != null && t.id == activeId) active = k;
                JSONObject o = new JSONObject();
                o.put("url", t.url);
                o.put("title", t.title);
                if (!DEFAULT_CONTAINER.equals(t.containerId)) o.put("container", t.containerId);
                if (t.locked) o.put("locked", true);
                arr.put(o);
                k++;
            }
            JSONObject root = new JSONObject();
            root.put("v", 2);
            root.put("active", active);
            root.put("tabs", arr);
            return root.toString();
        } catch (Exception e) {
            return "{\"v\":2,\"active\":0,\"tabs\":[]}";
        }
    }

    /** 恢复（替换现有标签）；known 非 null 时不认识的容器回到默认容器 */
    public int restore(String json, List<String> known) {
        if (json == null || json.isEmpty()) return 0;
        try {
            JSONObject root = new JSONObject(json);
            JSONArray arr = root.optJSONArray("tabs");
            if (arr == null) return 0;
            List<JSONObject> items = new ArrayList<>();
            for (int i = 0; i < arr.length() && items.size() < maxTabs; i++) {
                JSONObject o = arr.optJSONObject(i);
                if (o != null && isHttp(o.optString("url", null))) items.add(o);
            }
            if (items.isEmpty()) return 0;
            tabs.clear();
            activeId = null;
            for (JSONObject o : items) {
                String c = cleanContainer(o.optString("container", DEFAULT_CONTAINER));
                if (known != null && !c.equals(DEFAULT_CONTAINER) && !known.contains(c)) c = DEFAULT_CONTAINER;
                Opts op = Opts.make().title(o.optString("title", "")).activate(false).index(tabs.size()).container(c).locked(o.optBoolean("locked", false));
                op.noOpener = true;
                add(o.optString("url"), op);
            }
            int a = Math.max(0, Math.min(items.size() - 1, root.optInt("active", 0)));
            selectIndex(a);
            return items.size();
        } catch (Exception e) {
            return 0;
        }
    }
}
