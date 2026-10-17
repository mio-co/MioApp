package xyz.mio.app.browser;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.graphics.Typeface;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;
import android.text.InputType;
import android.util.Base64;
import android.util.TypedValue;
import android.view.ViewGroup;
import android.webkit.CookieManager;
import android.webkit.WebView;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.Switch;
import android.widget.TextView;
import android.widget.Toast;

import androidx.annotation.NonNull;
import androidx.webkit.JavaScriptReplyProxy;
import androidx.webkit.ScriptHandler;
import androidx.webkit.WebMessageCompat;
import androidx.webkit.WebViewCompat;
import androidx.webkit.WebViewFeature;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.Charset;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * 用户脚本管理器（Android 内置浏览器，:browser 进程），功能与 iOS / Windows 对应：
 * <ul>
 * <li>安装：粘贴代码 / 网址（Greasy Fork 脚本页、GitHub blob 自动换下载地址）/ 从文件导入（系统文件选择器）/
 * 浏览器打开 *.user.js 时提示。@require / @resource 安装时下载缓存（#sha256= 校验）；同 @name + @namespace 再装 = 就地更新。</li>
 * <li>注入：每个启用的脚本一个 document-start 脚本（WebViewCompat.addDocumentStartJavaScript，所有 frame），
 * 运行时（assets/mio-userscript-runtime.js，与 iOS 同一段）自己按 @match / @include / @exclude 判定、按 @run-at 调度。</li>
 * <li>GM 原生通道：WebMessageListener（window.mioUserScriptNative）。Android WebView 没有隔离 world，脚本都跑页面世界；
 * 每个脚本一个本进程随机 token（只写在它自己的注入代码里），原生按 id + token 认身份，页面伪造不了别的脚本。
 * GM_xmlhttpRequest 原生代发（同主机放行；@connect 声明的首次询问；未声明拒绝；默认带 WebView Cookie，anonymous 不带）。
 * GM 值写入后重新注册该脚本（注入代码带值快照，GM_getValue 才能同步返回）。</li>
 * <li>管理界面：启用 / 禁用、查看代码、检查更新、删除（连同数据）、重置跨域授权；盾牌菜单里执行 GM_registerMenuCommand 命令。</li>
 * </ul>
 * 限制：页面世界里页面 JS 能看到脚本的 window 改动和桥上的回复（与 Tampermonkey 的 @grant none 模式类似）。
 */
public final class UserScripts implements WebViewCompat.WebMessageListener {
    static final String ASSET = "mio-userscript-runtime.js";
    static final String BRIDGE = "mioUserScriptNative";
    public static final int REQUEST_IMPORT = 0x5553;

    private final Activity act;
    private final WebView webView;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService net = Executors.newFixedThreadPool(3);
    private final File dir;
    private final List<Entry> scripts = new ArrayList<>();
    private final Map<String, String> tokens = new HashMap<>();
    private final Map<String, ScriptHandler> handlers = new HashMap<>();
    private final Map<String, Map<String, String>> values = new HashMap<>();
    private final Map<String, List<String[]>> menus = new LinkedHashMap<>();
    private final Map<String, HttpURLConnection> xhrs = new ConcurrentHashMap<>();
    private final Map<String, List<java.util.function.Consumer<Boolean>>> asks = new HashMap<>();
    private final Runnable reregister = this::flushDirty;
    private final java.util.Set<String> dirty = new java.util.HashSet<>();
    private String runtime;
    private boolean supported;
    private String lastOffered;
    /** GM_xmlhttpRequest 用的 Cookie：当前 WebView 容器（Profile）的 CookieManager，由 BrowserActivity 设置 */
    private java.util.function.Supplier<CookieManager> cookies = CookieManager::getInstance;

    public void setCookieManager(java.util.function.Supplier<CookieManager> s) { if (s != null) cookies = s; }

    static final class Entry {
        String id, code, sourceURL;
        UserScriptCore.Meta meta;
        Map<String, String> requireCache = new HashMap<>(), resourceCache = new HashMap<>();
        Map<String, Boolean> decisions = new HashMap<>();
        boolean enabled = true;
        long installedAt, updatedAt, lastCheck;
    }

    static final class Pkg {
        UserScriptCore.Meta meta;
        String code, sourceURL;
        Map<String, String> requireCache = new HashMap<>(), resourceCache = new HashMap<>();
    }

    public UserScripts(Activity act, WebView webView) {
        this.act = act;
        this.webView = webView;
        dir = new File(act.getFilesDir(), "userscripts");
        load();
    }

    // ---------------------------------------------------------------- 存储

    private File file() { return new File(dir, "scripts.json"); }

    private File valueFile(String id) {
        String safe = id.replaceAll("[^A-Za-z0-9-]", "");
        return new File(new File(dir, "values"), (safe.isEmpty() ? "_" : safe) + ".json");
    }

    private static Map<String, String> strMap(JSONObject o) {
        Map<String, String> m = new HashMap<>();
        if (o == null) return m;
        for (Iterator<String> it = o.keys(); it.hasNext(); ) {
            String k = it.next();
            Object v = o.opt(k);
            if (v instanceof String) m.put(k, (String) v);
        }
        return m;
    }

    private void load() {
        scripts.clear();
        try {
            JSONArray a = new JSONArray(new String(readAll(new FileInputStream(file()), Integer.MAX_VALUE), StandardCharsets.UTF_8));
            for (int i = 0; i < a.length(); i++) {
                JSONObject o = a.optJSONObject(i);
                if (o == null) continue;
                Entry e = new Entry();
                e.id = o.optString("id");
                e.code = o.optString("code");
                try { e.meta = UserScriptCore.parse(e.code); } catch (Exception ex) { continue; }
                e.sourceURL = o.optString("sourceURL", null);
                e.enabled = o.optBoolean("enabled", true);
                e.requireCache = strMap(o.optJSONObject("requireCache"));
                e.resourceCache = strMap(o.optJSONObject("resourceCache"));
                JSONObject d = o.optJSONObject("decisions");
                if (d != null) for (Iterator<String> it = d.keys(); it.hasNext(); ) { String k = it.next(); e.decisions.put(k, d.optBoolean(k)); }
                e.installedAt = o.optLong("installedAt");
                e.updatedAt = o.optLong("updatedAt");
                e.lastCheck = o.optLong("lastCheck");
                if (!e.id.isEmpty()) scripts.add(e);
            }
        } catch (Exception ignored) {
            // 首次
        }
    }

    private void save() {
        JSONArray a = new JSONArray();
        for (Entry e : scripts) {
            try {
                a.put(new JSONObject().put("id", e.id).put("code", e.code).put("sourceURL", e.sourceURL == null ? JSONObject.NULL : e.sourceURL)
                        .put("enabled", e.enabled).put("requireCache", new JSONObject(e.requireCache)).put("resourceCache", new JSONObject(e.resourceCache))
                        .put("decisions", new JSONObject(e.decisions)).put("installedAt", e.installedAt).put("updatedAt", e.updatedAt).put("lastCheck", e.lastCheck));
            } catch (Exception ignored) {}
        }
        writeAtomic(file(), a.toString());
    }

    private static void writeAtomic(File f, String s) {
        try {
            //noinspection ResultOfMethodCallIgnored
            f.getParentFile().mkdirs();
            File tmp = new File(f.getPath() + ".tmp");
            try (OutputStream out = new FileOutputStream(tmp)) { out.write(s.getBytes(StandardCharsets.UTF_8)); }
            //noinspection ResultOfMethodCallIgnored
            tmp.renameTo(f);
        } catch (Exception ignored) {}
    }

    private Entry get(String id) {
        for (Entry e : scripts) if (e.id.equals(id)) return e;
        return null;
    }

    private Map<String, String> valuesOf(String id) {
        Map<String, String> v = values.get(id);
        if (v != null) return v;
        v = new HashMap<>();
        try {
            v = strMap(new JSONObject(new String(readAll(new FileInputStream(valueFile(id)), Integer.MAX_VALUE), StandardCharsets.UTF_8)));
        } catch (Exception ignored) {}
        values.put(id, v);
        return v;
    }

    private boolean setValue(String id, String key, String json) {
        Map<String, String> v = new HashMap<>(valuesOf(id));
        v.put(key, json);
        long size = 0;
        for (Map.Entry<String, String> e : v.entrySet()) size += e.getKey().getBytes(StandardCharsets.UTF_8).length + e.getValue().getBytes(StandardCharsets.UTF_8).length;
        if (size > UserScriptCore.MAX_VALUE_BYTES) return false;
        values.put(id, v);
        writeAtomic(valueFile(id), new JSONObject(v).toString());
        return true;
    }

    private void deleteValue(String id, String key) {
        Map<String, String> v = new HashMap<>(valuesOf(id));
        if (v.remove(key) == null) return;
        values.put(id, v);
        writeAtomic(valueFile(id), new JSONObject(v).toString());
    }

    private Entry install(Pkg p) {
        long now = System.currentTimeMillis();
        for (Entry e : scripts) {
            if (e.meta.identity().equals(p.meta.identity())) {
                e.meta = p.meta;
                e.code = p.code;
                e.requireCache = p.requireCache;
                e.resourceCache = p.resourceCache;
                if (p.sourceURL != null) e.sourceURL = p.sourceURL;
                e.updatedAt = now;
                e.decisions.keySet().removeIf(h -> !UserScriptCore.isDeclared(h, p.meta.connects, null));
                save();
                reinstall();
                return e;
            }
        }
        Entry e = new Entry();
        e.id = UUID.randomUUID().toString();
        e.meta = p.meta;
        e.code = p.code;
        e.requireCache = p.requireCache;
        e.resourceCache = p.resourceCache;
        e.sourceURL = p.sourceURL;
        e.installedAt = e.updatedAt = now;
        scripts.add(e);
        save();
        reinstall();
        return e;
    }

    private void delete(String id) {
        Entry e = get(id);
        if (e == null) return;
        scripts.remove(e);
        values.remove(id);
        //noinspection ResultOfMethodCallIgnored
        valueFile(id).delete();
        save();
        reinstall();
    }

    // ---------------------------------------------------------------- WebView

    public boolean supported() { return supported; }

    /** setupWebView 之后、加载页面之前调用（主线程） */
    public void install() {
        supported = WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)
                && WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT);
        if (!supported) return;
        try (InputStream in = act.getAssets().open(ASSET)) {
            runtime = new String(readAll(in, Integer.MAX_VALUE), StandardCharsets.UTF_8);
        } catch (Exception e) {
            supported = false;
            return;
        }
        try {
            WebViewCompat.addWebMessageListener(webView, BRIDGE, java.util.Collections.singleton("*"), this);
        } catch (Exception e) {
            android.util.Log.w("MioUserScripts", "addWebMessageListener failed", e);
            supported = false;
            return;
        }
        reinstall();
    }

    private String token(String id) {
        String t = tokens.get(id);
        if (t == null) {
            byte[] b = new byte[18];
            new SecureRandom().nextBytes(b);
            t = Base64.encodeToString(b, Base64.NO_WRAP | Base64.URL_SAFE);
            tokens.put(id, t);
        }
        return t;
    }

    private void register(Entry e) {
        ScriptHandler old = handlers.remove(e.id);
        if (old != null) old.remove();
        if (!e.enabled || runtime == null) return;
        String src = UserScriptCore.source(runtime, e.id, e.meta, e.code, e.requireCache, e.resourceCache,
                e.meta.grantsNone() ? null : valuesOf(e.id), token(e.id), BRIDGE, appVersion());
        if (src == null) return;
        try {
            handlers.put(e.id, WebViewCompat.addDocumentStartJavaScript(webView, src, java.util.Collections.singleton("*")));
        } catch (Exception ex) {
            android.util.Log.w("MioUserScripts", "addDocumentStartJavaScript failed", ex);
        }
    }

    /** 脚本列表 / 启用状态变了：全部重新注册（对之后加载的页面生效） */
    private void reinstall() {
        if (!supported) return;
        for (ScriptHandler h : handlers.values()) h.remove();
        handlers.clear();
        for (Entry e : scripts) register(e);
    }

    private void markDirty(String id) {
        dirty.add(id);
        main.removeCallbacks(reregister);
        main.postDelayed(reregister, 400);
    }

    private void flushDirty() {
        for (String id : new ArrayList<>(dirty)) { Entry e = get(id); if (e != null) register(e); }
        dirty.clear();
    }

    private String appVersion() {
        try { return act.getPackageManager().getPackageInfo(act.getPackageName(), 0).versionName; } catch (Exception e) { return ""; }
    }

    public void shutdown() {
        net.shutdownNow();
    }

    /** 主框架开始加载新页面：清掉上一页的菜单命令 */
    public void onPageStarted() {
        menus.clear();
    }

    // ---------------------------------------------------------------- GM 通道

    @Override
    public void onPostMessage(@NonNull WebView view, @NonNull WebMessageCompat message, @NonNull Uri sourceOrigin, boolean isMainFrame, @NonNull JavaScriptReplyProxy reply) {
        JSONObject m;
        try {
            m = new JSONObject(message.getData());
        } catch (Exception e) {
            return;
        }
        final String id = m.optString("id");
        final int seq = m.optInt("seq");
        Entry e = get(id);
        String t = tokens.get(id);
        if (e == null || !e.enabled || e.meta.grantsNone() || t == null || !t.equals(m.optString("token"))) {
            reply(reply, id, seq, null, "forbidden");
            return;
        }
        String op = m.optString("op");
        switch (op) {
            case "setValue": {
                Object v = m.opt("value");
                String key = m.optString("key", null);
                if (key == null || !(v instanceof String)) { reply(reply, id, seq, null, "bad value"); return; }
                if (setValue(id, key, (String) v)) { markDirty(id); reply(reply, id, seq, true, null); }
                else reply(reply, id, seq, null, "存储超出上限（每个脚本 5 MB）");
                return;
            }
            case "deleteValue":
                deleteValue(id, m.optString("key"));
                markDirty(id);
                reply(reply, id, seq, true, null);
                return;
            case "xhr":
                xhr(e, m, sourceOrigin.getHost(), reply, seq);
                return;
            case "xhrAbort": {
                String r = m.optString("reqId");
                HttpURLConnection c = r.startsWith(id + ":") ? xhrs.remove(r) : null;
                if (c != null) net.execute(c::disconnect);
                reply(reply, id, seq, true, null);
                return;
            }
            case "openTab": {
                String u = UserScriptCore.resolve(m.optString("url"), null);
                if (u == null) { reply(reply, id, seq, null, "invalid url"); return; }
                webView.loadUrl(u);
                reply(reply, id, seq, true, null);
                return;
            }
            case "setClipboard": {
                ClipboardManager cm = (ClipboardManager) act.getSystemService(Context.CLIPBOARD_SERVICE);
                String data = m.optString("data");
                if (cm != null) cm.setPrimaryClip(m.optString("type").toLowerCase(Locale.ROOT).contains("html")
                        ? ClipData.newHtmlText("userscript", data, data) : ClipData.newPlainText("userscript", data));
                reply(reply, id, seq, true, null);
                return;
            }
            case "menu": {
                if (isMainFrame) {
                    List<String[]> list = new ArrayList<>();
                    JSONArray a = m.optJSONArray("commands");
                    if (a != null) for (int i = 0; i < a.length(); i++) {
                        JSONObject c = a.optJSONObject(i);
                        if (c != null) list.add(new String[]{c.optString("id"), c.optString("name")});
                    }
                    if (list.isEmpty()) menus.remove(id); else menus.put(id, list);
                }
                reply(reply, id, seq, true, null);
                return;
            }
            default:
                reply(reply, id, seq, null, "unknown op " + op);
        }
    }

    private void reply(JavaScriptReplyProxy proxy, String sid, int seq, Object result, String error) {
        JSONObject o = new JSONObject();
        try {
            o.put("sid", sid).put("seq", seq);
            if (error != null) o.put("error", error); else o.put("result", result == null ? JSONObject.NULL : result);
        } catch (Exception ignored) {}
        final String s = o.toString();
        main.post(() -> {
            try { proxy.postMessage(s); } catch (Exception ignored) {}
        });
    }

    private void xhr(Entry e, JSONObject m, String pageHost, JavaScriptReplyProxy proxy, int seq) {
        String url = UserScriptCore.resolve(m.optString("url"), null);
        if (url == null) { reply(proxy, e.id, seq, err("不支持的地址"), null); return; }
        String host = Uri.parse(url).getHost();
        String verdict = UserScriptCore.connectVerdict(host, pageHost, e.meta.connects);
        if (verdict.equals("undeclared")) { reply(proxy, e.id, seq, err(host + " 不在脚本的 @connect 列表中，已拒绝"), null); return; }
        Runnable go = () -> net.execute(() -> reply(proxy, e.id, seq, perform(url, m), null));
        if (verdict.equals("sameOrigin")) { go.run(); return; }
        String n = UserScriptCore.normalizeHost(host);
        Boolean d = e.decisions.get(n);
        if (d != null) {
            if (d) go.run(); else reply(proxy, e.id, seq, err("已拒绝脚本访问 " + host), null);
            return;
        }
        ask(e, n, allow -> {
            if (allow) go.run(); else reply(proxy, e.id, seq, err("已拒绝脚本访问 " + host), null);
        });
    }

    private void ask(Entry e, String host, java.util.function.Consumer<Boolean> cb) {
        String key = e.id + "|" + host;
        if (asks.containsKey(key)) { asks.get(key).add(cb); return; }
        List<java.util.function.Consumer<Boolean>> list = new ArrayList<>();
        list.add(cb);
        asks.put(key, list);
        java.util.function.Consumer<Boolean> finish = allow -> {
            List<java.util.function.Consumer<Boolean>> cbs = asks.remove(key);
            if (cbs != null) for (java.util.function.Consumer<Boolean> c : cbs) c.accept(allow);
        };
        if (act.isFinishing()) { finish.accept(false); return; }
        boolean[] done = {false};
        new AlertDialog.Builder(act)
                .setTitle("允许脚本跨域访问？")
                .setMessage("用户脚本「" + e.meta.displayName() + "」想向 " + host + " 发送请求（脚本的 @connect 已声明该域名）。\n请求会带上你在该网站的 Cookie（登录状态）。")
                .setNegativeButton("拒绝", (x, w) -> { done[0] = true; e.decisions.put(host, false); save(); finish.accept(false); })
                .setNeutralButton("仅这一次", (x, w) -> { done[0] = true; finish.accept(true); })
                .setPositiveButton("总是允许", (x, w) -> { done[0] = true; e.decisions.put(host, true); save(); finish.accept(true); })
                .setOnDismissListener(x -> { if (!done[0]) finish.accept(false); })
                .show();
    }

    private static JSONObject err(String s) {
        JSONObject o = new JSONObject();
        try { o.put("error", s); } catch (Exception ignored) {}
        return o;
    }

    /** GM_xmlhttpRequest 代发（后台线程）：返回 { status, statusText, finalUrl, headers, text | base64 } 或 { error, timeout } */
    private JSONObject perform(String url, JSONObject m) {
        String reqId = m.optString("reqId");
        HttpURLConnection c = null;
        try {
            c = (HttpURLConnection) new URL(url).openConnection();
            xhrs.put(reqId, c);
            String method = m.optString("method", "GET").toUpperCase(Locale.ROOT);
            c.setRequestMethod(method.equals("PATCH") ? "POST" : method);
            if (method.equals("PATCH")) c.setRequestProperty("X-HTTP-Method-Override", "PATCH");
            int timeout = m.optInt("timeout", 0);
            c.setConnectTimeout(timeout > 0 ? timeout : 30000);
            c.setReadTimeout(timeout > 0 ? timeout : 120000);
            c.setInstanceFollowRedirects(true);
            c.setUseCaches(false);
            boolean hasUA = false, hasAuth = false;
            JSONObject h = m.optJSONObject("headers");
            if (h != null) for (Iterator<String> it = h.keys(); it.hasNext(); ) {
                String k = it.next();
                String lk = k.toLowerCase(Locale.ROOT);
                if (lk.equals("host") || lk.equals("content-length") || lk.equals("connection") || lk.equals("transfer-encoding")) continue;
                if (lk.equals("user-agent")) hasUA = true;
                if (lk.equals("authorization")) hasAuth = true;
                c.setRequestProperty(k, h.optString(k));
            }
            if (!hasUA && !m.optString("userAgent").isEmpty()) c.setRequestProperty("User-Agent", m.optString("userAgent"));
            if (!hasAuth && !m.optString("user").isEmpty()) {
                String up = m.optString("user") + ":" + m.optString("password");
                c.setRequestProperty("Authorization", "Basic " + Base64.encodeToString(up.getBytes(StandardCharsets.UTF_8), Base64.NO_WRAP));
            }
            boolean anonymous = m.optBoolean("anonymous");
            if (!anonymous) {
                String ck = cookies.get().getCookie(url);
                if (ck != null && !ck.isEmpty()) c.setRequestProperty("Cookie", ck);
            }
            JSONObject body = m.optJSONObject("body");
            if (body != null && !method.equals("GET") && !method.equals("HEAD")) {
                byte[] data = body.has("text") ? body.optString("text").getBytes(StandardCharsets.UTF_8) : Base64.decode(body.optString("base64"), Base64.DEFAULT);
                c.setDoOutput(true);
                try (OutputStream out = c.getOutputStream()) { out.write(data); }
            }
            int status = c.getResponseCode();
            InputStream in = status >= 400 ? c.getErrorStream() : c.getInputStream();
            byte[] buf = in == null ? new byte[0] : readAll(in, 64 * 1024 * 1024);
            JSONObject out = new JSONObject();
            out.put("status", status).put("statusText", c.getResponseMessage() == null ? "" : c.getResponseMessage()).put("finalUrl", c.getURL().toString());
            StringBuilder hs = new StringBuilder();
            for (Map.Entry<String, List<String>> e : c.getHeaderFields().entrySet()) {
                if (e.getKey() == null) continue;
                for (String v : e.getValue()) {
                    if (hs.length() > 0) hs.append("\r\n");
                    hs.append(e.getKey().toLowerCase(Locale.ROOT)).append(": ").append(v);
                    if (!anonymous && e.getKey().equalsIgnoreCase("set-cookie")) cookies.get().setCookie(c.getURL().toString(), v);
                }
            }
            out.put("headers", hs.toString());
            String type = m.optString("responseType").toLowerCase(Locale.ROOT);
            if (type.equals("arraybuffer") || type.equals("blob")) out.put("base64", Base64.encodeToString(buf, Base64.NO_WRAP));
            else {
                String mime = !m.optString("overrideMimeType").isEmpty() ? m.optString("overrideMimeType") : String.valueOf(c.getContentType());
                Charset cs = StandardCharsets.UTF_8;
                java.util.regex.Matcher cm = java.util.regex.Pattern.compile("charset=([^;]+)", java.util.regex.Pattern.CASE_INSENSITIVE).matcher(mime);
                if (cm.find()) { try { cs = Charset.forName(cm.group(1).trim().replace("\"", "")); } catch (Exception ignored) {} }
                out.put("text", new String(buf, cs));
            }
            return out;
        } catch (java.net.SocketTimeoutException ex) {
            JSONObject o = err("timeout");
            try { o.put("timeout", true); } catch (Exception ignored) {}
            return o;
        } catch (Exception ex) {
            if (!xhrs.containsKey(reqId)) return err("aborted");
            return err(String.valueOf(ex.getMessage()));
        } finally {
            xhrs.remove(reqId);
            if (c != null) c.disconnect();
        }
    }

    // ---------------------------------------------------------------- 下载 / 安装 / 更新（后台线程）

    static String download(String url) throws Exception {
        int hash = url.indexOf('#');
        String fragment = hash < 0 ? "" : url.substring(hash + 1);
        String target = hash < 0 ? url : url.substring(0, hash);
        HttpURLConnection c = (HttpURLConnection) new URL(target).openConnection();
        c.setConnectTimeout(30000);
        c.setReadTimeout(30000);
        c.setUseCaches(false);
        c.setRequestProperty("Accept", "text/javascript, application/javascript, text/plain, */*");
        try {
            int st = c.getResponseCode();
            if (st < 200 || st >= 300) throw new UserScriptCore.ParseException("下载失败：HTTP " + st + "（" + target + "）");
            byte[] data = readAll(c.getInputStream(), UserScriptCore.MAX_SCRIPT_BYTES + 1);
            if (data.length > UserScriptCore.MAX_SCRIPT_BYTES) throw new UserScriptCore.ParseException("文件太大");
            verifyIntegrity(data, fragment, target);
            return new String(data, StandardCharsets.UTF_8);
        } catch (UserScriptCore.ParseException e) {
            throw e;
        } catch (Exception e) {
            throw new UserScriptCore.ParseException("下载失败：" + e.getMessage());
        } finally {
            c.disconnect();
        }
    }

    static void verifyIntegrity(byte[] data, String fragment, String url) throws Exception {
        if (fragment == null || fragment.isEmpty()) return;
        for (String part : fragment.split("[,;]")) {
            java.util.regex.Matcher mm = java.util.regex.Pattern.compile("^([A-Za-z0-9]+)[=-](.+)$").matcher(part.trim());
            if (!mm.find()) continue;
            String algo = mm.group(1).toLowerCase(Locale.ROOT);
            String jalgo = algo.equals("sha256") ? "SHA-256" : algo.equals("sha384") ? "SHA-384" : algo.equals("sha512") ? "SHA-512" : null;
            if (jalgo == null) continue;
            byte[] d = MessageDigest.getInstance(jalgo).digest(data);
            StringBuilder hex = new StringBuilder();
            for (byte b : d) hex.append(String.format(Locale.ROOT, "%02x", b & 0xff));
            String want = mm.group(2);
            if (want.equalsIgnoreCase(hex.toString()) || want.equals(Base64.encodeToString(d, Base64.NO_WRAP))) return;
            throw new UserScriptCore.ParseException(Uri.parse(url).getLastPathSegment() + " 校验失败（" + algo + "）");
        }
    }

    static Pkg prepare(String code, String sourceURL) throws Exception {
        Pkg p = new Pkg();
        p.meta = UserScriptCore.parse(code);
        p.code = code;
        p.sourceURL = sourceURL;
        for (String r : p.meta.requires) {
            if (p.requireCache.containsKey(r)) continue;
            String u = UserScriptCore.resolve(r, sourceURL);
            if (u == null) throw new UserScriptCore.ParseException("下载失败：无效的 @require：" + r);
            p.requireCache.put(r, download(u));
        }
        for (Map.Entry<String, String> r : p.meta.resources.entrySet()) {
            String u = UserScriptCore.resolve(r.getValue(), sourceURL);
            if (u == null) throw new UserScriptCore.ParseException("下载失败：无效的 @resource：" + r.getValue());
            p.resourceCache.put(r.getKey(), download(u));
        }
        return p;
    }

    static Pkg checkUpdate(Entry s) throws Exception {
        String check = UserScriptCore.updateCheckURL(s.meta, s.sourceURL);
        if (check == null) throw new UserScriptCore.ParseException("脚本没有 @updateURL / @downloadURL，也不是从网址安装的");
        String text = download(check);
        UserScriptCore.Meta remote = UserScriptCore.parse(text);
        if (UserScriptCore.compareVersions(remote.version, s.meta.version) <= 0) return null;
        String path = Uri.parse(check).getPath();
        if (path != null && path.toLowerCase(Locale.ROOT).endsWith(".meta.js")) {
            String dl = UserScriptCore.downloadURL(remote, s.sourceURL);
            if (dl == null) throw new UserScriptCore.ParseException("找不到新版本的下载地址");
            return prepare(download(dl), s.sourceURL != null ? s.sourceURL : dl);
        }
        return prepare(text, s.sourceURL != null ? s.sourceURL : check);
    }

    private interface Job { Pkg run() throws Exception; }

    /** 后台准备 → 主线程确认安装 */
    private void installAsync(Job job, Runnable after) {
        Toast.makeText(act, "正在准备用户脚本…", Toast.LENGTH_SHORT).show();
        net.execute(() -> {
            try {
                Pkg p = job.run();
                main.post(() -> confirmInstall(p, after));
            } catch (Exception e) {
                main.post(() -> alert("无法安装用户脚本", String.valueOf(e.getMessage())));
            }
        });
    }

    private void confirmInstall(Pkg p, Runnable after) {
        if (act.isFinishing()) return;
        UserScriptCore.Meta m = p.meta;
        Entry old = null;
        for (Entry e : scripts) if (e.meta.identity().equals(m.identity())) old = e;
        StringBuilder sb = new StringBuilder();
        if (!m.version.isEmpty()) sb.append("版本：").append(m.version).append(old != null && !old.meta.version.isEmpty() ? "（已安装 " + old.meta.version + "）" : "").append('\n');
        if (!m.author.isEmpty()) sb.append("作者：").append(m.author).append('\n');
        if (!m.description.isEmpty()) sb.append(m.description).append('\n');
        List<String> where = new ArrayList<>(m.matches);
        where.addAll(m.includes);
        sb.append("运行于：").append(where.isEmpty() ? "所有网页" : android.text.TextUtils.join("、", where.subList(0, Math.min(6, where.size()))) + (where.size() > 6 ? " …" : "")).append('\n');
        if (!m.grantsNone()) sb.append("权限：").append(android.text.TextUtils.join("、", m.grants)).append('\n');
        if (!m.connects.isEmpty()) sb.append("可访问的域名：").append(android.text.TextUtils.join("、", m.connects)).append('\n');
        List<String> bad = UserScriptCore.rules(m).invalid;
        if (!bad.isEmpty()) sb.append("⚠️ 忽略无效规则：").append(android.text.TextUtils.join("、", bad)).append('\n');
        sb.append("\n只安装你信任的脚本：脚本可以读取和修改它运行的网页。");
        new AlertDialog.Builder(act)
                .setTitle((old != null ? "更新：" : "安装：") + m.displayName())
                .setMessage(sb.toString())
                .setNegativeButton("取消", null)
                .setPositiveButton(old != null ? "更新" : "安装", (d, w) -> {
                    install(p);
                    Toast.makeText(act, "已安装「" + m.displayName() + "」，刷新页面后生效", Toast.LENGTH_LONG).show();
                    if (after != null) after.run();
                })
                .show();
    }

    private void alert(String title, String msg) {
        if (act.isFinishing()) return;
        new AlertDialog.Builder(act).setTitle(title).setMessage(msg).setPositiveButton("好", null).show();
    }

    /** 主框架要打开 *.user.js：询问安装（返回 true = 已接管，不再加载） */
    public boolean maybeOfferInstall(String url) {
        if (!UserScriptCore.looksLikeUserScript(url)) return false;
        if (url.equals(lastOffered)) return true;
        lastOffered = url;
        main.postDelayed(() -> { if (url.equals(lastOffered)) lastOffered = null; }, 3000);
        String u = UserScriptCore.installURL(url);
        installAsync(() -> prepare(download(u), u), null);
        return true;
    }

    public void onActivityResult(int requestCode, int resultCode, Intent data, Runnable after) {
        if (requestCode != REQUEST_IMPORT || resultCode != Activity.RESULT_OK || data == null || data.getData() == null) return;
        Uri uri = data.getData();
        installAsync(() -> {
            try (InputStream in = act.getContentResolver().openInputStream(uri)) {
                if (in == null) throw new UserScriptCore.ParseException("无法读取文件");
                byte[] b = readAll(in, UserScriptCore.MAX_SCRIPT_BYTES + 1);
                if (b.length > UserScriptCore.MAX_SCRIPT_BYTES) throw new UserScriptCore.ParseException("文件太大");
                return prepare(new String(b, StandardCharsets.UTF_8), null);
            }
        }, after);
    }

    // ---------------------------------------------------------------- 界面

    /** 浏览器设置对话框里的入口 */
    public void addSettingsRow(LinearLayout box) {
        TextView title = new TextView(act);
        title.setText("\n用户脚本（Tampermonkey / Greasemonkey 格式 .user.js）");
        title.setTypeface(Typeface.DEFAULT_BOLD);
        box.addView(title);
        Button b = new Button(act);
        b.setText(supported ? "用户脚本（" + scripts.size() + "）…" : "用户脚本（系统 WebView 版本过旧，不可用）");
        b.setEnabled(supported);
        b.setOnClickListener(v -> showManager());
        box.addView(b);
    }

    /** 盾牌菜单条目：本页脚本命令 + 管理入口 */
    public void addMenuItems(String url, List<String> items, List<Runnable> actions) {
        if (!supported) return;
        for (Entry e : scripts) {
            List<String[]> cmds = menus.get(e.id);
            if (cmds == null || !e.enabled) continue;
            for (String[] c : cmds) {
                items.add("⚙ " + e.meta.displayName() + " › " + c[1]);
                actions.add(() -> webView.evaluateJavascript("(function(){var m=window.__mioUserScriptMenus;if(m&&m[" + JSONObject.quote(e.id) + "])m["
                        + JSONObject.quote(e.id) + "](" + JSONObject.quote(c[0]) + ");})();void 0", null));
            }
        }
        int running = 0;
        if (url != null) for (Entry e : scripts) if (e.enabled && UserScriptCore.rules(e.meta).matches(url)) running++;
        items.add(running > 0 ? "用户脚本（本页 " + running + " 个）…" : "用户脚本…");
        actions.add(this::showManager);
    }

    private int dp(float v) {
        return (int) TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, act.getResources().getDisplayMetrics());
    }

    private AlertDialog managerDialog;

    public void showManager() {
        if (managerDialog != null && managerDialog.isShowing()) managerDialog.dismiss();
        ScrollView scroll = new ScrollView(act);
        LinearLayout box = new LinearLayout(act);
        box.setOrientation(LinearLayout.VERTICAL);
        box.setPadding(dp(20), dp(8), dp(20), dp(8));
        scroll.addView(box);

        LinearLayout row = new LinearLayout(act);
        row.setOrientation(LinearLayout.HORIZONTAL);
        Button fromUrl = new Button(act);
        fromUrl.setText("网址");
        fromUrl.setOnClickListener(v -> promptUrl());
        Button paste = new Button(act);
        paste.setText("粘贴");
        paste.setOnClickListener(v -> promptCode());
        Button file = new Button(act);
        file.setText("文件");
        file.setOnClickListener(v -> {
            Intent i = new Intent(Intent.ACTION_OPEN_DOCUMENT);
            i.addCategory(Intent.CATEGORY_OPENABLE);
            i.setType("*/*");
            try { act.startActivityForResult(i, REQUEST_IMPORT); } catch (Exception e) { Toast.makeText(act, "没有可用的文件选择器", Toast.LENGTH_SHORT).show(); }
        });
        for (Button b : new Button[]{fromUrl, paste, file}) row.addView(b, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1));
        box.addView(row);

        TextView note = new TextView(act);
        note.setText("从网址（.user.js、Greasy Fork 脚本页、GitHub 链接）、粘贴代码或文件安装。修改对之后打开 / 刷新的页面生效。只安装你信任的脚本。");
        note.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
        box.addView(note);

        if (scripts.isEmpty()) {
            TextView empty = new TextView(act);
            empty.setText("\n还没有安装用户脚本");
            box.addView(empty);
        }
        for (Entry e : new ArrayList<>(scripts)) {
            Switch sw = new Switch(act);
            sw.setText(e.meta.displayName() + (e.meta.version.isEmpty() ? "" : "  v" + e.meta.version));
            sw.setTypeface(Typeface.DEFAULT_BOLD);
            sw.setChecked(e.enabled);
            sw.setOnCheckedChangeListener((b, on) -> { e.enabled = on; save(); reinstall(); });
            box.addView(sw);
            StringBuilder sub = new StringBuilder();
            if (!e.meta.description.isEmpty()) sub.append(e.meta.description).append('\n');
            List<String> where = new ArrayList<>(e.meta.matches);
            where.addAll(e.meta.includes);
            sub.append("运行于：").append(where.isEmpty() ? "所有网页" : android.text.TextUtils.join("、", where.subList(0, Math.min(4, where.size()))) + (where.size() > 4 ? " …" : ""));
            if (!e.meta.grantsNone()) sub.append("\n权限：").append(android.text.TextUtils.join("、", e.meta.grants));
            if (!e.decisions.isEmpty()) {
                List<String> d = new ArrayList<>();
                for (Map.Entry<String, Boolean> x : e.decisions.entrySet()) d.add(x.getKey() + (x.getValue() ? "✓" : "✗"));
                sub.append("\n跨域授权：").append(android.text.TextUtils.join("、", d));
            }
            List<String> bad = UserScriptCore.rules(e.meta).invalid;
            if (!bad.isEmpty()) sub.append("\n⚠️ 忽略无效规则：").append(android.text.TextUtils.join("、", bad));
            TextView info = new TextView(act);
            info.setText(sub.toString());
            info.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
            box.addView(info);

            LinearLayout acts = new LinearLayout(act);
            acts.setOrientation(LinearLayout.HORIZONTAL);
            Button code = small("代码", v -> {
                TextView t = new TextView(act);
                t.setText(e.code);
                t.setTextIsSelectable(true);
                t.setTypeface(Typeface.MONOSPACE);
                t.setTextSize(TypedValue.COMPLEX_UNIT_SP, 11);
                t.setPadding(dp(16), dp(8), dp(16), dp(8));
                ScrollView sv = new ScrollView(act);
                sv.addView(t);
                new AlertDialog.Builder(act).setTitle(e.meta.displayName()).setView(sv).setPositiveButton("关闭", null).show();
            });
            acts.addView(code);
            if (UserScriptCore.updateCheckURL(e.meta, e.sourceURL) != null) {
                acts.addView(small("更新", v -> {
                    Toast.makeText(act, "正在检查更新…", Toast.LENGTH_SHORT).show();
                    net.execute(() -> {
                        try {
                            Pkg p = checkUpdate(e);
                            main.post(() -> {
                                e.lastCheck = System.currentTimeMillis();
                                save();
                                if (p == null) Toast.makeText(act, "「" + e.meta.displayName() + "」已是最新版本", Toast.LENGTH_LONG).show();
                                else { install(p); Toast.makeText(act, "已更新到 " + p.meta.version, Toast.LENGTH_LONG).show(); showManager(); }
                            });
                        } catch (Exception ex) {
                            main.post(() -> alert("检查更新失败", String.valueOf(ex.getMessage())));
                        }
                    });
                }));
            }
            if (!e.decisions.isEmpty()) acts.addView(small("重置授权", v -> { e.decisions.clear(); save(); showManager(); }));
            acts.addView(small("删除", v -> new AlertDialog.Builder(act)
                    .setMessage("删除「" + e.meta.displayName() + "」及其保存的数据？")
                    .setNegativeButton("取消", null)
                    .setPositiveButton("删除", (d, w) -> { delete(e.id); showManager(); })
                    .show()));
            box.addView(acts);
        }

        AlertDialog.Builder b = new AlertDialog.Builder(act).setTitle("用户脚本").setView(scroll).setPositiveButton("完成", null);
        if (!scripts.isEmpty()) b.setNeutralButton("检查全部更新", (d, w) -> updateAll());
        managerDialog = b.show();
    }

    private Button small(String text, android.view.View.OnClickListener l) {
        Button b = new Button(act);
        b.setText(text);
        b.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
        b.setAllCaps(false);
        b.setOnClickListener(l);
        return b;
    }

    private void updateAll() {
        List<Entry> list = new ArrayList<>(scripts);
        Toast.makeText(act, "正在检查更新…", Toast.LENGTH_SHORT).show();
        net.execute(() -> {
            StringBuilder sb = new StringBuilder();
            List<Pkg> updates = new ArrayList<>();
            for (Entry e : list) {
                if (UserScriptCore.updateCheckURL(e.meta, e.sourceURL) == null) continue;
                try {
                    Pkg p = checkUpdate(e);
                    if (p == null) sb.append("「").append(e.meta.displayName()).append("」已是最新\n");
                    else { updates.add(p); sb.append("「").append(e.meta.displayName()).append("」→ ").append(p.meta.version).append('\n'); }
                } catch (Exception ex) {
                    sb.append("「").append(e.meta.displayName()).append("」：").append(ex.getMessage()).append('\n');
                }
            }
            main.post(() -> {
                for (Pkg p : updates) install(p);
                alert("检查更新", sb.length() == 0 ? "没有可检查更新的脚本" : sb.toString().trim());
            });
        });
    }

    private void promptUrl() {
        EditText in = new EditText(act);
        in.setHint("https://…/script.user.js");
        in.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI);
        in.setSingleLine(true);
        new AlertDialog.Builder(act).setTitle("从网址安装").setView(in).setNegativeButton("取消", null)
                .setPositiveButton("安装", (d, w) -> {
                    String u = UserScriptCore.installURL(in.getText().toString());
                    if (u == null) { Toast.makeText(act, "请输入 http(s) 网址", Toast.LENGTH_SHORT).show(); return; }
                    installAsync(() -> prepare(download(u), u), this::showManager);
                }).show();
    }

    private void promptCode() {
        EditText in = new EditText(act);
        in.setHint("// ==UserScript==\n// @name …\n// ==/UserScript==");
        in.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_MULTI_LINE | InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS);
        in.setMinLines(6);
        in.setTypeface(Typeface.MONOSPACE);
        in.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
        new AlertDialog.Builder(act).setTitle("粘贴用户脚本").setView(in).setNegativeButton("取消", null)
                .setPositiveButton("安装", (d, w) -> {
                    String code = in.getText().toString();
                    installAsync(() -> prepare(code, null), this::showManager);
                }).show();
    }

    // ---------------------------------------------------------------- util

    static byte[] readAll(InputStream in, int max) throws java.io.IOException {
        try {
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) > 0) {
                out.write(buf, 0, n);
                if (out.size() > max) break;
            }
            return out.toByteArray();
        } finally {
            in.close();
        }
    }
}
