package xyz.mio.app.browser;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Context;
import android.content.pm.ApplicationInfo;
import android.graphics.Typeface;
import android.net.Uri;
import android.util.Log;
import android.webkit.WebView;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.Switch;
import android.widget.TextView;

import androidx.webkit.ScriptHandler;
import androidx.webkit.WebViewCompat;
import androidx.webkit.WebViewFeature;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.HashSet;
import java.util.Locale;
import java.util.Set;

/**
 * 内置浏览器：YouTube 防沉迷（与 iOS / Mac / Windows 同一份脚本 shared/scripts/youtube-focus.js，APK 里是 assets/scripts/youtube-focus.js）。
 * 优先 WebViewCompat.addDocumentStartJavaScript（只对 https://youtube.com、https://*.youtube.com 主框架，document-start，不经 eval）；
 * 系统 WebView 不支持 DOCUMENT_START_SCRIPT 时在 onPageStarted / onPageCommitVisible / onPageFinished 里 evaluateJavascript 兜底
 * （脚本自己有 window.__mioYTFocus 防重复、只在 *.youtube.com 顶层生效）。
 */
final class YouTubeFocus {
    static final String TAG = "MioYTFocus";
    static final String ASSET = "scripts/youtube-focus.js";
    static final int DEFAULT_INTERVAL = 60;
    static final int[] INTERVAL_CHOICES = {30, 60, 120, 300, 600};

    private static String template;

    private final Activity activity;
    private final WebView webView;
    private final boolean docStart;
    private ScriptHandler handler;

    YouTubeFocus(Activity activity, WebView webView) {
        this.activity = activity;
        this.webView = webView;
        this.docStart = WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT);
    }

    // ------------------------------------------------------------ settings（BrowserPrefs 同一个文件，独立的键）

    static boolean enabled(Context c) { return BrowserPrefs.getBoolean(c, "youtubeFocus", true); }
    static boolean hidePlayables(Context c) { return BrowserPrefs.getBoolean(c, "youtubeFocusPlayables", true); }
    static int interval(Context c) {
        int v = BrowserPrefs.getInt(c, "youtubeFocusInterval", DEFAULT_INTERVAL);
        return v >= 5 ? v : DEFAULT_INTERVAL;
    }

    // ------------------------------------------------------------ script

    static boolean isYouTubeHost(String host) {
        if (host == null || host.isEmpty()) return false;
        String h = host.toLowerCase(Locale.ROOT);
        return h.equals("youtube.com") || h.endsWith(".youtube.com");
    }

    static boolean isYouTubeUrl(String url) {
        if (url == null) return false;
        try {
            Uri u = Uri.parse(url);
            String s = u.getScheme();
            return ("https".equalsIgnoreCase(s) || "http".equalsIgnoreCase(s)) && isYouTubeHost(u.getHost());
        } catch (Exception e) {
            return false;
        }
    }

    /** 与 MioWebCompat.youtubeFocusScript 相同：间隔夹在 5…3600 秒 */
    static String render(String tpl, int intervalSeconds, boolean hidePlayables) {
        int s = Math.max(5, Math.min(3600, intervalSeconds));
        return tpl.replace("__MIO_YT_INTERVAL_MS__", String.valueOf(s * 1000))
                .replace("__MIO_YT_PLAYABLES__", hidePlayables ? "1" : "0");
    }

    private static synchronized String template(Context c) {
        if (template != null) return template;
        try (InputStream in = c.getAssets().open(ASSET)) {
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
            template = new String(out.toByteArray(), StandardCharsets.UTF_8);
        } catch (Exception e) {
            Log.e(TAG, "missing asset " + ASSET, e);
            template = "";
        }
        return template;
    }

    private String script() {
        String tpl = template(activity);
        if (tpl.isEmpty()) return null;
        return render(tpl, interval(activity), hidePlayables(activity));
    }

    // ------------------------------------------------------------ injection

    /** 按当前设置（重新）注册 document-start 脚本。设置改变后调用 */
    void install() {
        if (handler != null) {
            try { handler.remove(); } catch (Exception ignored) {}
            handler = null;
        }
        if (!docStart || !enabled(activity)) return;
        String js = script();
        if (js == null) return;
        Set<String> rules = new HashSet<>();
        rules.add("https://youtube.com");
        rules.add("https://*.youtube.com");
        try {
            handler = WebViewCompat.addDocumentStartJavaScript(webView, js, rules);
            Log.i(TAG, "installed document-start script");
        } catch (Exception e) {
            Log.w(TAG, "addDocumentStartJavaScript failed, falling back to evaluateJavascript", e);
        }
    }

    boolean usesDocumentStart() { return handler != null; }

    /** 兜底：不支持 document-start 时（或注册失败）在页面开始 / 首帧 / 加载完成时注入 */
    void onPage(String url) {
        if (handler != null || !enabled(activity) || !isYouTubeUrl(url)) return;
        String js = script();
        if (js != null) webView.evaluateJavascript(js, null);
    }

    /** debug 包：YouTube 页面加载完成后把注入状态写进 logcat，给模拟器冒烟用（MioYTFocus state {...}） */
    void reportState(String url) {
        if ((activity.getApplicationInfo().flags & ApplicationInfo.FLAG_DEBUGGABLE) == 0) return;
        if (!isYouTubeUrl(url)) return;
        webView.evaluateJavascript("(function(){var s=document.getElementById('mio-yt-focus-style');return JSON.stringify({"
                + "host:location.hostname,installed:!!window.__mioYTFocus,style:!!s,rules:s&&s.sheet?s.sheet.cssRules.length:0,"
                + "playables:document.documentElement.classList.contains('mio-hide-playables'),"
                + "pivot:document.querySelectorAll('ytm-pivot-bar-item-renderer').length,"
                + "pivotHidden:document.querySelectorAll('ytm-pivot-bar-item-renderer[data-mio-shorts-nav]').length})})()",
                v -> Log.i(TAG, "state " + (docStart ? "docStart " : "fallback ") + v + " url=" + url));
    }

    // ------------------------------------------------------------ settings UI（浏览器设置对话框里的独立一节）

    static String intervalText(int sec) {
        return sec % 60 == 0 ? (sec / 60) + " 分钟" : sec + " 秒";
    }

    /** 往设置对话框里加「YouTube 防沉迷」一节；onChange 在设置改变后调用（重新注册脚本 + YouTube 页面刷新） */
    static void addSettings(Activity a, LinearLayout box, Runnable onChange) {
        TextView title = new TextView(a);
        title.setText("\nYouTube 防沉迷");
        title.setTypeface(Typeface.DEFAULT_BOLD);
        box.addView(title);

        Switch focus = new Switch(a);
        focus.setText("YouTube 防沉迷（隐藏 Shorts 推荐和入口，看 Shorts 时定时提醒）");
        focus.setChecked(enabled(a));
        box.addView(focus);

        Button interval = new Button(a);
        interval.setAllCaps(false);
        interval.setText("Shorts 提醒间隔：" + intervalText(interval(a)));
        box.addView(interval);

        Switch playables = new Switch(a);
        playables.setText("屏蔽游戏大本营（Playables）");
        playables.setChecked(hidePlayables(a));
        box.addView(playables);

        TextView note = new TextView(a);
        note.setText("隐藏首页 / 推荐 / 搜索里的 Shorts 和底部栏的 Shorts 入口、「打开 App」推广（频道页的 Shorts 保留）；进入 Shorts 立即提醒一次，之后按间隔提醒（只计前台时间）。游戏大本营：隐藏首页的小游戏区块和导航入口，直接打开 /playables 不受影响。");
        note.setTextSize(android.util.TypedValue.COMPLEX_UNIT_SP, 12);
        box.addView(note);

        Runnable sync = () -> {
            boolean on = enabled(a);
            interval.setEnabled(on);
            playables.setEnabled(on);
            interval.setAlpha(on ? 1f : 0.4f);
            playables.setAlpha(on ? 1f : 0.4f);
        };
        sync.run();
        focus.setOnCheckedChangeListener((b, on) -> {
            BrowserPrefs.putBoolean(a, "youtubeFocus", on);
            sync.run();
            onChange.run();
        });
        playables.setOnCheckedChangeListener((b, on) -> {
            BrowserPrefs.putBoolean(a, "youtubeFocusPlayables", on);
            onChange.run();
        });
        interval.setOnClickListener(v -> {
            int current = interval(a);
            String[] labels = new String[INTERVAL_CHOICES.length];
            int checked = -1;
            for (int i = 0; i < INTERVAL_CHOICES.length; i++) {
                labels[i] = intervalText(INTERVAL_CHOICES[i]);
                if (INTERVAL_CHOICES[i] == current) checked = i;
            }
            new AlertDialog.Builder(a)
                    .setTitle("Shorts 提醒间隔")
                    .setSingleChoiceItems(labels, checked, (d, which) -> {
                        BrowserPrefs.putInt(a, "youtubeFocusInterval", INTERVAL_CHOICES[which]);
                        interval.setText("Shorts 提醒间隔：" + intervalText(INTERVAL_CHOICES[which]));
                        d.dismiss();
                        onChange.run();
                    })
                    .setNegativeButton("取消", null)
                    .show();
        });
    }
}
