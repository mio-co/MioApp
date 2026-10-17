package xyz.mio.app.browser;

import android.Manifest;
import android.app.Activity;
import android.app.AlertDialog;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.webkit.JavascriptInterface;
import android.webkit.PermissionRequest;
import android.webkit.WebView;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.Switch;
import android.widget.TextView;
import android.util.TypedValue;

import androidx.webkit.ScriptHandler;
import androidx.webkit.WebViewCompat;
import androidx.webkit.WebViewFeature;

import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.lang.ref.WeakReference;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/**
 * 内置浏览器的媒体功能（v0.3.3，Android）：
 * - Spotify / DRM：onPermissionRequest 只放行 RESOURCE_PROTECTED_MEDIA_ID（Widevine），其它资源和以前一样拒绝。不改 UA。
 * - YouTube 媒体脚本（与 iOS 同一份 JS：assets/mio/youtube-media.js，由 scripts/sync-media-js.mjs 从 MioMediaScripts.swift 生成）：
 *   SponsorBlock 自动跳过 + 撤销 + 进度条标记、页面 MediaSession 元数据。document-start 注入 *.youtube.com。
 * - 后台播放：页面可见性伪造在 BrowserActivity.GENERIC_JS（v0.3.0 起）；Activity 切后台时不暂停 WebView（从不调用 webView.onPause）。
 *   播放中启动前台服务 {@link MioMediaService}（媒体通知 + MediaSession：播放 / 暂停 / 下一个），避免 :browser 进程在后台被回收。
 */
public final class MioMedia {
    static final String TAG = "MioMedia";
    static final String[] CATEGORIES = {"sponsor", "selfpromo", "interaction", "intro", "outro"};
    static final String[] CATEGORY_TITLES = {"赞助广告", "自我推广 / 无偿推广", "互动提醒（求订阅 / 点赞）", "片头 / 开场动画", "片尾 / 结束画面"};
    static final boolean[] CATEGORY_DEFAULTS = {true, true, true, false, false};
    static final String ATTRIBUTION = "片段数据来自 SponsorBlock（sponsor.ajay.app），按 CC BY-NC-SA 4.0 授权使用。隐私：只发送视频 ID 的 SHA-256 前 4 位。";

    private static WeakReference<MioMedia> current = new WeakReference<>(null);

    private final Activity activity;
    private final WebView webView;
    private final Handler main = new Handler(Looper.getMainLooper());
    private ScriptHandler script;
    private String template;
    private volatile boolean playing;
    private volatile String title = "", artist = "";
    private boolean askedNotifications;

    MioMedia(Activity activity, WebView webView) {
        this.activity = activity;
        this.webView = webView;
        current = new WeakReference<>(this);
        webView.addJavascriptInterface(new Bridge(), "MioMediaBridge");
    }

    static MioMedia current() { return current.get(); }

    // ---------------------------------------------------------------- DRM

    /** onPermissionRequest：只放行受保护媒体 ID（Widevine），其余拒绝（与之前默认的 deny 一致） */
    static String[] grantable(String[] requested) {
        if (requested == null) return new String[0];
        List<String> out = new ArrayList<>();
        for (String r : requested) if (PermissionRequest.RESOURCE_PROTECTED_MEDIA_ID.equals(r)) out.add(r);
        return out.toArray(new String[0]);
    }

    static void onPermissionRequest(PermissionRequest request) {
        String[] grant = grantable(request.getResources());
        Log.i(TAG, "permission request " + Arrays.toString(request.getResources()) + " from " + request.getOrigin() + " → grant " + Arrays.toString(grant));
        if (grant.length > 0) request.grant(grant); else request.deny();
    }

    // ---------------------------------------------------------------- 脚本

    /** 与 MioMediaScripts.Config.json 相同的键和顺序（纯 Java，单测可跑） */
    static String configJson(boolean sponsorBlock, List<String> categories) {
        StringBuilder sb = new StringBuilder();
        sb.append("{\"platform\":\"android\",\"background\":true,\"nowPlaying\":true,\"pip\":false,\"sponsorBlock\":").append(sponsorBlock).append(",\"categories\":[");
        boolean first = true;
        for (String c : CATEGORIES) {
            if (!categories.contains(c)) continue;
            if (!first) sb.append(',');
            sb.append('"').append(c).append('"');
            first = false;
        }
        return sb.append("]}").toString();
    }

    static String buildScript(String template, String configJson) {
        int i = template.indexOf("__MIO_MEDIA_CONFIG__");
        if (i < 0) return template;
        return template.substring(0, i) + configJson + template.substring(i + "__MIO_MEDIA_CONFIG__".length());
    }

    static List<String> enabledCategories(Context c) {
        List<String> out = new ArrayList<>();
        for (int i = 0; i < CATEGORIES.length; i++) if (BrowserPrefs.sponsorBlockCategory(c, CATEGORIES[i], CATEGORY_DEFAULTS[i])) out.add(CATEGORIES[i]);
        return out;
    }

    private String template() {
        if (template != null) return template;
        try (InputStream in = activity.getAssets().open("mio/youtube-media.js")) {
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            byte[] buf = new byte[16384];
            int n;
            while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
            template = new String(out.toByteArray(), StandardCharsets.UTF_8);
        } catch (Exception e) {
            Log.w(TAG, "youtube-media.js missing", e);
            template = "";
        }
        return template;
    }

    /** 注册 / 重新注册 YouTube 文档开始脚本（设置改了之后调用，对之后加载的页面生效） */
    void install() {
        if (!WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) return;
        String t = template();
        if (t.isEmpty()) return;
        if (script != null) { script.remove(); script = null; }
        String js = buildScript(t, configJson(BrowserPrefs.sponsorBlock(activity), enabledCategories(activity)));
        Set<String> rules = new HashSet<>();
        rules.add("https://youtube.com");
        rules.add("https://*.youtube.com");
        try {
            script = WebViewCompat.addDocumentStartJavaScript(webView, js, rules);
        } catch (Exception e) {
            Log.w(TAG, "addDocumentStartJavaScript", e);
        }
    }

    // ---------------------------------------------------------------- 播放状态 / 前台服务

    private class Bridge {
        @JavascriptInterface
        public void post(String json) {
            try {
                JSONObject o = new JSONObject(json);
                if (!"state".equals(o.optString("type"))) return;
                boolean p = o.optBoolean("playing");
                title = o.optString("title", "");
                artist = o.optString("artist", "");
                main.post(() -> onState(p));
            } catch (Exception ignored) {}
        }
    }

    private void onState(boolean p) {
        boolean was = playing;
        playing = p;
        if (p) {
            maybeAskNotifications();
            MioMediaService.update(activity, true, title, artist);
        } else if (was) {
            MioMediaService.update(activity, false, title, artist);
        }
    }

    boolean isPlaying() { return playing; }

    /** 通知栏 / 耳机按钮 → 页面（与 iOS 相同的 __mioMedia.command） */
    void command(String name) {
        main.post(() -> webView.evaluateJavascript("window.__mioMedia&&window.__mioMedia.command('" + name + "')", null));
    }

    void destroy() {
        MioMediaService.stop(activity);
        if (current.get() == this) current = new WeakReference<>(null);
    }

    /** Android 13+：媒体通知需要通知权限（不给也照常后台播放，只是看不到通知） */
    private void maybeAskNotifications() {
        if (askedNotifications || Build.VERSION.SDK_INT < 33) return;
        askedNotifications = true;
        if (activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) return;
        if (BrowserPrefs.askedNotifications(activity)) return;
        BrowserPrefs.setAskedNotifications(activity, true);
        try { activity.requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, 0x4D10); } catch (Exception ignored) {}
    }

    // ---------------------------------------------------------------- 设置

    /** 浏览器设置对话框里的 SponsorBlock 区块 */
    void addSettings(LinearLayout box) {
        Context c = activity;
        TextView title = new TextView(c);
        title.setText("\nYouTube（SponsorBlock 跳过赞助片段、后台播放）");
        title.setTypeface(android.graphics.Typeface.DEFAULT_BOLD);
        box.addView(title);

        Switch sb = new Switch(c);
        sb.setText("自动跳过赞助等片段（SponsorBlock）");
        sb.setChecked(BrowserPrefs.sponsorBlock(c));
        sb.setOnCheckedChangeListener((b, on) -> { BrowserPrefs.setSponsorBlock(c, on); install(); });
        box.addView(sb);

        Button cats = new Button(c);
        cats.setText("SponsorBlock 分类…");
        cats.setOnClickListener(v -> {
            boolean[] checked = new boolean[CATEGORIES.length];
            for (int i = 0; i < CATEGORIES.length; i++) checked[i] = BrowserPrefs.sponsorBlockCategory(c, CATEGORIES[i], CATEGORY_DEFAULTS[i]);
            new AlertDialog.Builder(c)
                    .setTitle("自动跳过的片段")
                    .setMultiChoiceItems(CATEGORY_TITLES, checked, (d, which, on) -> checked[which] = on)
                    .setPositiveButton("好", (d, w) -> {
                        for (int i = 0; i < CATEGORIES.length; i++) BrowserPrefs.setSponsorBlockCategory(c, CATEGORIES[i], checked[i]);
                        install();
                    })
                    .setNegativeButton("取消", null)
                    .show();
        });
        box.addView(cats);

        TextView note = new TextView(c);
        note.setText("跳过时底部提示，可点「撤销」回看；手动拖回片段里不会再跳。对之后打开的视频页生效。后台播放：切到后台继续播放，播放时通知栏有播放控制。Spotify 等 DRM 内容使用系统 WebView 的 Widevine。\n" + ATTRIBUTION);
        note.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
        box.addView(note);
    }
}
