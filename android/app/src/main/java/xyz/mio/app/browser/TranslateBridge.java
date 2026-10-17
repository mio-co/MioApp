package xyz.mio.app.browser;

import android.app.Activity;
import android.app.AlertDialog;
import android.graphics.Typeface;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;
import android.text.InputType;
import android.util.TypedValue;
import android.view.View;
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
import java.net.SocketTimeoutException;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * 内置浏览器的翻译（网页双语 / 划词 / YouTube 双语字幕）。
 * 页面脚本 assets/translate/mio-translate.js（= 仓库 shared/translate/），WebViewCompat.addDocumentStartJavaScript 注入（页面脚本之前）；
 * 脚本经 WebMessageListener（window.mioTranslateNative）调原生：带每次启动随机的 token，只接受主框架；
 * 网络请求在原生发（HttpURLConnection，不受页面 CSP / CORS 影响），只放行翻译引擎域名 + 用户配置的 OpenAI 地址；
 * OpenAI Key 用 Keystore 加密保存（TranslatePrefs），只在这里加到请求头。
 * 需要 WebView 支持 WEB_MESSAGE_LISTENER 和 DOCUMENT_START_SCRIPT（WebView 87+），不支持时翻译按钮提示不可用。
 */
public final class TranslateBridge implements WebViewCompat.WebMessageListener {
    private static final String OBJECT = "mioTranslateNative";
    private static final String ASSET = "translate/mio-translate.js";
    // 缓存只在 io 线程读写
    private static TranslateCore.Lru cache;
    private static File cacheFile;
    private static boolean cacheDirty;

    private final Activity activity;
    private final WebView webView;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService net = Executors.newFixedThreadPool(3);
    private final ExecutorService io = Executors.newSingleThreadExecutor();
    private final String token;
    private String template;
    private String userAgent = "";
    private ScriptHandler handler;
    private boolean supported;

    public TranslateBridge(Activity activity, WebView webView) {
        this.activity = activity;
        this.webView = webView;
        byte[] b = new byte[24];
        new SecureRandom().nextBytes(b);
        StringBuilder sb = new StringBuilder();
        for (byte x : b) sb.append(String.format("%02x", x & 0xff));
        token = sb.toString();
        if (cacheFile == null) cacheFile = new File(activity.getCacheDir(), "mio-translate-cache.json");
    }

    public boolean supported() { return supported; }

    /** setupWebView 里、加载页面之前调用（主线程） */
    public void install() {
        supported = WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)
                && WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT);
        if (!supported) return;
        template = readAsset();
        if (template == null) {
            supported = false;
            return;
        }
        userAgent = webView.getSettings().getUserAgentString();
        try {
            WebViewCompat.addWebMessageListener(webView, OBJECT, Collections.singleton("*"), this);
        } catch (Exception e) {
            android.util.Log.w("MioTranslate", "addWebMessageListener failed", e);
            supported = false;
            return;
        }
        reinstallScript();
    }

    private String readAsset() {
        try (InputStream in = activity.getAssets().open(ASSET)) {
            return new String(readAll(in, Integer.MAX_VALUE), StandardCharsets.UTF_8);
        } catch (Exception e) {
            android.util.Log.w("MioTranslate", "asset missing: " + ASSET);
            return null;
        }
    }

    /** 设置变了：重新注册注入脚本（下次加载页面用新配置），并把可热切换的项推给当前页面 */
    public void reinstallScript() {
        if (!supported) return;
        if (handler != null) {
            handler.remove();
            handler = null;
        }
        String s = TranslateCore.script(template, TranslatePrefs.configBase64(activity, token));
        if (s == null) return;
        try {
            handler = WebViewCompat.addDocumentStartJavaScript(webView, s, Collections.singleton("*"));
        } catch (Exception e) {
            android.util.Log.w("MioTranslate", "addDocumentStartJavaScript failed", e);
        }
        pushLive();
    }

    private void pushLive() {
        try {
            JSONObject p = new JSONObject();
            p.put("selection", TranslatePrefs.selection(activity));
            p.put("display", TranslatePrefs.display(activity));
            p.put("autoSites", new JSONArray(TranslatePrefs.autoSites(activity)));
            p.put("ytSubs", TranslatePrefs.ytSubs(activity));
            webView.evaluateJavascript("window.__mioTranslate && window.__mioTranslate.configure(" + p + "); void 0", null);
        } catch (Exception ignored) {}
    }

    public void shutdown() {
        net.shutdownNow();
        io.execute(TranslateBridge::saveCacheNow);
        io.shutdown();
    }

    // ------------------------------------------------------------------ messages

    @Override
    public void onPostMessage(@NonNull WebView view, @NonNull WebMessageCompat message, @NonNull Uri sourceOrigin, boolean isMainFrame, @NonNull JavaScriptReplyProxy reply) {
        if (!isMainFrame) return;
        JSONObject m;
        try {
            m = new JSONObject(message.getData());
        } catch (Exception e) {
            return;
        }
        final int id = m.optInt("id");
        if (!token.equals(m.optString("t"))) {
            reply(reply, id, err("forbidden"));
            return;
        }
        String op = m.optString("op");
        switch (op) {
            case "fetch": {
                final JSONObject req = m.optJSONObject("req");
                net.execute(() -> reply(reply, id, req == null ? err("bad request") : fetch(req)));
                break;
            }
            case "cacheGet": {
                final JSONArray keys = m.optJSONArray("keys");
                io.execute(() -> reply(reply, id, cacheGet(keys)));
                break;
            }
            case "cachePut": {
                final JSONObject entries = m.optJSONObject("entries");
                io.execute(() -> cachePut(entries));
                reply(reply, id, ok());
                break;
            }
            case "setPref":
                if ("ytSubs".equals(m.optString("key")) && m.opt("value") instanceof Boolean) {
                    TranslatePrefs.setYtSubs(activity, m.optBoolean("value"));
                    reply(reply, id, ok());
                } else {
                    reply(reply, id, err("unknown pref"));
                }
                break;
            default:
                reply(reply, id, err("unknown op"));
        }
    }

    private void reply(JavaScriptReplyProxy proxy, int id, JSONObject o) {
        try { o.put("id", id); } catch (Exception ignored) {}
        final String s = o.toString();
        main.post(() -> {
            try { proxy.postMessage(s); } catch (Exception ignored) {}
        });
    }

    private static JSONObject err(String e) {
        JSONObject o = new JSONObject();
        try { o.put("error", e); } catch (Exception ignored) {}
        return o;
    }

    private static JSONObject ok() {
        JSONObject o = new JSONObject();
        try { o.put("ok", true); } catch (Exception ignored) {}
        return o;
    }

    private static byte[] readAll(InputStream in, int max) throws java.io.IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        byte[] buf = new byte[16384];
        int n;
        while ((n = in.read(buf)) > 0) {
            int room = Math.max(0, max - out.size());
            out.write(buf, 0, Math.min(n, room));
            if (out.size() >= max) break;
        }
        return out.toByteArray();
    }

    JSONObject fetch(JSONObject req) {
        Map<String, String> headers = new LinkedHashMap<>();
        JSONObject h = req.optJSONObject("headers");
        if (h != null) {
            for (Iterator<String> it = h.keys(); it.hasNext(); ) {
                String k = it.next();
                headers.put(k, h.optString(k));
            }
        }
        List<String> picks = null;
        JSONArray pa = req.optJSONArray("pick");
        if (pa != null) {
            picks = new ArrayList<>();
            for (int i = 0; i < pa.length(); i++) picks.add(pa.optString(i));
        }
        String body = req.has("body") && !req.isNull("body") ? req.optString("body") : null;
        String auth = req.has("auth") && !req.isNull("auth") ? req.optString("auth") : null;
        TranslateCore.Checked c = TranslateCore.check(req.optString("url", null), req.optString("method", "GET"), headers, body,
                req.optDouble("timeoutMs", 15000), auth, picks, TranslatePrefs.openaiBase(activity));
        if (!c.ok()) return err(c.error);
        HttpURLConnection con = null;
        try {
            con = (HttpURLConnection) new URL(c.url).openConnection();
            con.setConnectTimeout(c.timeoutMs);
            con.setReadTimeout(c.timeoutMs);
            con.setRequestMethod(c.method);
            con.setInstanceFollowRedirects(true);
            con.setUseCaches(false);
            if (!userAgent.isEmpty()) con.setRequestProperty("User-Agent", userAgent);
            for (Map.Entry<String, String> e : c.headers.entrySet()) con.setRequestProperty(e.getKey(), e.getValue());
            if (c.openAIAuth) {
                String key = TranslatePrefs.key(activity);
                if (key == null || key.isEmpty()) return err("没有设置 API Key");
                con.setRequestProperty("Authorization", "Bearer " + key);
            }
            if (c.body != null) {
                con.setDoOutput(true);
                byte[] data = c.body.getBytes(StandardCharsets.UTF_8);
                con.setFixedLengthStreamingMode(data.length);
                try (OutputStream out = con.getOutputStream()) { out.write(data); }
            }
            int status = con.getResponseCode();
            InputStream in = status >= 400 ? con.getErrorStream() : con.getInputStream();
            String text = "";
            if (in != null) {
                try { text = new String(readAll(in, TranslateCore.MAX_RESPONSE), StandardCharsets.UTF_8); } finally { in.close(); }
            }
            JSONObject o = new JSONObject();
            o.put("status", status);
            if (c.picks != null) {
                JSONArray arr = new JSONArray();
                for (List<String> g : TranslateCore.runPicks(text, c.picks)) arr.put(g == null ? JSONObject.NULL : new JSONArray(g));
                o.put("picks", arr);
            } else {
                o.put("body", text);
            }
            return o;
        } catch (SocketTimeoutException e) {
            return err("timeout");
        } catch (Exception e) {
            return err(String.valueOf(e.getMessage()));
        } finally {
            if (con != null) con.disconnect();
        }
    }

    // ------------------------------------------------------------------ cache（io 线程）

    private static TranslateCore.Lru cache() {
        if (cache != null) return cache;
        cache = new TranslateCore.Lru(20000);
        try (FileInputStream in = new FileInputStream(cacheFile)) {
            JSONArray arr = new JSONArray(new String(readAll(in, 64 * 1024 * 1024), StandardCharsets.UTF_8));
            for (int i = 0; i < arr.length(); i++) {
                JSONArray p = arr.optJSONArray(i);
                if (p != null && p.length() == 2) cache.putChecked(p.optString(0), p.optString(1));
            }
        } catch (Exception ignored) {}
        return cache;
    }

    private static JSONObject cacheGet(JSONArray keys) {
        JSONObject values = new JSONObject();
        TranslateCore.Lru l = cache();
        if (keys != null) {
            for (int i = 0; i < Math.min(500, keys.length()); i++) {
                String k = keys.optString(i);
                String v = l.getTouch(k);
                if (v != null) {
                    try { values.put(k, v); } catch (Exception ignored) {}
                }
            }
        }
        JSONObject o = new JSONObject();
        try { o.put("values", values); } catch (Exception ignored) {}
        return o;
    }

    private void cachePut(JSONObject entries) {
        if (entries == null) return;
        TranslateCore.Lru l = cache();
        int n = 0;
        for (Iterator<String> it = entries.keys(); it.hasNext() && n < 500; n++) {
            String k = it.next();
            l.putChecked(k, entries.optString(k));
        }
        if (!cacheDirty) {
            cacheDirty = true;
            main.postDelayed(() -> {
                if (!io.isShutdown()) io.execute(TranslateBridge::saveCacheNow);
            }, 3000);
        }
    }

    private static void saveCacheNow() {
        if (cache == null || cacheFile == null || !cacheDirty) return;
        cacheDirty = false;
        JSONArray arr = new JSONArray();
        synchronized (cache) {
            for (Map.Entry<String, String> e : cache.entrySet()) {
                JSONArray p = new JSONArray();
                p.put(e.getKey());
                p.put(e.getValue());
                arr.put(p);
            }
        }
        try (FileOutputStream out = new FileOutputStream(cacheFile)) {
            out.write(arr.toString().getBytes(StandardCharsets.UTF_8));
        } catch (Exception ignored) {}
    }

    private void clearCache() {
        io.execute(() -> {
            cache = new TranslateCore.Lru(20000);
            cacheDirty = false;
            //noinspection ResultOfMethodCallIgnored
            cacheFile.delete();
        });
    }

    // ------------------------------------------------------------------ UI

    private int dp(float v) {
        return (int) TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, activity.getResources().getDisplayMetrics());
    }

    private void setMode(String mode) {
        webView.evaluateJavascript("window.__mioTranslate && window.__mioTranslate.setMode('" + mode + "'); void 0", null);
    }

    private static String hostOf(String url) {
        if (url == null) return null;
        try { return Uri.parse(url).getHost(); } catch (Exception e) { return null; }
    }

    /** 底部工具栏「译」按钮 */
    public void showMenu() {
        if (!supported) {
            new AlertDialog.Builder(activity)
                    .setTitle("翻译不可用")
                    .setMessage("系统 WebView 版本过旧（需要支持 document-start 脚本和 WebMessageListener），请在应用商店更新 Android System WebView。")
                    .setPositiveButton("好", null)
                    .show();
            return;
        }
        webView.evaluateJavascript("window.__mioTranslate ? JSON.stringify(window.__mioTranslate.state()) : null", value -> {
            JSONObject st = null;
            try {
                if (value != null && !"null".equals(value)) st = new JSONObject(new JSONArray("[" + value + "]").getString(0));
            } catch (Exception ignored) {}
            final String host = hostOf(webView.getUrl());
            final String mode = st == null ? "off" : st.optString("mode", "off");
            List<String> items = new ArrayList<>();
            List<Runnable> actions = new ArrayList<>();
            if (st != null) {
                items.add("双语对照" + ("bilingual".equals(mode) ? " ✓" : ""));
                actions.add(() -> setMode("bilingual"));
                items.add("仅显示译文" + ("translation".equals(mode) ? " ✓" : ""));
                actions.add(() -> setMode("translation"));
                if (!"off".equals(mode)) {
                    items.add("显示原文");
                    actions.add(() -> setMode("off"));
                }
            }
            String norm = TranslateCore.normalizeHost(host);
            if (norm != null) {
                final boolean auto = TranslatePrefs.isAuto(activity, host);
                items.add(auto ? "不再自动翻译 " + norm : "总是翻译 " + norm);
                actions.add(() -> {
                    TranslatePrefs.setAuto(activity, host, !auto);
                    reinstallScript();
                    if (!auto && "off".equals(mode)) setMode(TranslatePrefs.display(activity));
                });
            }
            items.add("译为…（" + TranslateCore.languageName(TranslatePrefs.target(activity)) + "）");
            actions.add(() -> pickLanguage(() -> webView.reload()));
            items.add("翻译设置…");
            actions.add(this::showSettings);
            String err = st != null ? st.optString("lastError", "") : "";
            AlertDialog.Builder b = new AlertDialog.Builder(activity)
                    .setTitle("翻译 → " + TranslateCore.languageName(TranslatePrefs.target(activity)) + (st == null ? "（页面加载完成后可用）" : ""))
                    .setItems(items.toArray(new String[0]), (d, which) -> actions.get(which).run());
            if (!err.isEmpty()) b.setMessage("上次失败：" + err);
            b.show();
        });
    }

    private void pickLanguage(Runnable done) {
        final String cur = TranslatePrefs.target(activity);
        String[] names = new String[TranslateCore.LANGS.length];
        int checked = 0;
        for (int i = 0; i < names.length; i++) {
            names[i] = TranslateCore.LANGS[i][1];
            if (TranslateCore.LANGS[i][0].equals(cur)) checked = i;
        }
        new AlertDialog.Builder(activity)
                .setTitle("翻译成")
                .setSingleChoiceItems(names, checked, (d, which) -> {
                    d.dismiss();
                    String code = TranslateCore.LANGS[which][0];
                    if (code.equals(cur)) return;
                    TranslatePrefs.setTarget(activity, code);
                    reinstallScript();
                    if (done != null) done.run();
                })
                .setNegativeButton("取消", null)
                .show();
    }

    private TextView note(String text) {
        TextView t = new TextView(activity);
        t.setText(text);
        t.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
        t.setPadding(0, dp(4), 0, dp(8));
        return t;
    }

    private TextView header(String text) {
        TextView t = new TextView(activity);
        t.setText(text);
        t.setTypeface(Typeface.DEFAULT_BOLD);
        t.setPadding(0, dp(14), 0, dp(4));
        return t;
    }

    private Button button(String text, View.OnClickListener l) {
        Button b = new Button(activity);
        b.setAllCaps(false);
        b.setText(text);
        b.setOnClickListener(l);
        return b;
    }

    private interface Saver {
        void save(String value);
    }

    private void ask(String title, String message, String current, boolean secure, Saver saver) {
        EditText input = new EditText(activity);
        input.setSingleLine(true);
        input.setText(current == null ? "" : current);
        input.setInputType(secure ? InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD : InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI);
        new AlertDialog.Builder(activity)
                .setTitle(title)
                .setMessage(message)
                .setView(input)
                .setPositiveButton("保存", (d, w) -> saver.save(input.getText().toString()))
                .setNegativeButton("取消", null)
                .show();
    }

    /** 翻译设置（浏览器设置里的「翻译设置…」、翻译菜单） */
    public void showSettings() {
        ScrollView scroll = new ScrollView(activity);
        LinearLayout box = new LinearLayout(activity);
        box.setOrientation(LinearLayout.VERTICAL);
        box.setPadding(dp(20), dp(8), dp(20), dp(8));
        scroll.addView(box);
        final AlertDialog[] holder = new AlertDialog[1];
        final Runnable refresh = () -> {
            reinstallScript();
            if (holder[0] != null) holder[0].dismiss();
            showSettings();
        };

        box.addView(header("网页翻译"));
        box.addView(button("翻译成：" + TranslateCore.languageName(TranslatePrefs.target(activity)), v -> pickLanguage(refresh)));
        final boolean only = "translation".equals(TranslatePrefs.display(activity));
        box.addView(button("显示方式：" + (only ? "仅译文" : "双语对照"), v -> {
            TranslatePrefs.setDisplay(activity, only ? "bilingual" : "translation");
            refresh.run();
        }));
        Switch sel = new Switch(activity);
        sel.setText("划词翻译（选中文字后点「译」）");
        sel.setChecked(TranslatePrefs.selection(activity));
        sel.setOnCheckedChangeListener((b, on) -> {
            TranslatePrefs.setSelection(activity, on);
            reinstallScript();
        });
        box.addView(sel);
        Switch yt = new Switch(activity);
        yt.setText("YouTube 双语字幕");
        yt.setChecked(TranslatePrefs.youtube(activity));
        yt.setOnCheckedChangeListener((b, on) -> {
            TranslatePrefs.setYoutube(activity, on);
            reinstallScript();
        });
        box.addView(yt);
        box.addView(note("工具栏「译」按钮切换双语对照 / 仅译文 / 原文。代码、输入框和已经是目标语言的段落不翻译；只翻译看得到的部分，动态加载的内容增量翻译。"));

        box.addView(header("自动翻译的网站"));
        final List<String> sites = TranslatePrefs.autoSites(activity);
        box.addView(button("管理（" + sites.size() + "）…", v -> {
            final String[] items = sites.toArray(new String[0]);
            final boolean[] checked = new boolean[items.length];
            new AlertDialog.Builder(activity)
                    .setTitle(items.length == 0 ? "没有自动翻译的网站" : "勾选要移除的网站")
                    .setMultiChoiceItems(items, checked, (d, which, isChecked) -> checked[which] = isChecked)
                    .setPositiveButton("移除所选", (d, w) -> {
                        List<String> keep = new ArrayList<>();
                        for (int i = 0; i < items.length; i++) if (!checked[i]) keep.add(items[i]);
                        TranslatePrefs.setAutoSites(activity, keep);
                        refresh.run();
                    })
                    .setNeutralButton("添加…", (d, w) -> {
                        String h = TranslateCore.normalizeHost(hostOf(webView.getUrl()));
                        ask("自动翻译网站（含子域名）", "例如 example.com", h, false, t -> {
                            if (TranslateCore.normalizeHost(t) == null) {
                                Toast.makeText(activity, "无效的域名", Toast.LENGTH_SHORT).show();
                                return;
                            }
                            TranslatePrefs.setAuto(activity, t, true);
                            refresh.run();
                        });
                    })
                    .setNegativeButton("关闭", null)
                    .show();
        }));

        box.addView(header("翻译引擎"));
        final String engine = TranslatePrefs.engine(activity);
        box.addView(button("引擎：" + TranslateCore.engineName(engine), v -> {
            String[] names = new String[TranslateCore.ENGINES.length];
            int idx = 0;
            for (int i = 0; i < names.length; i++) {
                names[i] = TranslateCore.ENGINES[i][1];
                if (TranslateCore.ENGINES[i][0].equals(engine)) idx = i;
            }
            new AlertDialog.Builder(activity).setTitle("翻译引擎").setSingleChoiceItems(names, idx, (d, which) -> {
                d.dismiss();
                TranslatePrefs.setEngine(activity, TranslateCore.ENGINES[which][0]);
                refresh.run();
            }).setNegativeButton("取消", null).show();
        }));
        if ("openai".equals(engine)) {
            final String base = TranslatePrefs.openaiBase(activity);
            box.addView(button("API 地址：" + (base.isEmpty() ? "未设置" : base), v -> ask("API 地址", "OpenAI 兼容接口，例如 https://api.openai.com/v1", base, false, t -> {
                if (!t.trim().isEmpty() && TranslateCore.normalizeBase(t).isEmpty()) {
                    Toast.makeText(activity, "地址无效（需要 http:// 或 https://）", Toast.LENGTH_SHORT).show();
                    return;
                }
                TranslatePrefs.setOpenaiBase(activity, t);
                refresh.run();
            })));
            final String model = TranslatePrefs.openaiModel(activity);
            box.addView(button("模型：" + (model.isEmpty() ? "未设置" : model), v -> ask("模型", "例如 gpt-4o-mini", model, false, t -> {
                TranslatePrefs.setOpenaiModel(activity, t);
                refresh.run();
            })));
            box.addView(button("API Key：" + (TranslatePrefs.hasKey(activity) ? "已保存（Keystore 加密）" : "未设置"), v -> ask("API Key", "留空保存 = 删除", "", true, t -> {
                if (!TranslatePrefs.setKey(activity, t)) Toast.makeText(activity, "保存失败（Keystore 不可用）", Toast.LENGTH_LONG).show();
                refresh.run();
            })));
            final String prompt = TranslatePrefs.openaiPrompt(activity);
            box.addView(button("附加提示：" + (prompt.isEmpty() ? "无" : prompt), v -> ask("附加提示（可选）", "例如：使用口语化表达；专有名词保留英文", prompt, false, t -> {
                TranslatePrefs.setOpenaiPrompt(activity, t);
                refresh.run();
            })));
            box.addView(button("测试连接", v -> testOpenAI()));
        }
        box.addView(note("免费引擎使用微软（Bing 网页翻译）和谷歌的公开网页接口，可能限流或变动；所选引擎失败或超时时自动改用免费引擎（微软 → 谷歌）。要翻译的文字会发送给所选引擎。"));

        box.addView(header("缓存"));
        box.addView(button("清除翻译缓存", v -> {
            clearCache();
            Toast.makeText(activity, "已清除", Toast.LENGTH_SHORT).show();
        }));

        holder[0] = new AlertDialog.Builder(activity)
                .setTitle("翻译")
                .setView(scroll)
                .setPositiveButton("完成", null)
                .create();
        holder[0].show();
    }

    private void testOpenAI() {
        final String endpoint = TranslateCore.openaiEndpoint(TranslatePrefs.openaiBase(activity));
        final String model = TranslatePrefs.openaiModel(activity);
        if (endpoint.isEmpty() || model.isEmpty()) {
            Toast.makeText(activity, "请先填写 API 地址和模型", Toast.LENGTH_SHORT).show();
            return;
        }
        Toast.makeText(activity, "测试中…", Toast.LENGTH_SHORT).show();
        net.execute(() -> {
            String msg;
            try {
                JSONObject body = new JSONObject();
                body.put("model", model);
                body.put("temperature", 0);
                JSONArray msgs = new JSONArray();
                msgs.put(new JSONObject().put("role", "user").put("content", "Translate to Simplified Chinese, reply with the translation only: Good morning"));
                body.put("messages", msgs);
                JSONObject req = new JSONObject();
                req.put("url", endpoint).put("method", "POST").put("auth", "openai").put("timeoutMs", 30000)
                        .put("headers", new JSONObject().put("Content-Type", "application/json")).put("body", body.toString());
                long t0 = System.currentTimeMillis();
                JSONObject r = fetch(req);
                if (r.has("error")) {
                    msg = "⚠️ " + r.optString("error");
                } else {
                    String text = "";
                    try {
                        JSONObject j = new JSONObject(r.optString("body"));
                        JSONArray ch = j.optJSONArray("choices");
                        if (ch != null) text = ch.getJSONObject(0).getJSONObject("message").optString("content");
                        else if (j.optJSONObject("error") != null) text = j.getJSONObject("error").optString("message");
                    } catch (Exception ignored) {}
                    int status = r.optInt("status");
                    msg = (status == 200 ? "✅ " : "⚠️ ") + "HTTP " + status + " · " + (System.currentTimeMillis() - t0) + " ms · " + (text.length() > 80 ? text.substring(0, 80) : text);
                }
            } catch (Exception e) {
                msg = "⚠️ " + e.getMessage();
            }
            final String m = msg;
            main.post(() -> new AlertDialog.Builder(activity).setTitle("测试结果").setMessage(m).setPositiveButton("好", null).show());
        });
    }
}
