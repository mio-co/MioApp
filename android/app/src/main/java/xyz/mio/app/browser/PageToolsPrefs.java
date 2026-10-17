package xyz.mio.app.browser;

import android.content.Context;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/**
 * 阅读模式 / 强制深色 / 存到 Mio 的设置（文件存储 mio-pagetools-prefs.json，:browser 与主进程都读得到），
 * 与 iOS（MioReaderCore.swift）、桌面版（page-tools-store.js）同样的规则：按站点开关（含父域名，越具体越优先）> 全局。
 */
public final class PageToolsPrefs {
    private PageToolsPrefs() {}

    public static final String DEFAULT_CATEGORY = "稍后阅读";
    static final String[] THEMES = {"light", "sepia", "dark"};
    static final String[] FONTS = {"sans", "serif", "mono"};

    // ---------------------------------------------------------------- 纯逻辑（单测）

    public static String normalizeHost(String h) {
        if (h == null) return "";
        String s = h.trim().toLowerCase(Locale.ROOT);
        while (s.startsWith(".")) s = s.substring(1);
        while (s.endsWith(".")) s = s.substring(0, s.length() - 1);
        if (s.startsWith("www.")) s = s.substring(4);
        return s;
    }

    /** 实际生效的站点设置键（news.example.com 上可能是 example.com 的设置） */
    public static String matchingSiteKey(String host, Map<String, Boolean> sites) {
        String h = normalizeHost(host);
        if (h.isEmpty()) return null;
        String[] parts = h.split("\\.");
        if (parts.length < 2) return sites.containsKey(h) ? h : null;
        for (int i = 0; i < parts.length - 1; i++) {
            StringBuilder key = new StringBuilder();
            for (int j = i; j < parts.length; j++) {
                if (key.length() > 0) key.append('.');
                key.append(parts[j]);
            }
            if (sites.containsKey(key.toString())) return key.toString();
        }
        return null;
    }

    public static boolean isDarkEnabled(String host, boolean global, Map<String, Boolean> sites) {
        String key = matchingSiteKey(host, sites);
        return key != null ? Boolean.TRUE.equals(sites.get(key)) : global;
    }

    /** 当前站点开关：和全局一致时去掉站点设置，否则记为例外（写在实际生效的那一级） */
    public static Map<String, Boolean> withSiteDark(String host, boolean on, boolean global, Map<String, Boolean> sites) {
        Map<String, Boolean> s = new LinkedHashMap<>(sites);
        String h = normalizeHost(host);
        if (h.isEmpty()) return s;
        String key = matchingSiteKey(h, s);
        if (key == null) key = h;
        if (on == global) s.remove(key); else s.put(key, on);
        if (isDarkEnabled(h, global, s) != on) s.put(key, on);
        return s;
    }

    public static boolean needsScript(boolean global, Map<String, Boolean> sites) {
        return global || sites.containsValue(Boolean.TRUE);
    }

    /** 记录「网站自带深色」：最多 300 个，最近的在前；返回 null 表示没有变化 */
    public static List<String> updatedNativeHosts(List<String> list, String host, boolean nativeDark) {
        String h = normalizeHost(host);
        if (h.isEmpty()) return null;
        List<String> l = new ArrayList<>(list);
        l.remove(h);
        if (nativeDark) l.add(0, h);
        while (l.size() > 300) l.remove(l.size() - 1);
        return l.equals(list) ? null : l;
    }

    public static int clampFontSize(int s) { return Math.max(12, Math.min(32, s)); }

    // ---------------------------------------------------------------- 存储

    private static File file(Context c) { return new File(c.getFilesDir(), "mio-pagetools-prefs.json"); }

    static synchronized JSONObject read(Context c) {
        try {
            File f = file(c);
            if (f.exists()) {
                try (java.io.FileInputStream in = new java.io.FileInputStream(f)) {
                    java.io.ByteArrayOutputStream out = new java.io.ByteArrayOutputStream();
                    byte[] buf = new byte[8192];
                    int n;
                    while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
                    return new JSONObject(new String(out.toByteArray(), StandardCharsets.UTF_8));
                }
            }
        } catch (Exception ignored) {}
        return new JSONObject();
    }

    static synchronized void write(Context c, JSONObject o) {
        try {
            File f = file(c);
            File tmp = new File(f.getPath() + ".tmp");
            try (java.io.FileOutputStream out = new java.io.FileOutputStream(tmp)) {
                out.write(o.toString().getBytes(StandardCharsets.UTF_8));
            }
            if (!tmp.renameTo(f)) {
                try (java.io.FileOutputStream out = new java.io.FileOutputStream(f)) {
                    out.write(o.toString().getBytes(StandardCharsets.UTF_8));
                }
            }
        } catch (Exception ignored) {}
    }

    public static boolean darkGlobal(Context c) { return read(c).optBoolean("darkGlobal", false); }

    public static void setDarkGlobal(Context c, boolean on) {
        JSONObject o = read(c);
        try { o.put("darkGlobal", on); } catch (Exception ignored) {}
        write(c, o);
    }

    public static Map<String, Boolean> darkSites(Context c) {
        Map<String, Boolean> m = new LinkedHashMap<>();
        JSONObject s = read(c).optJSONObject("darkSites");
        if (s == null) return m;
        for (Iterator<String> it = s.keys(); it.hasNext(); ) {
            String k = it.next();
            Object v = s.opt(k);
            if (v instanceof Boolean) m.put(k, (Boolean) v);
        }
        return m;
    }

    public static void setSiteDark(Context c, String host, boolean on) {
        JSONObject o = read(c);
        Map<String, Boolean> next = withSiteDark(host, on, o.optBoolean("darkGlobal", false), darkSites(c));
        try { o.put("darkSites", new JSONObject(next)); } catch (Exception ignored) {}
        write(c, o);
    }

    public static boolean isDarkEnabled(Context c, String host) {
        return isDarkEnabled(host, darkGlobal(c), darkSites(c));
    }

    public static List<String> nativeHosts(Context c) {
        List<String> l = new ArrayList<>();
        JSONArray a = read(c).optJSONArray("darkNativeHosts");
        if (a != null) for (int i = 0; i < a.length(); i++) l.add(a.optString(i));
        return l;
    }

    /** dark.js 上报；返回是否有变化（有变化时重新注册注入脚本） */
    public static boolean reportDark(Context c, String host, boolean nativeDark) {
        List<String> next = updatedNativeHosts(nativeHosts(c), host, nativeDark);
        if (next == null) return false;
        JSONObject o = read(c);
        try { o.put("darkNativeHosts", new JSONArray(next)); } catch (Exception ignored) {}
        write(c, o);
        return true;
    }

    public static JSONObject darkConfig(Context c) {
        JSONObject cfg = new JSONObject();
        try {
            cfg.put("global", darkGlobal(c));
            cfg.put("sites", new JSONObject(darkSites(c)));
            cfg.put("nativeHosts", new JSONArray(nativeHosts(c)));
        } catch (Exception ignored) {}
        return cfg;
    }

    public static JSONObject readerPrefs(Context c) {
        JSONObject o = read(c);
        JSONObject p = new JSONObject();
        String t = o.optString("readerTheme", "light");
        String f = o.optString("readerFont", "sans");
        try {
            p.put("theme", contains(THEMES, t) ? t : "light");
            p.put("font", contains(FONTS, f) ? f : "sans");
            p.put("fontSize", clampFontSize(o.optInt("readerFontSize", 18)));
        } catch (Exception ignored) {}
        return p;
    }

    public static void setReaderPref(Context c, String key, Object value) {
        JSONObject o = read(c);
        try {
            if ("readerFontSize".equals(key)) o.put(key, clampFontSize((Integer) value));
            else o.put(key, value);
        } catch (Exception ignored) {}
        write(c, o);
    }

    public static String saveCategory(Context c) {
        String s = read(c).optString("saveCategory", "").trim();
        return s.isEmpty() ? DEFAULT_CATEGORY : s;
    }

    public static void setSaveCategory(Context c, String v) {
        JSONObject o = read(c);
        try { o.put("saveCategory", v == null ? "" : v.trim()); } catch (Exception ignored) {}
        write(c, o);
    }

    private static boolean contains(String[] a, String v) {
        for (String s : a) if (s.equals(v)) return true;
        return false;
    }
}
