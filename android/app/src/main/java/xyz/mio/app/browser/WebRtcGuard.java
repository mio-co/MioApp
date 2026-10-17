package xyz.mio.app.browser;

import android.app.Activity;
import android.content.Context;
import android.webkit.WebView;
import android.widget.LinearLayout;
import android.widget.Switch;

import androidx.webkit.ScriptHandler;
import androidx.webkit.WebViewCompat;
import androidx.webkit.WebViewFeature;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Locale;
import java.util.TreeSet;

/**
 * WebRTC 控制（与 iOS 的 MioWebRTCGuard.swift 同一段脚本：assets/mio-webrtc-guard.js，由 scripts/sync-webrtc-guard.mjs 生成）。
 * 所有 frame、document-start（WebViewCompat.addDocumentStartJavaScript，规则 "*"）注入；总开关默认开，按站点放行（含子域名）。
 * 设置存 files/mio-webrtc.json（:browser 进程独占读写）。
 */
public final class WebRtcGuard {
    static final String ASSET = "mio-webrtc-guard.js";
    static final String PLACEHOLDER = "__MIO_WEBRTC_CONFIG__";
    /** 常见网页通话站点（设置里一键放行） */
    static final String[][] PRESETS = {
            {"Google Meet", "meet.google.com"}, {"Zoom", "zoom.us"}, {"Microsoft Teams", "teams.microsoft.com"},
            {"Discord", "discord.com"}, {"Jitsi Meet", "meet.jit.si"}, {"Whereby", "whereby.com"},
    };

    private static String template;
    private ScriptHandler handler;

    // ---------------------------------------------------------------- 纯逻辑（单测）

    /** 用户输入（域名或网址）→ 小写主机名，去掉 www. / 端口 / 末尾的点 */
    static String normalize(String input) {
        if (input == null) return "";
        String h = input.trim().toLowerCase(Locale.ROOT);
        int i = h.indexOf("://");
        if (i >= 0) h = h.substring(i + 3);
        for (char c : new char[]{'/', '?', '#'}) {
            int j = h.indexOf(c);
            if (j >= 0) h = h.substring(0, j);
        }
        int at = h.lastIndexOf('@');
        if (at >= 0) h = h.substring(at + 1);
        int colon = h.lastIndexOf(':');
        if (colon >= 0 && !h.contains("]")) h = h.substring(0, colon);
        while (h.endsWith(".")) h = h.substring(0, h.length() - 1);
        if (h.startsWith("*.")) h = h.substring(2);
        if (h.startsWith("www.")) h = h.substring(4);
        return h;
    }

    /** 覆盖 host 的放行条目（host 本身或其父域），没有返回 null */
    static String entryFor(String host, List<String> list) {
        if (host == null) return null;
        String h = host.toLowerCase(Locale.ROOT);
        while (h.endsWith(".")) h = h.substring(0, h.length() - 1);
        if (h.isEmpty()) return null;
        for (String e : list) {
            if (h.equals(e) || h.endsWith("." + e)) return e;
        }
        return null;
    }

    /** {"allow":["a.com","b.org"]}（与 iOS 端 JSONSerialization 的输出一致） */
    static String configJson(List<String> allow) {
        StringBuilder sb = new StringBuilder("{\"allow\":[");
        for (int i = 0; i < allow.size(); i++) {
            if (i > 0) sb.append(',');
            sb.append('"');
            for (char c : allow.get(i).toCharArray()) {
                if (c == '"' || c == '\\') sb.append('\\').append(c);
                else if (c < 0x20) sb.append(String.format(Locale.ROOT, "\\u%04x", (int) c));
                else sb.append(c);
            }
            sb.append('"');
        }
        return sb.append("]}").toString();
    }

    static String buildScript(String tpl, List<String> allow) {
        return tpl.replace(PLACEHOLDER, configJson(allow));
    }

    // ---------------------------------------------------------------- 设置

    private static File file(Context c) { return new File(c.getFilesDir(), "mio-webrtc.json"); }

    private static synchronized JSONObject read(Context c) {
        File f = file(c);
        if (!f.exists()) return new JSONObject();
        try (FileInputStream in = new FileInputStream(f)) {
            return new JSONObject(new String(readAll(in), StandardCharsets.UTF_8));
        } catch (Exception e) {
            return new JSONObject();
        }
    }

    private static synchronized void write(Context c, JSONObject o) {
        try {
            File f = file(c);
            File tmp = new File(f.getPath() + ".tmp");
            try (FileOutputStream out = new FileOutputStream(tmp)) { out.write(o.toString().getBytes(StandardCharsets.UTF_8)); }
            //noinspection ResultOfMethodCallIgnored
            tmp.renameTo(f);
        } catch (Exception ignored) {}
    }

    public static boolean enabled(Context c) { return read(c).optBoolean("enabled", true); }

    public static void setEnabled(Context c, boolean on) {
        JSONObject o = read(c);
        try { o.put("enabled", on); } catch (Exception ignored) {}
        write(c, o);
    }

    public static List<String> allowlist(Context c) {
        List<String> out = new ArrayList<>();
        JSONArray a = read(c).optJSONArray("allow");
        if (a != null) for (int i = 0; i < a.length(); i++) {
            String h = normalize(a.optString(i));
            if (!h.isEmpty()) out.add(h);
        }
        return out;
    }

    public static boolean isAllowed(Context c, String host) { return entryFor(host, allowlist(c)) != null; }

    public static void setAllowed(Context c, String host, boolean allow) {
        TreeSet<String> set = new TreeSet<>(allowlist(c));
        if (allow) {
            String h = normalize(host);
            if (h.isEmpty()) return;
            set.add(h);
        } else {
            String h = host == null ? "" : host.toLowerCase(Locale.ROOT);
            String n = normalize(host);
            set.removeIf(e -> h.equals(e) || h.endsWith("." + e) || n.equals(e));
        }
        JSONObject o = read(c);
        try { o.put("allow", new JSONArray(new ArrayList<>(set))); } catch (Exception ignored) {}
        write(c, o);
    }

    /** 要注入的代码；总开关关掉时 null */
    static String script(Context c) {
        if (!enabled(c)) return null;
        if (template == null) {
            try (InputStream in = c.getAssets().open(ASSET)) {
                template = new String(readAll(in), StandardCharsets.UTF_8);
            } catch (Exception e) {
                return null;
            }
        }
        return buildScript(template, allowlist(c));
    }

    private static byte[] readAll(InputStream in) throws java.io.IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        byte[] buf = new byte[8192];
        int n;
        while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
        return out.toByteArray();
    }

    // ---------------------------------------------------------------- WebView

    /** （重新）注册 document-start 脚本：设置变了调用一次，下一次加载页面生效 */
    public void install(Context c, WebView webView) {
        if (handler != null) { handler.remove(); handler = null; }
        if (!WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) return;
        String js = script(c);
        if (js == null) return;
        try {
            handler = WebViewCompat.addDocumentStartJavaScript(webView, js, Collections.singleton("*"));
        } catch (Exception ignored) {}
    }

    /** 浏览器设置对话框里的开关：总开关 + 当前站点放行 + 常见通话站点 */
    public void addSettingsRows(Activity a, LinearLayout box, String host, WebView webView) {
        Switch master = new Switch(a);
        master.setText("屏蔽 WebRTC（防真实 IP 泄露，摄像头 / 麦克风也会被拒绝）");
        master.setChecked(enabled(a));
        master.setOnCheckedChangeListener((b, on) -> { setEnabled(a, on); install(a, webView); });
        box.addView(master);
        if (host != null) {
            Switch site = new Switch(a);
            site.setText("允许 " + host + " 使用 WebRTC（网页通话）");
            site.setChecked(isAllowed(a, host));
            site.setOnCheckedChangeListener((b, on) -> { setAllowed(a, host, on); install(a, webView); });
            box.addView(site);
        }
        for (String[] p : PRESETS) {
            Switch s = new Switch(a);
            s.setText("放行 " + p[0] + "（" + p[1] + "）");
            s.setChecked(allowlist(a).contains(p[1]));
            s.setOnCheckedChangeListener((b, on) -> { setAllowed(a, p[1], on); install(a, webView); });
            box.addView(s);
        }
    }
}
