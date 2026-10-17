package xyz.mio.app.browser;

import android.annotation.SuppressLint;
import android.app.Activity;
import android.app.AlertDialog;
import android.content.ActivityNotFoundException;
import android.content.Context;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.Color;
import android.graphics.Typeface;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.text.InputType;
import android.text.TextUtils;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputMethodManager;
import android.webkit.CookieManager;
import android.webkit.JavascriptInterface;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Button;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.ScrollView;
import android.widget.Switch;
import android.widget.TextView;
import android.widget.Toast;

import androidx.core.graphics.Insets;
import androidx.core.view.ViewCompat;
import androidx.core.view.WindowInsetsCompat;
import androidx.webkit.ScriptHandler;
import androidx.webkit.WebViewCompat;
import androidx.webkit.WebViewFeature;

import org.json.JSONObject;

import java.io.ByteArrayInputStream;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Date;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

import xyz.mio.app.adblock.AdblockNative;
import xyz.mio.app.adblock.AdblockStore;

/**
 * App 内置浏览器（独立进程 :browser → 独立的 WebView 数据目录，与 MioCore 主界面的会话互不影响）。
 * 拦截：shouldInterceptRequest → adblock-rust；页面脚本（AdGuard Scriptlets / CSS / ExtendedCss）：
 * 主框架按主机名预先注册 document-start 脚本（WebViewCompat.addDocumentStartJavaScript，不经 eval，绕开 Trusted Types / CSP），
 * iframe 和未预注册的页面由通用 document-start 脚本经 JavascriptInterface 同步取代码执行。
 */
public class BrowserActivity extends Activity {
    private static final String EXTRA_URL = "url";
    private static final String EXTRA_SETTINGS = "settings";
    private static boolean dataSuffixSet;

    public static Intent intent(Context c, String url, boolean settings) {
        Intent i = new Intent(c, BrowserActivity.class);
        if (url != null) i.putExtra(EXTRA_URL, url);
        i.putExtra(EXTRA_SETTINGS, settings);
        if (!(c instanceof Activity)) i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        return i;
    }

    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private AdblockStore store;
    private WebView webView;
    private EditText address;
    private TextView shield;
    private ProgressBar progress;
    private Button backBtn, fwdBtn, reloadBtn;
    private FrameLayout fullscreen;
    private View customView;
    private WebChromeClient.CustomViewCallback customCallback;
    private volatile String topUrl = "";
    private volatile boolean engineReady;
    private boolean docStartSupported;
    private ScriptHandler genericHandler;
    private final LinkedHashMap<String, ScriptHandler> hostScripts = new LinkedHashMap<>();
    private long hostScriptsBuiltAt;
    private YouTubeFocus ytFocus;
    private MioMedia media;
    /** 阅读模式 / 强制深色 / 存到 Mio（PageTools.java） */
    private PageTools pageTools;
    private Button readerBtn;

    // ---------------------------------------------------------------- lifecycle

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        if (!dataSuffixSet) {
            dataSuffixSet = true;
            try {
                WebView.setDataDirectorySuffix("browser");
            } catch (Throwable ignored) {
                // 本进程已经创建过 WebView
            }
        }
        store = AdblockStore.get(this);
        buildUi();
        setupWebView();

        String url = getIntent().getStringExtra(EXTRA_URL);
        boolean settings = getIntent().getBooleanExtra(EXTRA_SETTINGS, false);
        worker.execute(() -> {
            store.ensureEngine();
            engineReady = store.isReady();
            main.post(() -> {
                installGenericScript();
                if (url != null) load(url);
                if (settings) showSettings(url == null);
            });
        });
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        String url = intent.getStringExtra(EXTRA_URL);
        if (url != null) load(url);
        if (intent.getBooleanExtra(EXTRA_SETTINGS, false)) showSettings(false);
    }

    @Override
    protected void onResume() {
        super.onResume();
        // 主进程（WorkManager）可能更新了规则
        worker.execute(() -> {
            long before = store.builtAt();
            store.ensureEngine();
            if (store.builtAt() != before) main.post(this::invalidateHostScripts);
        });
    }

    @Override
    protected void onDestroy() {
        worker.shutdownNow();
        if (media != null) media.destroy();
        if (webView != null) {
            webView.stopLoading();
            webView.destroy();
        }
        super.onDestroy();
    }

    @Override
    public void onBackPressed() {
        if (customView != null) {
            hideCustomView();
        } else if (webView != null && webView.canGoBack()) {
            webView.goBack();
        } else {
            super.onBackPressed();
        }
    }

    // ---------------------------------------------------------------- UI

    private int dp(float v) {
        return (int) TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, getResources().getDisplayMetrics());
    }

    private Button glyph(String text, String description, View.OnClickListener l) {
        Button b = new Button(this, null, android.R.attr.borderlessButtonStyle);
        b.setText(text);
        b.setTextSize(TypedValue.COMPLEX_UNIT_SP, 20);
        b.setAllCaps(false);
        b.setContentDescription(description);
        b.setMinWidth(0);
        b.setMinimumWidth(0);
        b.setPadding(dp(8), 0, dp(8), 0);
        b.setOnClickListener(l);
        return b;
    }

    private void buildUi() {
        FrameLayout root = new FrameLayout(this);
        LinearLayout col = new LinearLayout(this);
        col.setOrientation(LinearLayout.VERTICAL);
        root.addView(col, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));

        LinearLayout top = new LinearLayout(this);
        top.setOrientation(LinearLayout.HORIZONTAL);
        top.setGravity(Gravity.CENTER_VERTICAL);
        top.setPadding(dp(4), dp(4), dp(4), dp(4));
        top.addView(glyph("✕", "关闭", v -> finish()), new LinearLayout.LayoutParams(dp(44), dp(44)));
        address = new EditText(this);
        address.setSingleLine(true);
        address.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15);
        address.setInputType(InputType.TYPE_TEXT_VARIATION_URI);
        address.setImeOptions(EditorInfo.IME_ACTION_GO);
        address.setSelectAllOnFocus(true);
        address.setOnEditorActionListener((v, actionId, event) -> {
            if (actionId == EditorInfo.IME_ACTION_GO || (event != null && event.getKeyCode() == KeyEvent.KEYCODE_ENTER)) {
                String u = urlFromInput(address.getText().toString());
                hideKeyboard();
                address.clearFocus();
                if (u != null) load(u);
                return true;
            }
            return false;
        });
        address.setOnFocusChangeListener((v, has) -> {
            if (has) address.setText(webView.getUrl() != null ? webView.getUrl() : "");
            else updateAddress();
        });
        top.addView(address, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1));
        readerBtn = glyph("📖", "阅读模式", v -> { if (pageTools != null) pageTools.openReader(false); });
        top.addView(readerBtn, new LinearLayout.LayoutParams(dp(44), dp(44)));
        shield = glyph("🛡", "广告拦截", v -> showShieldMenu());
        top.addView(shield, new LinearLayout.LayoutParams(dp(44), dp(44)));
        col.addView(top, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        progress = new ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal);
        progress.setMax(100);
        col.addView(progress, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(3)));

        webView = new WebView(this);
        col.addView(webView, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1));

        LinearLayout bottom = new LinearLayout(this);
        bottom.setOrientation(LinearLayout.HORIZONTAL);
        bottom.setGravity(Gravity.CENTER);
        backBtn = glyph("‹", "后退", v -> { if (webView.canGoBack()) webView.goBack(); });
        fwdBtn = glyph("›", "前进", v -> { if (webView.canGoForward()) webView.goForward(); });
        reloadBtn = glyph("↻", "刷新", v -> {
            if (progress.getVisibility() == View.VISIBLE && progress.getProgress() < 100) webView.stopLoading();
            else webView.reload();
        });
        Button share = glyph("⇪", "分享", v -> share());
        Button external = glyph("↗", "用系统浏览器打开", v -> openExternal(webView.getUrl()));
        Button settings = glyph("⚙", "浏览器设置", v -> showSettings(false));
        Button mio = glyph("📥", "存到 Mio / 阅读模式 / 深色", v -> { if (pageTools != null) pageTools.showMenu(); });
        for (Button b : new Button[]{backBtn, fwdBtn, reloadBtn, share, external, mio, settings}) {
            bottom.addView(b, new LinearLayout.LayoutParams(0, dp(48), 1));
        }
        col.addView(bottom, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        fullscreen = new FrameLayout(this);
        fullscreen.setBackgroundColor(Color.BLACK);
        fullscreen.setVisibility(View.GONE);
        root.addView(fullscreen, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));

        // Android 15 起强制 edge-to-edge：内容避开状态栏 / 导航栏 / 键盘
        ViewCompat.setOnApplyWindowInsetsListener(col, (v, insets) -> {
            Insets bars = insets.getInsets(WindowInsetsCompat.Type.systemBars() | WindowInsetsCompat.Type.displayCutout() | WindowInsetsCompat.Type.ime());
            v.setPadding(bars.left, bars.top, bars.right, bars.bottom);
            return WindowInsetsCompat.CONSUMED;
        });
        setContentView(root);
        updateButtons();
    }

    private void hideKeyboard() {
        InputMethodManager imm = (InputMethodManager) getSystemService(INPUT_METHOD_SERVICE);
        if (imm != null) imm.hideSoftInputFromWindow(address.getWindowToken(), 0);
    }

    private void updateAddress() {
        if (address.hasFocus()) return;
        String u = webView.getUrl();
        String host = u != null ? Uri.parse(u).getHost() : null;
        String title = webView.getTitle();
        if (host == null) host = "";
        address.setText(title != null && !title.isEmpty() && !title.equals(u) ? title + " — " + host : host);
    }

    private void updateButtons() {
        if (webView == null) return;
        backBtn.setEnabled(webView.canGoBack());
        fwdBtn.setEnabled(webView.canGoForward());
        backBtn.setAlpha(webView.canGoBack() ? 1f : 0.35f);
        fwdBtn.setAlpha(webView.canGoForward() ? 1f : 0.35f);
    }

    private void updateShield() {
        boolean on = isActive(hostOf(topUrl));
        shield.setText(on ? "🛡" : "⛔");
        shield.setAlpha(on ? 1f : 0.6f);
    }

    static String urlFromInput(String text) {
        String t = text.trim();
        if (t.isEmpty()) return null;
        Uri u = Uri.parse(t);
        if (u.getScheme() != null && (u.getScheme().equals("http") || u.getScheme().equals("https")) && u.getHost() != null) return t;
        if (!t.contains(" ") && t.contains(".")) return "https://" + t;
        return "https://www.google.com/search?q=" + Uri.encode(t);
    }

    // ---------------------------------------------------------------- WebView

    @SuppressLint({"SetJavaScriptEnabled", "AddJavascriptInterface"})
    private void setupWebView() {
        WebSettings s = webView.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setDatabaseEnabled(true);
        s.setMediaPlaybackRequiresUserGesture(false);
        s.setSupportMultipleWindows(false);
        s.setJavaScriptCanOpenWindowsAutomatically(false);
        s.setLoadWithOverviewMode(true);
        s.setUseWideViewPort(true);
        s.setBuiltInZoomControls(true);
        s.setDisplayZoomControls(false);
        s.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);
        // 去掉 WebView 标识（"; wv"、"Version/4.0"）：否则 Google 登录拒绝（disallowed_useragent），YouTube 给降级页面
        String ua = s.getUserAgentString();
        if (ua != null) s.setUserAgentString(ua.replace("; wv)", ")").replace("Version/4.0 ", ""));
        CookieManager.getInstance().setAcceptCookie(true);
        CookieManager.getInstance().setAcceptThirdPartyCookies(webView, true);
        docStartSupported = WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT);
        webView.addJavascriptInterface(new Bridge(), "MioAdblockBridge");
        // YouTube 防沉迷：先于通用脚本注册（通用脚本之后每次都会重新注册到最后）
        ytFocus = new YouTubeFocus(this, webView);
        ytFocus.install();
        // 媒体：YouTube 脚本（SponsorBlock / MediaSession）、后台播放通知、Widevine 权限（MioMedia.java）
        media = new MioMedia(this, webView);
        media.install();
        pageTools = new PageTools(this, webView);
        pageTools.setReaderButton(readerBtn);

        webView.setWebViewClient(new WebViewClient() {
            @Override
            public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                Uri uri = request.getUrl();
                String scheme = uri.getScheme() == null ? "" : uri.getScheme().toLowerCase(Locale.ROOT);
                if (scheme.equals("http") || scheme.equals("https")) {
                    if (request.isForMainFrame()) prepare(uri.toString());
                    return false;
                }
                if (scheme.equals("about") || scheme.equals("data") || scheme.equals("blob") || scheme.equals("javascript")) return false;
                // intent:// tel: mailto: 以及各种 App 链接交给系统
                try {
                    Intent i = scheme.equals("intent") ? Intent.parseUri(uri.toString(), Intent.URI_INTENT_SCHEME) : new Intent(Intent.ACTION_VIEW, uri);
                    i.addCategory(Intent.CATEGORY_BROWSABLE);
                    i.setComponent(null);
                    i.setSelector(null);
                    startActivity(i);
                } catch (Exception e) {
                    if (scheme.equals("intent")) {
                        try {
                            String fallback = Intent.parseUri(uri.toString(), Intent.URI_INTENT_SCHEME).getStringExtra("browser_fallback_url");
                            if (fallback != null) view.loadUrl(fallback);
                        } catch (Exception ignored) {}
                    }
                }
                return true;
            }

            @Override
            public void onPageStarted(WebView view, String url, Bitmap favicon) {
                topUrl = url;
                pageTools.onPageStarted(url);
                prepare(url);
                ytFocus.onPage(url);
                updateAddress();
                updateShield();
                updateButtons();
            }

            @Override
            public void onPageCommitVisible(WebView view, String url) {
                ytFocus.onPage(url);
            }

            @Override
            public void onPageFinished(WebView view, String url) {
                ytFocus.onPage(url);
                ytFocus.reportState(url);
                pageTools.onPageFinished();
                updateAddress();
                updateButtons();
            }

            @Override
            public void doUpdateVisitedHistory(WebView view, String url, boolean isReload) {
                topUrl = url;
                pageTools.onUrlChanged();
                updateButtons();
                updateAddress();
            }

            @Override
            public WebResourceResponse shouldInterceptRequest(WebView view, WebResourceRequest request) {
                return intercept(request);
            }

            @Override
            public boolean onRenderProcessGone(WebView view, android.webkit.RenderProcessGoneDetail detail) {
                finish();
                return true;
            }
        });

        webView.setWebChromeClient(new WebChromeClient() {
            @Override
            public void onProgressChanged(WebView view, int p) {
                progress.setProgress(p);
                progress.setVisibility(p >= 100 ? View.INVISIBLE : View.VISIBLE);
                reloadBtn.setText(p >= 100 ? "↻" : "✕");
            }

            @Override
            public void onReceivedTitle(WebView view, String title) {
                updateAddress();
            }

            @Override
            public void onShowCustomView(View view, CustomViewCallback callback) {
                if (customView != null) { callback.onCustomViewHidden(); return; }
                customView = view;
                customCallback = callback;
                fullscreen.addView(view, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
                fullscreen.setVisibility(View.VISIBLE);
            }

            @Override
            public void onHideCustomView() {
                hideCustomView();
            }

            @Override
            public void onPermissionRequest(android.webkit.PermissionRequest request) {
                // 只放行 RESOURCE_PROTECTED_MEDIA_ID（Widevine，Spotify 等 DRM）；其它资源照旧拒绝
                MioMedia.onPermissionRequest(request);
            }
        });
    }

    private void hideCustomView() {
        if (customView == null) return;
        fullscreen.removeView(customView);
        fullscreen.setVisibility(View.GONE);
        customView = null;
        if (customCallback != null) customCallback.onCustomViewHidden();
        customCallback = null;
    }

    private void load(String url) {
        topUrl = url;
        prepare(url);
        webView.loadUrl(url);
    }

    // ---------------------------------------------------------------- blocking

    private static String hostOf(String url) {
        if (url == null) return null;
        try { return Uri.parse(url).getHost(); } catch (Exception e) { return null; }
    }

    private boolean isActive(String host) {
        return BrowserPrefs.adblockEnabled(this) && BrowserPrefs.allowlistEntry(this, host) == null;
    }

    private volatile boolean activeCache = true;
    private volatile String activeCacheHost = "";

    /** 网络线程里调用：缓存当前主机的开关状态，避免每个请求都读设置文件 */
    private boolean activeFor(String host) {
        String h = host == null ? "" : host;
        if (!h.equals(activeCacheHost)) {
            activeCache = isActive(h);
            activeCacheHost = h;
        }
        return activeCache;
    }

    private void invalidateActive() { activeCacheHost = "\u0000"; }

    private WebResourceResponse intercept(WebResourceRequest request) {
        if (!engineReady || request.isForMainFrame()) return null;
        String url = request.getUrl().toString();
        if (!url.startsWith("http")) return null;
        String top = topUrl;
        if (!activeFor(hostOf(top))) return null;
        long h = store.acquire();
        if (h == 0) return null;
        boolean block;
        try {
            block = AdblockNative.shouldBlock(h, url, top, requestType(request));
        } finally {
            store.release();
        }
        if (!block) return null;
        Map<String, String> headers = new HashMap<>();
        headers.put("Access-Control-Allow-Origin", "*");
        return new WebResourceResponse("text/plain", "utf-8", 403, "Blocked", headers, new ByteArrayInputStream(new byte[0]));
    }

    static String requestType(WebResourceRequest r) {
        Map<String, String> h = r.getRequestHeaders();
        String dest = null, accept = null;
        if (h != null) {
            for (Map.Entry<String, String> e : h.entrySet()) {
                if ("Sec-Fetch-Dest".equalsIgnoreCase(e.getKey())) dest = e.getValue();
                if ("Accept".equalsIgnoreCase(e.getKey())) accept = e.getValue();
            }
        }
        if (dest != null) {
            switch (dest) {
                case "script": case "worker": case "sharedworker": case "serviceworker": return "script";
                case "style": return "stylesheet";
                case "image": return "image";
                case "font": return "font";
                case "iframe": case "frame": return "subdocument";
                case "video": case "audio": case "track": return "media";
                case "object": case "embed": return "object";
                case "empty": return "xmlhttprequest";
                case "document": return "subdocument";
                default: break;
            }
        }
        String path = r.getUrl().getPath();
        path = path == null ? "" : path.toLowerCase(Locale.ROOT);
        if (path.endsWith(".js") || path.endsWith(".mjs")) return "script";
        if (path.endsWith(".css")) return "stylesheet";
        if (path.matches(".*\\.(png|jpe?g|gif|webp|svg|ico|avif|bmp)$")) return "image";
        if (path.matches(".*\\.(woff2?|ttf|otf|eot)$")) return "font";
        if (path.matches(".*\\.(mp4|webm|m3u8|mp3|m4a|aac|ogg|ts|mpd)$")) return "media";
        if (accept != null) {
            if (accept.contains("text/css")) return "stylesheet";
            if (accept.startsWith("image/")) return "image";
            if (accept.contains("text/html")) return "subdocument";
            if (accept.contains("json") || accept.equals("*/*")) return "xmlhttprequest";
        }
        return "other";
    }

    // ---------------------------------------------------------------- document-start scripts

    /** 后台播放 + iframe / 未预注册页面的拦截代码（经 JavascriptInterface 同步取）；每次注册主机脚本后重新注册，保证它在最后执行 */
    private static final String GENERIC_JS =
            "(function(){try{" +
            "Object.defineProperty(document,'hidden',{configurable:true,get:function(){return false;}});" +
            "Object.defineProperty(document,'visibilityState',{configurable:true,get:function(){return 'visible';}});" +
            "document.addEventListener('visibilitychange',function(e){e.stopImmediatePropagation();},true);" +
            "}catch(e){}" +
            "if(window.top===window&&window.__mioAB)return;" +
            "if(!/^https?:$/.test(location.protocol))return;" +
            "var B=window.MioAdblockBridge;if(!B||!B.script)return;" +
            "try{var c=B.script(location.href,window.top===window);if(c){window.__mioAB=1;(0,eval)(c);}}catch(e){}" +
            "})();";

    private void installGenericScript() {
        if (!docStartSupported) return;
        if (genericHandler != null) genericHandler.remove();
        genericHandler = WebViewCompat.addDocumentStartJavaScript(webView, GENERIC_JS, Collections.singleton("*"));
    }

    private void invalidateHostScripts() {
        for (ScriptHandler sh : hostScripts.values()) sh.remove();
        hostScripts.clear();
        invalidateActive();
        updateShield();
    }

    /** 主框架即将打开 url：为该主机注册 document-start 脚本（页面脚本之前执行，不经 eval） */
    private void prepare(String url) {
        if (!docStartSupported || !engineReady) return;
        String host = hostOf(url);
        if (host == null) return;
        host = host.toLowerCase(Locale.ROOT);
        if (store.builtAt() != hostScriptsBuiltAt) {
            invalidateHostScripts();
            hostScriptsBuiltAt = store.builtAt();
        }
        if (hostScripts.containsKey(host)) {
            ScriptHandler sh = hostScripts.remove(host);
            hostScripts.put(host, sh); // LRU
            return;
        }
        if (!isActive(host)) return;
        String code;
        long h = store.acquire();
        if (h == 0) return;
        try {
            code = AdblockNative.pageScript(h, url);
        } finally {
            store.release();
        }
        if (code == null) return;
        String wrapped = "(function(){if(window.top!==window||location.hostname.toLowerCase()!==" + JSONObject.quote(host)
                + "||window.__mioAB)return;window.__mioAB=1;\n" + code + "\n})();";
        java.util.Set<String> rules = new java.util.HashSet<>();
        rules.add("https://" + host);
        rules.add("http://" + host);
        try {
            ScriptHandler sh = WebViewCompat.addDocumentStartJavaScript(webView, wrapped, rules);
            hostScripts.put(host, sh);
        } catch (Exception e) {
            return;
        }
        while (hostScripts.size() > 8) {
            String oldest = hostScripts.keySet().iterator().next();
            ScriptHandler old = hostScripts.remove(oldest);
            if (old != null) old.remove();
        }
        installGenericScript();
    }

    private class Bridge {
        @JavascriptInterface
        public String script(String url, boolean top) {
            String host = hostOf(top ? url : topUrl);
            if (!engineReady || !activeFor(host)) return null;
            long h = store.acquire();
            if (h == 0) return null;
            try {
                return AdblockNative.pageScript(h, url);
            } finally {
                store.release();
            }
        }

        @JavascriptInterface
        public String generic(String url, String json) {
            if (!engineReady || !activeFor(hostOf(topUrl))) return null;
            long h = store.acquire();
            if (h == 0) return null;
            try {
                return AdblockNative.genericCss(h, url, json);
            } finally {
                store.release();
            }
        }
    }

    // ---------------------------------------------------------------- actions

    private void share() {
        String u = webView.getUrl();
        if (u == null) return;
        Intent i = new Intent(Intent.ACTION_SEND);
        i.setType("text/plain");
        i.putExtra(Intent.EXTRA_TEXT, u);
        startActivity(Intent.createChooser(i, "分享"));
    }

    private void openExternal(String url) {
        if (url == null) return;
        try {
            Intent i = new Intent(Intent.ACTION_VIEW, Uri.parse(url));
            startActivity(Intent.createChooser(i, "用浏览器打开"));
        } catch (ActivityNotFoundException ignored) {}
    }

    private void showShieldMenu() {
        String host = hostOf(webView.getUrl());
        List<String> items = new ArrayList<>();
        List<Runnable> actions = new ArrayList<>();
        if (!BrowserPrefs.adblockEnabled(this)) {
            items.add("开启广告拦截");
            actions.add(() -> { BrowserPrefs.setAdblockEnabled(this, true); afterSettingChange(true); });
        } else if (host != null) {
            if (BrowserPrefs.allowlistEntry(this, host) != null) {
                items.add("恢复拦截此站点");
                actions.add(() -> { BrowserPrefs.setAllowlisted(this, host, false); afterSettingChange(true); });
            } else {
                items.add("此站点不拦截（加入白名单）");
                actions.add(() -> { BrowserPrefs.setAllowlisted(this, host, true); afterSettingChange(true); });
            }
        }
        items.add("拦截设置…");
        actions.add(() -> showSettings(false));
        new AlertDialog.Builder(this)
                .setTitle(host != null ? host : "广告拦截")
                .setItems(items.toArray(new String[0]), (d, which) -> actions.get(which).run())
                .show();
    }

    private void afterSettingChange(boolean reload) {
        invalidateHostScripts();
        if (reload && webView.getUrl() != null) {
            prepare(webView.getUrl());
            webView.reload();
        }
    }

    private static String fmt(long t) {
        return t <= 0 ? "—" : new SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.ROOT).format(new Date(t));
    }

    private String statusText() {
        JSONObject s = store.state();
        StringBuilder sb = new StringBuilder();
        JSONObject lists = s.optJSONObject("lists");
        for (int id : AdblockStore.ALL_IDS) {
            JSONObject m = lists != null ? lists.optJSONObject(String.valueOf(id)) : null;
            sb.append("• ").append(AdblockStore.listName(id));
            if (m != null) {
                String v = m.optString("version", "");
                if (!v.isEmpty() && !"null".equals(v)) sb.append("  v").append(v);
                sb.append("  ").append(id == 0 ? "App 内置" : ("remote".equals(m.optString("source")) ? "下载于 " + fmt(m.optLong("fetchedAt")) : "App 内置版"));
                String err = m.optString("error", "");
                if (!err.isEmpty()) sb.append("  ⚠️ ").append(err);
            }
            sb.append('\n');
        }
        JSONObject sm = s.optJSONObject("scriptlets");
        sb.append("• AdGuard Scriptlets  v").append(store.scriptletsVersion() != null ? store.scriptletsVersion() : "?")
                .append(sm != null && "remote".equals(sm.optString("source")) ? "  远程更新于 " + fmt(sm.optLong("fetchedAt")) + "（SHA-256 已校验）" : "  App 内置版")
                .append('\n');
        sb.append("\n上次检查：").append(fmt(s.optLong("lastCheck")));
        String msg = s.optString("lastCheckMessage", "");
        if (!msg.isEmpty()) sb.append('\n').append(msg);
        sb.append("\n引擎构建于：").append(fmt(store.builtAt()));
        if (store.lastBuildError() != null) sb.append("\n⚠️ ").append(store.lastBuildError());
        if (!docStartSupported) sb.append("\n⚠️ 系统 WebView 版本过旧，不支持 document-start 脚本（只拦截网络请求）");
        return sb.toString();
    }

    private void showSettings(boolean finishOnClose) {
        String host = hostOf(webView.getUrl());
        ScrollView scroll = new ScrollView(this);
        LinearLayout box = new LinearLayout(this);
        box.setOrientation(LinearLayout.VERTICAL);
        box.setPadding(dp(20), dp(8), dp(20), dp(8));
        scroll.addView(box);

        Switch master = new Switch(this);
        master.setText("拦截广告和跟踪器");
        master.setChecked(BrowserPrefs.adblockEnabled(this));
        master.setOnCheckedChangeListener((b, on) -> { BrowserPrefs.setAdblockEnabled(this, on); afterSettingChange(false); });
        box.addView(master);

        if (host != null) {
            Switch site = new Switch(this);
            site.setText("在 " + host + " 上拦截");
            site.setChecked(BrowserPrefs.allowlistEntry(this, host) == null);
            site.setOnCheckedChangeListener((b, on) -> { BrowserPrefs.setAllowlisted(this, host, !on); afterSettingChange(false); });
            box.addView(site);
        }

        Switch system = new Switch(this);
        system.setText("外链默认用系统浏览器打开");
        system.setChecked(BrowserPrefs.preferSystemBrowser(this));
        system.setOnCheckedChangeListener((b, on) -> BrowserPrefs.setPreferSystemBrowser(this, on));
        box.addView(system);

        TextView title = new TextView(this);
        title.setText("\n过滤规则（AdGuard 官方源，超过 24 小时自动检查更新）");
        title.setTypeface(Typeface.DEFAULT_BOLD);
        box.addView(title);
        TextView status = new TextView(this);
        status.setText(statusText());
        status.setTextIsSelectable(true);
        box.addView(status);

        YouTubeFocus.addSettings(this, box, () -> {
            ytFocus.install();
            String u = webView.getUrl();
            if (YouTubeFocus.isYouTubeUrl(u)) webView.reload();
        });

        Button update = new Button(this);
        update.setText("立即更新规则");
        update.setOnClickListener(v -> {
            update.setEnabled(false);
            update.setText("更新中…");
            worker.execute(() -> {
                String msg = store.update(true);
                store.ensureEngine();
                main.post(() -> {
                    invalidateHostScripts();
                    status.setText(statusText());
                    update.setEnabled(true);
                    update.setText("立即更新规则");
                    Toast.makeText(this, msg, Toast.LENGTH_LONG).show();
                });
            });
        });
        box.addView(update);

        Button allow = new Button(this);
        allow.setText("白名单（" + BrowserPrefs.allowlist(this).size() + "）…");
        allow.setOnClickListener(v -> showAllowlist(allow));
        box.addView(allow);

        xyz.mio.app.update.UpdateUi.addSettingsSection(this, box);
        if (media != null) media.addSettings(box);

        TextView lic = new TextView(this);
        lic.setText("\n开源组件：Brave adblock-rust（MPL-2.0）、AdGuard Scriptlets / ExtendedCss（GPL-3.0）；过滤列表：AdGuard（GPL-3.0）、EasyList / EasyPrivacy（GPL-3.0 / CC BY-SA 3.0）。详见仓库 NOTICE。");
        lic.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
        box.addView(lic);

        AlertDialog d = new AlertDialog.Builder(this)
                .setTitle("浏览器与广告拦截")
                .setView(scroll)
                .setPositiveButton("完成", null)
                .create();
        d.setOnDismissListener(x -> {
            if (finishOnClose && webView.getUrl() == null) finish();
        });
        d.show();
    }

    private void showAllowlist(Button counter) {
        List<String> list = BrowserPrefs.allowlist(this);
        String[] items = list.toArray(new String[0]);
        boolean[] checked = new boolean[items.length];
        new AlertDialog.Builder(this)
                .setTitle(items.length == 0 ? "白名单为空" : "勾选要移除的网站")
                .setMultiChoiceItems(items, checked, (d, which, isChecked) -> checked[which] = isChecked)
                .setPositiveButton("移除所选", (d, w) -> {
                    List<String> keep = new ArrayList<>();
                    for (int i = 0; i < items.length; i++) if (!checked[i]) keep.add(items[i]);
                    BrowserPrefs.setAllowlist(this, keep);
                    counter.setText("白名单（" + keep.size() + "）…");
                    afterSettingChange(false);
                })
                .setNeutralButton("添加…", (d, w) -> {
                    EditText input = new EditText(this);
                    input.setHint("example.com");
                    input.setInputType(InputType.TYPE_TEXT_VARIATION_URI);
                    String h = hostOf(webView.getUrl());
                    if (h != null) input.setText(BrowserPrefs.normalize(h));
                    new AlertDialog.Builder(this)
                            .setTitle("添加到白名单（含子域名）")
                            .setView(input)
                            .setPositiveButton("添加", (d2, w2) -> {
                                String t = input.getText().toString();
                                if (!TextUtils.isEmpty(t)) BrowserPrefs.setAllowlisted(this, t, true);
                                counter.setText("白名单（" + BrowserPrefs.allowlist(this).size() + "）…");
                                afterSettingChange(false);
                            })
                            .setNegativeButton("取消", null)
                            .show();
                })
                .setNegativeButton("关闭", null)
                .show();
    }
}
