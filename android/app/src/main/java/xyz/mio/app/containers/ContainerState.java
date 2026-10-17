package xyz.mio.app.containers;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.net.URI;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashSet;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.regex.Pattern;

/**
 * 内置浏览器「容器」（登录状态隔离）纯逻辑：不依赖 Android（只用 org.json），本地单测可跑。
 * 与 iOS 的 MioContainerCore.swift、Windows 的 desktop/src/containers-core.js 同一套规则、同一份 JSON：
 * <pre>
 * { "version": 1,
 *   "containers": [{ "id": "&lt;uuid 小写&gt;", "name": "工作", "color": "blue", "createdAt": &lt;ms&gt; }],
 *   "tabs": { "&lt;tabKey&gt;": { "containerId": "&lt;id&gt;", "locked": true } },
 *   "siteRules": [{ "host": "github.com", "containerId": "&lt;id&gt;" }],
 *   "pendingRemovals": ["&lt;id&gt;"] }
 * </pre>
 * - 默认容器 id = "default"：WebView 的 Default profile（原来的浏览数据，不迁移、不丢登录），不存进 containers、不能删除。
 * - 未知 / 已删除的容器 id 一律按默认容器处理（resolve）。
 * - 锁定继承：锁定标签打开的子标签 / 弹窗继承容器且同样锁定；未锁定标签的子标签默认继承容器（可被显式指定覆盖）。
 */
public final class ContainerState {
    public static final String DEFAULT_ID = "default";
    public static final String DEFAULT_NAME = "默认";
    public static final String DEFAULT_COLOR = "gray";
    public static final int MAX_CONTAINERS = 20;
    public static final int MAX_NAME = 32;
    /** Firefox Multi-Account Containers 的配色 */
    public static final List<String> COLORS = Collections.unmodifiableList(Arrays.asList("blue", "turquoise", "green", "yellow", "orange", "red", "pink", "purple"));
    private static final Map<String, Integer> COLOR_RGB = new LinkedHashMap<>();
    private static final Map<String, String> COLOR_NAMES = new LinkedHashMap<>();
    static {
        COLOR_RGB.put("blue", 0x37ADFF); COLOR_NAMES.put("blue", "蓝");
        COLOR_RGB.put("turquoise", 0x00C79A); COLOR_NAMES.put("turquoise", "青");
        COLOR_RGB.put("green", 0x51CD00); COLOR_NAMES.put("green", "绿");
        COLOR_RGB.put("yellow", 0xFFCB00); COLOR_NAMES.put("yellow", "黄");
        COLOR_RGB.put("orange", 0xFF9F00); COLOR_NAMES.put("orange", "橙");
        COLOR_RGB.put("red", 0xFF613D); COLOR_NAMES.put("red", "红");
        COLOR_RGB.put("pink", 0xFF4BDA); COLOR_NAMES.put("pink", "粉");
        COLOR_RGB.put("purple", 0xAF51F5); COLOR_NAMES.put("purple", "紫");
        COLOR_RGB.put("gray", 0x8E8E93); COLOR_NAMES.put("gray", "灰");
    }
    private static final Pattern UUID_RE = Pattern.compile("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$");
    private static final Pattern HOST_RE = Pattern.compile("^[a-z0-9.-]+$");

    /** 0xAARRGGBB（不透明） */
    public static int argb(String color) {
        Integer v = COLOR_RGB.get(color);
        return 0xFF000000 | (v != null ? v : COLOR_RGB.get(DEFAULT_COLOR));
    }

    public static String colorName(String color) {
        String n = COLOR_NAMES.get(color);
        return n != null ? n : color;
    }

    public static final class Container {
        public final String id;
        public final String name;
        public final String color;
        public final long createdAt;

        Container(String id, String name, String color, long createdAt) {
            this.id = id;
            this.name = name;
            this.color = color;
            this.createdAt = createdAt;
        }

        public boolean isDefault() { return DEFAULT_ID.equals(id); }

        @Override public boolean equals(Object o) {
            if (!(o instanceof Container)) return false;
            Container c = (Container) o;
            return id.equals(c.id) && name.equals(c.name) && color.equals(c.color) && createdAt == c.createdAt;
        }

        @Override public int hashCode() { return id.hashCode(); }

        @Override public String toString() { return "Container(" + id + "," + name + "," + color + ")"; }
    }

    /** 标签的容器 + 锁定 */
    public static final class TabContainer {
        public final String containerId;
        public final boolean locked;

        public TabContainer(String containerId, boolean locked) {
            this.containerId = containerId;
            this.locked = locked;
        }

        public static final TabContainer UNASSIGNED = new TabContainer(DEFAULT_ID, false);

        @Override public boolean equals(Object o) {
            if (!(o instanceof TabContainer)) return false;
            TabContainer t = (TabContainer) o;
            return containerId.equals(t.containerId) && locked == t.locked;
        }

        @Override public int hashCode() { return containerId.hashCode() * 31 + (locked ? 1 : 0); }

        @Override public String toString() { return "Tab(" + containerId + (locked ? ",locked)" : ")"); }
    }

    public static final class SiteRule {
        public final String host;
        public final String containerId;

        SiteRule(String host, String containerId) {
            this.host = host;
            this.containerId = containerId;
        }

        @Override public boolean equals(Object o) {
            return o instanceof SiteRule && host.equals(((SiteRule) o).host) && containerId.equals(((SiteRule) o).containerId);
        }

        @Override public int hashCode() { return host.hashCode(); }
    }

    /** 可注入（单测） */
    public interface Clock { long now(); }
    public interface IdSource { String next(); }

    private final List<Container> containers = new ArrayList<>();
    private final Map<String, TabContainer> tabs = new LinkedHashMap<>();
    private final List<SiteRule> siteRules = new ArrayList<>();
    private final List<String> pendingRemovals = new ArrayList<>();
    public Clock clock = System::currentTimeMillis;
    public IdSource ids = () -> UUID.randomUUID().toString().toLowerCase(Locale.ROOT);

    public ContainerState() {}

    // ------------------------------------------------------------ 工具

    public static boolean isContainerId(String s) {
        return s != null && UUID_RE.matcher(s).matches();
    }

    public static String cleanName(String s) {
        String t = (s == null ? "" : s).replaceAll("\\s+", " ").trim();
        return t.length() > MAX_NAME ? t.substring(0, MAX_NAME) : t;
    }

    /** 站点规则主机名：小写、去掉端口 / 路径 / 末尾点 / www.；接受网址 */
    public static String normalizeHost(String input) {
        String s = input == null ? "" : input.trim().toLowerCase(Locale.ROOT);
        if (s.isEmpty()) return null;
        if (s.matches("^[a-z][a-z0-9+.-]*://.*")) {
            try {
                s = new URI(s).getHost();
            } catch (Exception e) {
                return null;
            }
            if (s == null) return null;
        } else {
            s = s.split("[/?#]", 2)[0].replaceAll(":\\d+$", "");
        }
        if (s.endsWith(".")) s = s.substring(0, s.length() - 1);
        if (s.startsWith("www.")) s = s.substring(4);
        if (s.isEmpty() || !HOST_RE.matcher(s).matches() || !s.contains(".") || s.startsWith(".") || s.contains("..")) return null;
        return s;
    }

    public static String hostOfUrl(String url) {
        if (url == null) return null;
        try {
            URI u = new URI(url.trim());
            String scheme = u.getScheme() == null ? "" : u.getScheme().toLowerCase(Locale.ROOT);
            if (!scheme.equals("http") && !scheme.equals("https")) return null;
            String h = u.getHost();
            if (h == null) return null;
            h = h.toLowerCase(Locale.ROOT);
            return h.endsWith(".") ? h.substring(0, h.length() - 1) : h;
        } catch (Exception e) {
            return null;
        }
    }

    /** 锁定继承（纯函数）：父标签锁定 → 父容器 + 锁定（忽略 requested）；有 requested → requested；有父标签 → 父容器；否则默认容器 */
    public static TabContainer inherit(TabContainer parent, String requested) {
        if (parent != null && parent.locked) return new TabContainer(parent.containerId, true);
        if (requested != null && !requested.isEmpty()) return new TabContainer(requested, false);
        if (parent != null) return new TabContainer(parent.containerId, false);
        return TabContainer.UNASSIGNED;
    }

    /** 站点默认容器规则匹配：主机名本身或其子域名命中；多条命中取最长（最具体）的 */
    public static String matchSiteRule(String url, List<SiteRule> rules) {
        String host = hostOfUrl(url);
        if (host == null || rules == null) return null;
        SiteRule best = null;
        for (SiteRule r : rules) {
            if (host.equals(r.host) || host.endsWith("." + r.host)) {
                if (best == null || r.host.length() > best.host.length()) best = r;
            }
        }
        return best == null ? null : best.containerId;
    }

    // ------------------------------------------------------------ JSON

    /** 容错解析：坏 JSON / 坏条目丢掉 */
    public static ContainerState parse(String json) {
        ContainerState s = new ContainerState();
        if (json == null) return s;
        JSONObject root;
        try {
            root = new JSONObject(json);
        } catch (JSONException e) {
            return s;
        }
        Set<String> seen = new HashSet<>();
        JSONArray cs = root.optJSONArray("containers");
        if (cs != null) {
            for (int i = 0; i < cs.length(); i++) {
                JSONObject c = cs.optJSONObject(i);
                if (c == null || s.containers.size() >= MAX_CONTAINERS) continue;
                String id = c.optString("id", null);
                if (!isContainerId(id) || seen.contains(id)) continue;
                String name = cleanName(c.optString("name", ""));
                if (name.isEmpty()) continue;
                String color = c.optString("color", "");
                if (!COLORS.contains(color)) color = COLORS.get(0);
                seen.add(id);
                s.containers.add(new Container(id, name, color, c.optLong("createdAt", 0)));
            }
        }
        JSONObject ts = root.optJSONObject("tabs");
        if (ts != null) {
            for (Iterator<String> it = ts.keys(); it.hasNext(); ) {
                String k = it.next();
                JSONObject t = ts.optJSONObject(k);
                if (k.isEmpty() || t == null) continue;
                String cid = t.optString("containerId", null);
                if (!s.exists(cid)) continue;
                Object l = t.opt("locked");
                boolean locked = l instanceof Boolean ? (Boolean) l : l instanceof Number && ((Number) l).doubleValue() != 0;
                s.tabs.put(k, new TabContainer(cid, locked));
            }
        }
        JSONArray rs = root.optJSONArray("siteRules");
        Set<String> hosts = new HashSet<>();
        if (rs != null) {
            for (int i = 0; i < rs.length(); i++) {
                JSONObject r = rs.optJSONObject(i);
                if (r == null) continue;
                String host = normalizeHost(r.optString("host", null));
                String cid = r.optString("containerId", null);
                if (host == null || hosts.contains(host) || !s.exists(cid)) continue;
                hosts.add(host);
                s.siteRules.add(new SiteRule(host, cid));
            }
        }
        JSONArray ps = root.optJSONArray("pendingRemovals");
        if (ps != null) {
            for (int i = 0; i < ps.length(); i++) {
                String id = ps.optString(i, null);
                if (isContainerId(id) && !seen.contains(id) && !s.pendingRemovals.contains(id)) s.pendingRemovals.add(id);
            }
        }
        return s;
    }

    public String toJson() {
        try {
            JSONObject root = new JSONObject();
            root.put("version", 1);
            JSONArray cs = new JSONArray();
            for (Container c : containers) {
                cs.put(new JSONObject().put("id", c.id).put("name", c.name).put("color", c.color).put("createdAt", c.createdAt));
            }
            root.put("containers", cs);
            JSONObject ts = new JSONObject();
            for (Map.Entry<String, TabContainer> e : tabs.entrySet()) {
                ts.put(e.getKey(), new JSONObject().put("containerId", e.getValue().containerId).put("locked", e.getValue().locked));
            }
            root.put("tabs", ts);
            JSONArray rs = new JSONArray();
            for (SiteRule r : siteRules) rs.put(new JSONObject().put("host", r.host).put("containerId", r.containerId));
            root.put("siteRules", rs);
            root.put("pendingRemovals", new JSONArray(pendingRemovals));
            return root.toString();
        } catch (JSONException e) {
            throw new IllegalStateException(e);
        }
    }

    // ------------------------------------------------------------ 容器

    public static Container defaultContainer() {
        return new Container(DEFAULT_ID, DEFAULT_NAME, DEFAULT_COLOR, 0);
    }

    /** 默认容器在前 */
    public List<Container> list() {
        List<Container> l = new ArrayList<>();
        l.add(defaultContainer());
        l.addAll(containers);
        return l;
    }

    public Container get(String id) {
        if (DEFAULT_ID.equals(id)) return defaultContainer();
        for (Container c : containers) if (c.id.equals(id)) return c;
        return null;
    }

    public boolean exists(String id) {
        return get(id) != null;
    }

    /** 有效 id 原样返回，其他（空、未知、已删除）→ "default" */
    public String resolve(String id) {
        return exists(id) ? id : DEFAULT_ID;
    }

    public boolean canCreate() {
        return containers.size() < MAX_CONTAINERS;
    }

    public String nextColor() {
        Set<String> used = new HashSet<>();
        for (Container c : containers) used.add(c.color);
        for (String c : COLORS) if (!used.contains(c)) return c;
        return COLORS.get(containers.size() % COLORS.size());
    }

    public Container create(String name, String color) {
        if (!canCreate()) throw new IllegalStateException("最多 " + MAX_CONTAINERS + " 个容器");
        String n = cleanName(name);
        if (n.isEmpty()) throw new IllegalArgumentException("容器名称不能为空");
        String id = ids.next();
        id = id == null ? "" : id.toLowerCase(Locale.ROOT);
        while (!isContainerId(id) || exists(id) || pendingRemovals.contains(id)) id = UUID.randomUUID().toString().toLowerCase(Locale.ROOT);
        Container c = new Container(id, n, COLORS.contains(color) ? color : nextColor(), clock.now());
        containers.add(c);
        return c;
    }

    public Container update(String id, String name, String color) {
        int i = indexOf(id);
        if (i < 0) throw new IllegalArgumentException(DEFAULT_ID.equals(id) ? "默认容器不能修改" : "容器不存在");
        Container c = containers.get(i);
        String n = c.name;
        if (name != null) {
            n = cleanName(name);
            if (n.isEmpty()) throw new IllegalArgumentException("容器名称不能为空");
        }
        String col = c.color;
        if (color != null) {
            if (!COLORS.contains(color)) throw new IllegalArgumentException("无效的颜色");
            col = color;
        }
        Container u = new Container(c.id, n, col, c.createdAt);
        containers.set(i, u);
        return u;
    }

    private int indexOf(String id) {
        for (int i = 0; i < containers.size(); i++) if (containers.get(i).id.equals(id)) return i;
        return -1;
    }

    /** 删除：去掉元数据、它的标签映射（这些标签应被关闭）和站点规则，记入 pendingRemovals。返回受影响的 tabKey */
    public List<String> remove(String id) {
        if (DEFAULT_ID.equals(id)) throw new IllegalArgumentException("默认容器不能删除");
        int i = indexOf(id);
        if (i < 0) throw new IllegalArgumentException("容器不存在");
        containers.remove(i);
        List<String> keys = tabsIn(id);
        for (String k : keys) tabs.remove(k);
        for (Iterator<SiteRule> it = siteRules.iterator(); it.hasNext(); ) if (it.next().containerId.equals(id)) it.remove();
        if (!pendingRemovals.contains(id)) pendingRemovals.add(id);
        return keys;
    }

    public List<String> pendingRemovals() {
        return new ArrayList<>(pendingRemovals);
    }

    public void markRemoved(String id) {
        pendingRemovals.remove(id);
    }

    // ------------------------------------------------------------ 标签 → 容器（restore 用）

    /** 默认容器且不锁定 = 删除记录（读出来一样） */
    public TabContainer setTab(String key, String containerId, boolean locked) {
        if (key == null || key.isEmpty()) throw new IllegalArgumentException("tabKey 不能为空");
        String cid = resolve(containerId);
        if (DEFAULT_ID.equals(cid) && !locked) tabs.remove(key);
        else tabs.put(key, new TabContainer(cid, locked));
        return getTab(key);
    }

    /** 没记录 → 默认容器、不锁定 */
    public TabContainer getTab(String key) {
        TabContainer t = tabs.get(key);
        return t == null ? TabContainer.UNASSIGNED : new TabContainer(resolve(t.containerId), t.locked);
    }

    public TabContainer setTabLocked(String key, boolean locked) {
        return setTab(key, getTab(key).containerId, locked);
    }

    public void removeTab(String key) {
        tabs.remove(key);
    }

    public void retainTabs(Iterable<String> keys) {
        Set<String> keep = new HashSet<>();
        for (String k : keys) keep.add(k);
        tabs.keySet().retainAll(keep);
    }

    public List<String> tabsIn(String containerId) {
        List<String> l = new ArrayList<>();
        for (Map.Entry<String, TabContainer> e : tabs.entrySet()) if (e.getValue().containerId.equals(containerId)) l.add(e.getKey());
        Collections.sort(l);
        return l;
    }

    public Map<String, TabContainer> tabs() {
        return Collections.unmodifiableMap(tabs);
    }

    /** 锁定继承 + resolve：子标签 / 弹窗 */
    public TabContainer childOf(TabContainer parent, String requested) {
        TabContainer r = inherit(parent, exists(requested) ? requested : null);
        return new TabContainer(resolve(r.containerId), r.locked && exists(r.containerId));
    }

    /** 新标签用哪个容器：锁定的打开者 > 显式指定 > 站点默认容器规则 > 未锁定的打开者 > 默认容器 */
    public TabContainer containerForNewTab(String url, TabContainer opener, String requested) {
        if (opener != null && opener.locked) return childOf(opener, null);
        if (requested != null && exists(requested)) return new TabContainer(requested, false);
        String rule = containerForUrl(url);
        if (rule != null) return new TabContainer(rule, false);
        return childOf(opener, null);
    }

    // ------------------------------------------------------------ 站点默认容器（可选）

    public String setSiteRule(String input, String containerId) {
        String host = normalizeHost(input);
        if (host == null) throw new IllegalArgumentException("无效的域名");
        if (DEFAULT_ID.equals(containerId) || !exists(containerId)) throw new IllegalArgumentException("只能指定已有的非默认容器");
        for (Iterator<SiteRule> it = siteRules.iterator(); it.hasNext(); ) if (it.next().host.equals(host)) it.remove();
        siteRules.add(new SiteRule(host, containerId));
        Collections.sort(siteRules, (a, b) -> a.host.compareTo(b.host));
        return host;
    }

    public void removeSiteRule(String input) {
        String h = normalizeHost(input);
        String host = h != null ? h : input;
        for (Iterator<SiteRule> it = siteRules.iterator(); it.hasNext(); ) if (it.next().host.equals(host)) it.remove();
    }

    public List<SiteRule> siteRules() {
        return Collections.unmodifiableList(siteRules);
    }

    public String containerForUrl(String url) {
        String id = matchSiteRule(url, siteRules);
        return id != null && exists(id) ? id : null;
    }
}
