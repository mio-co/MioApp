package xyz.mio.app.browser;

import android.content.Context;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

/**
 * 浏览器设置（文件存储，每次读盘：主进程的插件和 :browser 进程的浏览器都能看到最新值）。
 */
public final class BrowserPrefs {
    private BrowserPrefs() {}

    private static File file(Context c) { return new File(c.getFilesDir(), "mio-browser-prefs.json"); }

    private static synchronized JSONObject read(Context c) {
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

    private static synchronized void write(Context c, JSONObject o) {
        try {
            File f = file(c);
            File tmp = new File(f.getPath() + ".tmp");
            try (java.io.FileOutputStream out = new java.io.FileOutputStream(tmp)) {
                out.write(o.toString().getBytes(StandardCharsets.UTF_8));
            }
            //noinspection ResultOfMethodCallIgnored
            tmp.renameTo(f);
        } catch (Exception ignored) {}
    }

    public static boolean adblockEnabled(Context c) { return read(c).optBoolean("adblock", true); }
    public static void setAdblockEnabled(Context c, boolean v) { JSONObject o = read(c); try { o.put("adblock", v); } catch (Exception ignored) {} write(c, o); }

    public static boolean preferSystemBrowser(Context c) { return read(c).optBoolean("preferSystem", false); }
    public static void setPreferSystemBrowser(Context c, boolean v) { JSONObject o = read(c); try { o.put("preferSystem", v); } catch (Exception ignored) {} write(c, o); }

    // 通用键值（YouTube 防沉迷等独立功能用自己的键）
    public static boolean getBoolean(Context c, String key, boolean def) { return read(c).optBoolean(key, def); }
    public static void putBoolean(Context c, String key, boolean v) { JSONObject o = read(c); try { o.put(key, v); } catch (Exception ignored) {} write(c, o); }
    public static int getInt(Context c, String key, int def) { return read(c).optInt(key, def); }
    public static void putInt(Context c, String key, int v) { JSONObject o = read(c); try { o.put(key, v); } catch (Exception ignored) {} write(c, o); }

    public static List<String> allowlist(Context c) {
        List<String> out = new ArrayList<>();
        JSONArray a = read(c).optJSONArray("allowlist");
        if (a != null) for (int i = 0; i < a.length(); i++) out.add(a.optString(i));
        return out;
    }

    public static void setAllowlist(Context c, List<String> list) {
        JSONObject o = read(c);
        JSONArray a = new JSONArray();
        for (String s : list) if (!s.isEmpty()) a.put(s);
        try { o.put("allowlist", a); } catch (Exception ignored) {}
        write(c, o);
    }

    public static String normalize(String host) {
        String h = host == null ? "" : host.trim().toLowerCase(Locale.ROOT);
        if (h.contains("://")) {
            try { h = new java.net.URL(h).getHost(); } catch (Exception ignored) {}
        }
        if (h.startsWith("www.")) h = h.substring(4);
        return h;
    }

    public static String allowlistEntry(Context c, String host) {
        if (host == null || host.isEmpty()) return null;
        String h = host.toLowerCase(Locale.ROOT);
        for (String e : allowlist(c)) if (h.equals(e) || h.endsWith("." + e)) return e;
        return null;
    }

    public static void setAllowlisted(Context c, String host, boolean on) {
        String entry = normalize(host);
        List<String> list = allowlist(c);
        if (on) {
            if (!list.contains(entry)) list.add(entry);
        } else {
            List<String> keep = new ArrayList<>();
            for (String e : list) if (!(entry.equals(e) || entry.endsWith("." + e))) keep.add(e);
            list = keep;
        }
        setAllowlist(c, list);
    }
}
