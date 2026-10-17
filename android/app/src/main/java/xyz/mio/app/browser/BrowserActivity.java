package xyz.mio.app.browser;

import android.annotation.SuppressLint;
import android.app.Activity;
import android.app.AlertDialog;
import android.content.ActivityNotFoundException;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ApplicationInfo;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.graphics.drawable.InsetDrawable;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.Message;
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
import android.widget.ImageView;
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
import java.io.File;
import java.nio.charset.StandardCharsets;
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
 * App 内置浏览器（独立进程 :browser → 独立的 WebView 数据目录，与 MioCore 主界面的会话互不影响；独立任务，可收起到后台）。
 * 多标签页：每个标签一个 WebView（共享同一个 Cookie / 存储），per-tab setup 在 {@link #createWebView(Tab)}：
 * 拦截（shouldInterceptRequest → adblock-rust）、按主机名预注册的 document-start 脚本、通用 document-start 脚本、
 * YouTube 防沉迷等按 WebView 注册的功能都对每个标签各自安装。标签管理纯逻辑在 {@link TabsCore}。
 * 收起（⌄ / 返回键）= moveTaskToBack：标签都留在后台；Mio 主界面右下角显示标签数角标（{@link TabsBadge}），点一下回来。
 * 同时加载的 WebView 最多 MAX_LOADED 个，超出时按最近使用卸载后台标签（saveState 保留历史，切回时恢复）。
 */
public class BrowserActivity extends Activity {
    private static final String TAG = "MioTabs";
    private static final String EXTRA_URL = "url";
    private static final String EXTRA_SETTINGS = "settings";
    private static final String EXTRA_COOKIES = "siteCookies";
    private static final String EXTRA_SMOKE = "mioTabsSmoke";
    static final String SITE_ORIGIN = "https://mio.300031.xyz";
    private static final int MAX_LOADED = 5;
    private static boolean dataSuffixSet;

    /** 打开内置浏览器（独立任务）。主进程里调用时顺便带上 MioCore 的登录 Cookie，新标签页打开 MioCore 导航时沿用登录状态 */
    public static Intent intent(Context c, String url, boolean settings) {
        Intent i = new Intent(c, BrowserActivity.class);
        if (url != null) i.putExtra(EXTRA_URL, url);
        i.putExtra(EXTRA_SETTINGS, settings);
        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        try {
            String cookies = CookieManager.getInstance().getCookie(SITE_ORIGIN);
            if (cookies != null && !cookies.isEmpty()) i.putExtra(EXTRA_COOKIES, cookies);
        } catch (Throwable ignored) {
            // 主进程还没有 WebView：不带 Cookie
        }
        return i;
    }

    /** 一个标签：TabsCore 里的记录 + 它的 WebView 和按 WebView 的拦截状态 */
    final class Tab {
        final long id;
        WebView webView;
        volatile String topUrl = "";
        ScriptHandler genericHandler;
        final LinkedHashMap<String, ScriptHandler> hostScripts = new LinkedHashMap<>();
        long hostScriptsBuiltAt;
        YouTubeFocus ytFocus;
        int progress = 100;
        volatile boolean activeCache = true;
        volatile String activeCacheHost = "";

        Tab(long id) { this.id = id; }
    }

    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private final CloseAfterExternal closeAfterExternal = new CloseAfterExternal();
    private final TabsCore tabs = new TabsCore();
    private final Map<Long, Tab> loaded = new HashMap<>();
    private final Map<Long, Bundle> savedStates = new HashMap<>();
    private final Map<Long, Bitmap> thumbs = new HashMap<>();
    private AdblockStore store;
    /** 当前标签的 WebView / 防沉迷（工具栏、设置等按「当前页」操作的代码用） */
    private WebView webView;
    private YouTubeFocus ytFocus;
    private Tab current;
    private FrameLayout webFrame;
    private FrameLayout overview;
    private EditText address;
    private TextView shield;
    private ProgressBar progress;
    private Button backBtn, fwdBtn, reloadBtn, tabsBtn;
    private FrameLayout fullscreen;
    private View customView;
    private WebChromeClient.CustomViewCallback customCallback;
    private volatile boolean engineReady;
    private boolean docStartSupported;
    private boolean ready;
    private final Runnable saveRunnable = this::saveNow;

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
        docStartSupported = WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT);
        buildUi();
        applyCookies(getIntent());
        tabs.restore(readSession(), TabContainers.knownIds());

        Intent in = getIntent();
        String url = in.getStringExtra(EXTRA_URL);
        boolean settings = in.getBooleanExtra(EXTRA_SETTINGS, false);
        boolean smoke = in.getBooleanExtra(EXTRA_SMOKE, false) && isDebuggable();
        worker.execute(() -> {
            store.ensureEngine();
            engineReady = store.isReady();
            main.post(() -> {
                ready = true;
                if (url != null) openTab(url, true, false, null);
                else if (tabs.isEmpty() && !settings) openTab(newTabUrl(), true, false, null);
                else showActive();
                if (settings) showSettings(url == null && tabs.isEmpty());
                if (smoke) main.postDelayed(this::runTabsSmoke, 6000);
            });
        });
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        applyCookies(intent);
        String url = intent.getStringExtra(EXTRA_URL);
        // MioCore 里点外链：新标签打开
        if (url != null) {
            if (ready) openTab(url, true, false, null);
        } else if (ready && tabs.isEmpty()) {
            openTab(newTabUrl(), true, false, null);
        }
        if (intent.getBooleanExtra(EXTRA_SETTINGS, false)) showSettings(false);
        if (intent.getBooleanExtra(EXTRA_SMOKE, false) && isDebuggable()) main.postDelayed(this::runTabsSmoke, 6000);
    }

    @Override
    protected void onResume() {
        super.onResume();
        closeAfterExternal.onResume();
        // 主进程（WorkManager）可能更新了规则
        worker.execute(() -> {
            long before = store.builtAt();
            store.ensureEngine();
            if (store.builtAt() != before) main.post(this::invalidateHostScripts);
        });
    }

    @Override
    protected void onPause() {
        super.onPause();
        saveNow();
    }

    @Override
    protected void onStop() {
        super.onStop();
        // 跳转系统浏览器后自动关闭标签页：外部浏览器盖住本页后关闭当前标签（统一的 closeTab；最后一个标签 → 关闭浏览器，App 不退出）
        if (closeAfterExternal.onStop(isChangingConfigurations()) && current != null) closeTab(current.id);
    }

    @Override
    protected void onDestroy() {
        worker.shutdownNow();
        main.removeCallbacks(saveRunnable);
        for (Tab t : new ArrayList<>(loaded.values())) destroyWebView(t);
        loaded.clear();
        super.onDestroy();
    }

    @Override
    public void onBackPressed() {
        if (overview != null && overview.getVisibility() == View.VISIBLE) {
            hideOverview();
        } else if (customView != null) {
            hideCustomView();
        } else if (webView != null && webView.canGoBack()) {
            webView.goBack();
        } else if (current != null) {
            // 没有历史：从别的标签打开的 → 关掉回到那个标签；否则收起浏览器（标签保留）
            TabsCore.Tab rec = tabs.get(current.id);
            if (rec != null && rec.openerId != null && tabs.get(rec.openerId) != null) {
                long opener = rec.openerId;
                closeTab(current.id);
                selectTab(opener);
            } else {
                hideBrowser();
            }
        } else {
            super.onBackPressed();
        }
    }

    private boolean isDebuggable() {
        return (getApplicationInfo().flags & ApplicationInfo.FLAG_DEBUGGABLE) != 0;
    }

    /** 主进程带来的 MioCore Cookie（含 Cloudflare Access）写进浏览器进程的 CookieManager */
    private void applyCookies(Intent intent) {
        String raw = intent == null ? null : intent.getStringExtra(EXTRA_COOKIES);
        if (raw == null || raw.isEmpty()) return;
        CookieManager cm = CookieManager.getInstance();
        for (String part : raw.split(";")) {
            String kv = part.trim();
            if (kv.isEmpty() || !kv.contains("=")) continue;
            cm.setCookie(SITE_ORIGIN, kv + "; Path=/; Secure; HttpOnly");
        }
        cm.flush();
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
        top.addView(glyph("⌄", "收起浏览器（标签保留在后台）", v -> hideBrowser()), new LinearLayout.LayoutParams(dp(44), dp(44)));
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
            if (has) address.setText(webView != null && webView.getUrl() != null ? webView.getUrl() : "");
            else updateAddress();
        });
        top.addView(address, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1));
        shield = glyph("🛡", "广告拦截", v -> showShieldMenu());
        top.addView(shield, new LinearLayout.LayoutParams(dp(44), dp(44)));
        col.addView(top, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        progress = new ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal);
        progress.setMax(100);
        col.addView(progress, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(3)));

        // 每个标签的 WebView 都放在这里，只有当前标签可见
        webFrame = new FrameLayout(this);
        col.addView(webFrame, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1));

        LinearLayout bottom = new LinearLayout(this);
        bottom.setOrientation(LinearLayout.HORIZONTAL);
        bottom.setGravity(Gravity.CENTER);
        backBtn = glyph("‹", "后退", v -> { if (webView != null && webView.canGoBack()) webView.goBack(); });
        fwdBtn = glyph("›", "前进", v -> { if (webView != null && webView.canGoForward()) webView.goForward(); });
        reloadBtn = glyph("↻", "刷新", v -> {
            if (webView == null) return;
            if (current != null && current.progress < 100) webView.stopLoading();
            else webView.reload();
        });
        Button share = glyph("⇪", "分享", v -> share());
        Button external = glyph("↗", "用系统浏览器打开", v -> openExternal(webView != null ? webView.getUrl() : null));
        Button settings = glyph("⚙", "浏览器设置", v -> showSettings(false));
        tabsBtn = glyph("1", "标签页", v -> showOverview());
        tabsBtn.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13);
        tabsBtn.setTypeface(Typeface.DEFAULT_BOLD);
        GradientDrawable box = new GradientDrawable();
        box.setCornerRadius(dp(5));
        box.setStroke(dp(2), 0xFF888888);
        InsetDrawable inset = new InsetDrawable(box, dp(14), dp(12), dp(14), dp(12));
        tabsBtn.setBackground(inset);
        tabsBtn.setOnLongClickListener(v -> { showTabsMenu(); return true; });
        for (Button b : new Button[]{backBtn, fwdBtn, reloadBtn, share, external, settings, tabsBtn}) {
            bottom.addView(b, new LinearLayout.LayoutParams(0, dp(48), 1));
        }
        col.addView(bottom, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        overview = new FrameLayout(this);
        overview.setVisibility(View.GONE);
        root.addView(overview, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));

        fullscreen = new FrameLayout(this);
        fullscreen.setBackgroundColor(Color.BLACK);
        fullscreen.setVisibility(View.GONE);
        root.addView(fullscreen, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));

        // Android 15 起强制 edge-to-edge：内容避开状态栏 / 导航栏 / 键盘
        ViewCompat.setOnApplyWindowInsetsListener(col, (v, insets) -> {
            Insets bars = insets.getInsets(WindowInsetsCompat.Type.systemBars() | WindowInsetsCompat.Type.displayCutout() | WindowInsetsCompat.Type.ime());
            v.setPadding(bars.left, bars.top, bars.right, bars.bottom);
            overview.setPadding(bars.left, bars.top, bars.right, bars.bottom);
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
        if (webView == null) { address.setText(""); return; }
        String u = webView.getUrl();
        String host = u != null ? Uri.parse(u).getHost() : null;
        String title = webView.getTitle();
        if (host == null) host = "";
        address.setText(title != null && !title.isEmpty() && !title.equals(u) ? title + " — " + host : host);
    }

    private void updateButtons() {
        if (tabsBtn != null) {
            int n = tabs.size();
            tabsBtn.setText(n > 99 ? "∞" : String.valueOf(Math.max(n, 0)));
            tabsBtn.setContentDescription(n + " 个标签页");
        }
        if (webView == null) return;
        backBtn.setEnabled(webView.canGoBack());
        fwdBtn.setEnabled(webView.canGoForward());
        backBtn.setAlpha(webView.canGoBack() ? 1f : 0.35f);
        fwdBtn.setAlpha(webView.canGoForward() ? 1f : 0.35f);
    }

    private void updateShield() {
        boolean on = isActive(hostOf(current != null ? current.topUrl : null));
        shield.setText(on ? "🛡" : "⛔");
        shield.setAlpha(on ? 1f : 0.6f);
    }

    private void updateProgress() {
        int p = current != null ? current.progress : 100;
        progress.setProgress(p);
        progress.setVisibility(p >= 100 ? View.INVISIBLE : View.VISIBLE);
        reloadBtn.setText(p >= 100 ? "↻" : "✕");
    }

    static String urlFromInput(String text) {
        String t = text.trim();
        if (t.isEmpty()) return null;
        Uri u = Uri.parse(t);
        if (u.getScheme() != null && (u.getScheme().equals("http") || u.getScheme().equals("https")) && u.getHost() != null) return t;
        if (!t.contains(" ") && t.contains(".")) return "https://" + t;
        return "https://www.google.com/search?q=" + Uri.encode(t);
    }

    // ---------------------------------------------------------------- tabs

    private String newTabUrl() {
        String u = TabsCore.normalizeNewTabUrl(BrowserPrefs.newTabUrl(this));
        return u != null ? u : TabsCore.DEFAULT_NEW_TAB_URL;
    }

    /** 新标签：fromCurrent = 从当前标签打开（插在它右边，继承容器 / 锁定） */
    private TabsCore.Tab openTab(String url, boolean activate, boolean fromCurrent, String containerId) {
        String target = TabsCore.isHttp(url) ? url : newTabUrl();
        TabsCore.Tab rec = tabs.add(target, TabsCore.Opts.make().activate(activate).fromActive(fromCurrent).container(containerId));
        if (rec == null) {
            Toast.makeText(this, "最多同时打开 " + tabs.maxTabs + " 个标签", Toast.LENGTH_SHORT).show();
            return null;
        }
        Tab t = ensureLoaded(rec.id, false);
        if (t != null && t.webView.getUrl() == null) {
            t.topUrl = target;
            prepare(t, target);
            t.webView.loadUrl(target);
        }
        if (activate) showActive();
        else updateButtons();
        scheduleSave();
        return rec;
    }

    /** 标签的 WebView（没有就建：恢复卸载前的历史，否则不加载——调用方决定 loadUrl） */
    private Tab ensureLoaded(long id, boolean loadIfNew) {
        Tab t = loaded.get(id);
        if (t != null) return t;
        TabsCore.Tab rec = tabs.get(id);
        if (rec == null) return null;
        t = new Tab(id);
        createWebView(t);
        loaded.put(id, t);
        webFrame.addView(t.webView, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        t.webView.setVisibility(View.INVISIBLE);
        Bundle state = savedStates.remove(id);
        boolean restored = false;
        if (state != null) {
            prepare(t, rec.url);
            t.topUrl = rec.url;
            restored = t.webView.restoreState(state) != null;
        }
        if (!restored && loadIfNew) {
            t.topUrl = rec.url;
            prepare(t, rec.url);
            t.webView.loadUrl(rec.url);
        }
        enforceLoadedLimit();
        return t;
    }

    private void showActive() {
        TabsCore.Tab rec = tabs.active();
        if (rec == null) return;
        Tab t = ensureLoaded(rec.id, true);
        if (t == null) return;
        if (current != null && current != t && current.webView != null) captureThumb(current);
        current = t;
        webView = t.webView;
        ytFocus = t.ytFocus;
        for (Tab x : loaded.values()) x.webView.setVisibility(x == t ? View.VISIBLE : View.INVISIBLE);
        t.webView.bringToFront();
        updateAddress();
        updateShield();
        updateButtons();
        updateProgress();
        if (overview.getVisibility() == View.VISIBLE) renderOverview();
    }

    private void selectTab(long id) {
        if (tabs.select(id)) {
            showActive();
            scheduleSave();
        }
    }

    /** 统一的关闭标签（✕、window.close()、返回键、跳转系统浏览器后自动关闭）；最后一个标签关掉 → 关闭浏览器回到 Mio（App 不退出） */
    private void closeTab(long id) {
        Tab t = loaded.remove(id);
        if (t != null) destroyWebView(t);
        savedStates.remove(id);
        thumbs.remove(id);
        if (current == t) { current = null; webView = null; ytFocus = null; }
        if (tabs.close(id) == null) return;
        saveNow();
        if (tabs.isEmpty()) {
            finish();
            return;
        }
        showActive();
    }

    private void reopenClosedTab() {
        TabsCore.Tab rec = tabs.reopenClosed();
        if (rec == null) return;
        showActive();
        scheduleSave();
    }

    /** 收起：任务移到后台，标签全部保留（不销毁） */
    private void hideBrowser() {
        saveNow();
        if (!moveTaskToBack(true)) finish();
    }

    private void unloadTab(long id) {
        if (current != null && current.id == id) return;
        Tab t = loaded.remove(id);
        if (t == null) return;
        captureThumb(t);
        Bundle state = new Bundle();
        try {
            if (t.webView.saveState(state) != null) savedStates.put(id, state);
        } catch (Exception ignored) {}
        destroyWebView(t);
    }

    private void enforceLoadedLimit() {
        for (Long id : tabs.toUnload(MAX_LOADED, x -> loaded.containsKey(x.id))) unloadTab(id);
    }

    private void destroyWebView(Tab t) {
        if (t.webView == null) return;
        try {
            webFrame.removeView(t.webView);
            t.webView.stopLoading();
            t.webView.destroy();
        } catch (Exception ignored) {}
    }

    private void captureThumb(Tab t) {
        WebView wv = t.webView;
        if (wv == null || wv.getWidth() <= 0 || wv.getHeight() <= 0) return;
        try {
            float scale = Math.min(1f, dp(180) / (float) wv.getWidth());
            int w = Math.max(1, (int) (wv.getWidth() * scale));
            int h = Math.max(1, (int) (Math.min(wv.getHeight(), wv.getWidth() * 1.3f) * scale));
            Bitmap bmp = Bitmap.createBitmap(w, h, Bitmap.Config.RGB_565);
            Canvas c = new Canvas(bmp);
            c.scale(scale, scale);
            wv.draw(c);
            thumbs.put(t.id, bmp);
        } catch (Throwable ignored) {}
    }

    private File sessionFile() { return new File(getFilesDir(), "browser-tabs.json"); }

    private String readSession() {
        try (java.io.FileInputStream in = new java.io.FileInputStream(sessionFile())) {
            java.io.ByteArrayOutputStream out = new java.io.ByteArrayOutputStream();
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
            return new String(out.toByteArray(), StandardCharsets.UTF_8);
        } catch (Exception e) {
            return null;
        }
    }

    private void scheduleSave() {
        main.removeCallbacks(saveRunnable);
        main.postDelayed(saveRunnable, 600);
    }

    /** 会话（与 Windows / iOS 同格式）：主进程的 TabsBadge 也读它显示标签数 */
    private void saveNow() {
        main.removeCallbacks(saveRunnable);
        try {
            File f = sessionFile();
            File tmp = new File(f.getPath() + ".tmp");
            try (java.io.FileOutputStream out = new java.io.FileOutputStream(tmp)) {
                out.write(tabs.serialize().getBytes(StandardCharsets.UTF_8));
            }
            //noinspection ResultOfMethodCallIgnored
            tmp.renameTo(f);
        } catch (Exception ignored) {}
    }

    private void showTabsMenu() {
        List<String> items = new ArrayList<>();
        List<Runnable> actions = new ArrayList<>();
        items.add("新建标签页");
        actions.add(() -> openTab(newTabUrl(), true, false, null));
        List<TabContainers.Info> containers = TabContainers.list(this);
        if (containers.size() > 1 && TabContainers.supported()) {
            items.add("在容器中新建标签页…");
            actions.add(() -> pickContainer(id -> openTab(newTabUrl(), true, false, id)));
        }
        if (tabs.hasClosed()) {
            items.add("重新打开关闭的标签页");
            actions.add(this::reopenClosedTab);
        }
        items.add("关闭此标签页");
        actions.add(() -> { if (current != null) closeTab(current.id); });
        items.add("收起浏览器（标签保留）");
        actions.add(this::hideBrowser);
        new AlertDialog.Builder(this)
                .setItems(items.toArray(new String[0]), (d, which) -> actions.get(which).run())
                .show();
    }

    interface ContainerPick { void pick(String id); }

    private void pickContainer(ContainerPick cb) {
        List<TabContainers.Info> list = TabContainers.list(this);
        String[] names = new String[list.size()];
        for (int i = 0; i < names.length; i++) names[i] = list.get(i).name;
        new AlertDialog.Builder(this)
                .setTitle("选择容器")
                .setItems(names, (d, which) -> cb.pick(list.get(which).id))
                .setNegativeButton("取消", null)
                .show();
    }

    // ---------------------------------------------------------------- overview（网格卡片）

    private void showOverview() {
        if (current != null) captureThumb(current);
        renderOverview();
        overview.setVisibility(View.VISIBLE);
        overview.bringToFront();
    }

    private void hideOverview() {
        overview.setVisibility(View.GONE);
    }

    private void renderOverview() {
        overview.removeAllViews();
        boolean dark = (getResources().getConfiguration().uiMode & android.content.res.Configuration.UI_MODE_NIGHT_MASK) == android.content.res.Configuration.UI_MODE_NIGHT_YES;
        int bg = dark ? 0xFF111111 : 0xFFF2F2F7;
        int card = dark ? 0xFF222222 : Color.WHITE;
        int fg = dark ? 0xFFEEEEEE : 0xFF111111;
        overview.setBackgroundColor(bg);
        LinearLayout col = new LinearLayout(this);
        col.setOrientation(LinearLayout.VERTICAL);
        overview.addView(col, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));

        LinearLayout bar = new LinearLayout(this);
        bar.setGravity(Gravity.CENTER_VERTICAL);
        bar.setPadding(dp(8), dp(4), dp(8), dp(4));
        Button hide = glyph("⌄", "收起浏览器", v -> { hideOverview(); hideBrowser(); });
        bar.addView(hide, new LinearLayout.LayoutParams(dp(48), dp(48)));
        Button reopen = glyph("↶", "重新打开关闭的标签页", v -> { reopenClosedTab(); renderOverview(); });
        reopen.setEnabled(tabs.hasClosed());
        reopen.setAlpha(tabs.hasClosed() ? 1f : 0.35f);
        bar.addView(reopen, new LinearLayout.LayoutParams(dp(48), dp(48)));
        TextView count = new TextView(this);
        count.setText(tabs.size() + " 个标签页");
        count.setTextColor(fg);
        count.setGravity(Gravity.CENTER);
        count.setTypeface(Typeface.DEFAULT_BOLD);
        bar.addView(count, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1));
        Button add = glyph("＋", "新建标签页", v -> { hideOverview(); openTab(newTabUrl(), true, false, null); });
        add.setOnLongClickListener(v -> { if (TabContainers.list(this).size() > 1 && TabContainers.supported()) pickContainer(id -> { hideOverview(); openTab(newTabUrl(), true, false, id); }); return true; });
        bar.addView(add, new LinearLayout.LayoutParams(dp(48), dp(48)));
        Button done = glyph("完成", "完成", v -> hideOverview());
        done.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16);
        bar.addView(done, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, dp(48)));
        col.addView(bar);

        ScrollView scroll = new ScrollView(this);
        LinearLayout grid = new LinearLayout(this);
        grid.setOrientation(LinearLayout.VERTICAL);
        grid.setPadding(dp(10), dp(4), dp(10), dp(16));
        scroll.addView(grid);
        col.addView(scroll, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1));

        int columns = getResources().getConfiguration().screenWidthDp >= 600 ? 3 : 2;
        LinearLayout row = null;
        List<TabsCore.Tab> list = tabs.tabs();
        for (int i = 0; i < list.size(); i++) {
            if (i % columns == 0) {
                row = new LinearLayout(this);
                row.setOrientation(LinearLayout.HORIZONTAL);
                grid.addView(row);
            }
            final TabsCore.Tab rec = list.get(i);
            LinearLayout c = new LinearLayout(this);
            c.setOrientation(LinearLayout.VERTICAL);
            GradientDrawable shape = new GradientDrawable();
            shape.setColor(card);
            shape.setCornerRadius(dp(12));
            boolean isActive = tabs.activeId() != null && tabs.activeId() == rec.id;
            if (isActive) shape.setStroke(dp(3), 0xFF2563EB);
            c.setBackground(shape);
            c.setPadding(dp(6), dp(6), dp(6), dp(8));
            FrameLayout thumbBox = new FrameLayout(this);
            ImageView img = new ImageView(this);
            img.setScaleType(ImageView.ScaleType.CENTER_CROP);
            Bitmap bmp = thumbs.get(rec.id);
            String host = TabsCore.displayHost(rec.url);
            if (bmp != null) {
                img.setImageBitmap(bmp);
            } else {
                img.setBackgroundColor(dark ? 0xFF333333 : 0xFFE5E5EA);
            }
            thumbBox.addView(img, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
            if (bmp == null) {
                TextView letter = new TextView(this);
                letter.setText(host.isEmpty() ? "·" : host.substring(0, 1).toUpperCase(Locale.ROOT));
                letter.setTextSize(TypedValue.COMPLEX_UNIT_SP, 34);
                letter.setTextColor(0xFF999999);
                letter.setGravity(Gravity.CENTER);
                thumbBox.addView(letter, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
            }
            TextView x = new TextView(this);
            x.setText("✕");
            x.setTextColor(Color.WHITE);
            x.setGravity(Gravity.CENTER);
            GradientDrawable circle = new GradientDrawable();
            circle.setShape(GradientDrawable.OVAL);
            circle.setColor(0x99000000);
            x.setBackground(circle);
            x.setContentDescription("关闭标签页");
            x.setOnClickListener(v -> { closeTab(rec.id); if (!isFinishing()) renderOverview(); });
            FrameLayout.LayoutParams xl = new FrameLayout.LayoutParams(dp(28), dp(28), Gravity.TOP | Gravity.END);
            xl.setMargins(0, dp(4), dp(4), 0);
            thumbBox.addView(x, xl);
            c.addView(thumbBox, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(150)));
            TabContainers.Info ci = "default".equals(rec.containerId) ? null : TabContainers.find(this, rec.containerId);
            if (ci != null) {
                View stripe = new View(this);
                stripe.setBackgroundColor(ci.color);
                c.addView(stripe, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(3)));
            }
            TextView title = new TextView(this);
            Tab lt = loaded.get(rec.id);
            String tt = lt != null && lt.webView.getTitle() != null && !lt.webView.getTitle().isEmpty() ? lt.webView.getTitle() : rec.title;
            title.setText((rec.locked ? "🔒 " : "") + (tt == null || tt.isEmpty() ? (host.isEmpty() ? "新标签页" : host) : tt));
            title.setSingleLine(true);
            title.setEllipsize(TextUtils.TruncateAt.END);
            title.setTextColor(fg);
            title.setTypeface(Typeface.DEFAULT_BOLD);
            title.setPadding(dp(2), dp(6), dp(2), 0);
            c.addView(title);
            TextView h = new TextView(this);
            h.setText(host);
            h.setSingleLine(true);
            h.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
            h.setTextColor(0xFF888888);
            h.setPadding(dp(2), 0, dp(2), 0);
            c.addView(h);
            c.setContentDescription(title.getText() + "，" + host + (isActive ? "，当前标签" : ""));
            c.setOnClickListener(v -> { hideOverview(); selectTab(rec.id); });
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1);
            lp.setMargins(dp(6), dp(6), dp(6), dp(6));
            row.addView(c, lp);
        }
        if (row != null) {
            for (int k = list.size() % columns; k != 0 && k < columns; k++) {
                row.addView(new View(this), new LinearLayout.LayoutParams(0, 1, 1));
            }
        }
    }

    // ---------------------------------------------------------------- WebView（per-tab setup）

    /** 一个标签的 WebView 和它的全部按 WebView 注册的功能。新的按 WebView 功能挂在这里，每个标签各自安装 */
    @SuppressLint({"SetJavaScriptEnabled", "AddJavascriptInterface"})
    private void createWebView(Tab t) {
        WebView wv = new WebView(this);
        t.webView = wv;
        TabsCore.Tab rec = tabs.get(t.id);
        // 容器（登录隔离）：feat/containers-core 提供的 Profile 绑定，必须在任何加载之前
        TabContainers.bind(wv, rec != null ? rec.containerId : TabsCore.DEFAULT_CONTAINER);
        WebSettings s = wv.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setDatabaseEnabled(true);
        s.setMediaPlaybackRequiresUserGesture(false);
        // target=_blank / window.open → onCreateWindow 开新标签（只接受用户手势触发的）
        s.setSupportMultipleWindows(true);
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
        CookieManager.getInstance().setAcceptThirdPartyCookies(wv, true);
        wv.addJavascriptInterface(new Bridge(t), "MioAdblockBridge");
        // YouTube 防沉迷：先于通用脚本注册（通用脚本之后每次都会重新注册到最后）
        t.ytFocus = new YouTubeFocus(this, wv);
        t.ytFocus.install();
        installGenericScript(t);

        wv.setOnLongClickListener(v -> onLongPress(t));

        wv.setWebViewClient(new WebViewClient() {
            @Override
            public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                Uri uri = request.getUrl();
                String scheme = uri.getScheme() == null ? "" : uri.getScheme().toLowerCase(Locale.ROOT);
                if (scheme.equals("http") || scheme.equals("https")) {
                    if (request.isForMainFrame()) prepare(t, uri.toString());
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
                t.topUrl = url;
                prepare(t, url);
                t.ytFocus.onPage(url);
                if (t == current) {
                    updateAddress();
                    updateShield();
                    updateButtons();
                }
            }

            @Override
            public void onPageCommitVisible(WebView view, String url) {
                t.ytFocus.onPage(url);
            }

            @Override
            public void onPageFinished(WebView view, String url) {
                t.ytFocus.onPage(url);
                t.ytFocus.reportState(url);
                if (tabs.update(t.id, TabsCore.isHttp(url) ? url : null, view.getTitle())) scheduleSave();
                if (t == current) {
                    updateAddress();
                    updateButtons();
                }
            }

            @Override
            public void doUpdateVisitedHistory(WebView view, String url, boolean isReload) {
                t.topUrl = url;
                if (tabs.update(t.id, TabsCore.isHttp(url) ? url : null, null)) scheduleSave();
                if (t == current) {
                    updateButtons();
                    updateAddress();
                }
            }

            @Override
            public WebResourceResponse shouldInterceptRequest(WebView view, WebResourceRequest request) {
                return intercept(t, request);
            }

            @Override
            public boolean onRenderProcessGone(WebView view, android.webkit.RenderProcessGoneDetail detail) {
                // 网页进程崩溃：这个标签的 WebView 作废；当前标签马上重建并重新加载
                main.post(() -> {
                    Tab gone = loaded.remove(t.id);
                    if (gone != null) {
                        try { webFrame.removeView(gone.webView); gone.webView.destroy(); } catch (Exception ignored) {}
                    }
                    if (current == t) {
                        current = null;
                        webView = null;
                        showActive();
                    }
                });
                return true;
            }
        });

        wv.setWebChromeClient(new WebChromeClient() {
            @Override
            public void onProgressChanged(WebView view, int p) {
                t.progress = p;
                if (t == current) updateProgress();
            }

            @Override
            public void onReceivedTitle(WebView view, String title) {
                if (tabs.update(t.id, null, title)) scheduleSave();
                if (t == current) updateAddress();
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
            public boolean onCreateWindow(WebView view, boolean isDialog, boolean isUserGesture, Message resultMsg) {
                // 新窗口 = 新标签（继承容器 / 锁定，插在来源标签右边）；没有用户手势的弹窗不开
                if (!isUserGesture) return false;
                if (current != t) selectTab(t.id);
                TabsCore.Tab rec = tabs.add("", TabsCore.Opts.make().activate(true).fromActive(true));
                if (rec == null) {
                    Toast.makeText(BrowserActivity.this, "最多同时打开 " + tabs.maxTabs + " 个标签", Toast.LENGTH_SHORT).show();
                    return false;
                }
                Tab nt = ensureLoaded(rec.id, false);
                if (nt == null) return false;
                WebView.WebViewTransport transport = (WebView.WebViewTransport) resultMsg.obj;
                transport.setWebView(nt.webView);
                resultMsg.sendToTarget();
                showActive();
                scheduleSave();
                return true;
            }

            @Override
            public void onCloseWindow(WebView window) {
                // window.close()：关掉这个标签
                if (loaded.get(t.id) != null) closeTab(t.id);
            }
        });
    }

    /** 长按链接：在新标签页打开 / 在容器中打开 / 复制 / 系统浏览器 */
    private boolean onLongPress(Tab t) {
        WebView.HitTestResult r = t.webView.getHitTestResult();
        if (r == null) return false;
        int type = r.getType();
        if (type == WebView.HitTestResult.SRC_ANCHOR_TYPE) {
            showLinkMenu(t, r.getExtra());
            return true;
        }
        if (type == WebView.HitTestResult.SRC_IMAGE_ANCHOR_TYPE) {
            Message msg = main.obtainMessage();
            msg.setTarget(new Handler(Looper.getMainLooper(), m -> {
                String href = m.getData().getString("url");
                showLinkMenu(t, href != null ? href : r.getExtra());
                return true;
            }));
            t.webView.requestFocusNodeHref(msg);
            return true;
        }
        return false;
    }

    private void showLinkMenu(Tab t, String url) {
        if (!TabsCore.isHttp(url)) return;
        List<String> items = new ArrayList<>();
        List<Runnable> actions = new ArrayList<>();
        items.add("在新标签页中打开");
        actions.add(() -> { if (current != t) selectTab(t.id); openTab(url, false, true, null); Toast.makeText(this, "已在后台标签页打开", Toast.LENGTH_SHORT).show(); });
        items.add("在新标签页中打开并切换");
        actions.add(() -> { if (current != t) selectTab(t.id); openTab(url, true, true, null); });
        TabsCore.Tab rec = tabs.get(t.id);
        if (TabContainers.list(this).size() > 1 && TabContainers.supported() && (rec == null || !rec.locked)) {
            items.add("在容器中打开…");
            actions.add(() -> pickContainer(id -> { if (current != t) selectTab(t.id); openTab(url, true, true, id); }));
        }
        items.add("复制链接地址");
        actions.add(() -> {
            ClipboardManager cm = (ClipboardManager) getSystemService(CLIPBOARD_SERVICE);
            if (cm != null) cm.setPrimaryClip(ClipData.newPlainText("url", url));
        });
        items.add("用系统浏览器打开");
        actions.add(() -> openExternal(url));
        new AlertDialog.Builder(this)
                .setTitle(url)
                .setItems(items.toArray(new String[0]), (d, which) -> actions.get(which).run())
                .show();
    }

    private void hideCustomView() {
        if (customView == null) return;
        fullscreen.removeView(customView);
        fullscreen.setVisibility(View.GONE);
        customView = null;
        if (customCallback != null) customCallback.onCustomViewHidden();
        customCallback = null;
    }

    /** 当前标签打开 url（地址栏） */
    private void load(String url) {
        if (current == null) {
            openTab(url, true, false, null);
            return;
        }
        current.topUrl = url;
        prepare(current, url);
        current.webView.loadUrl(url);
    }

    // ---------------------------------------------------------------- blocking

    private static String hostOf(String url) {
        if (url == null) return null;
        try { return Uri.parse(url).getHost(); } catch (Exception e) { return null; }
    }

    private boolean isActive(String host) {
        return BrowserPrefs.adblockEnabled(this) && BrowserPrefs.allowlistEntry(this, host) == null;
    }

    /** 网络线程里调用：缓存当前主机的开关状态，避免每个请求都读设置文件 */
    private boolean activeFor(Tab t, String host) {
        String h = host == null ? "" : host;
        if (!h.equals(t.activeCacheHost)) {
            t.activeCache = isActive(h);
            t.activeCacheHost = h;
        }
        return t.activeCache;
    }

    private void invalidateActive() {
        for (Tab t : loaded.values()) t.activeCacheHost = "\u0000";
    }

    private WebResourceResponse intercept(Tab t, WebResourceRequest request) {
        if (!engineReady || request.isForMainFrame()) return null;
        String url = request.getUrl().toString();
        if (!url.startsWith("http")) return null;
        String top = t.topUrl;
        if (!activeFor(t, hostOf(top))) return null;
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

    private void installGenericScript(Tab t) {
        if (!docStartSupported || t.webView == null) return;
        if (t.genericHandler != null) t.genericHandler.remove();
        t.genericHandler = WebViewCompat.addDocumentStartJavaScript(t.webView, GENERIC_JS, Collections.singleton("*"));
    }

    /** 规则 / 开关变化：所有标签的主机脚本作废 */
    private void invalidateHostScripts() {
        for (Tab t : loaded.values()) {
            for (ScriptHandler sh : t.hostScripts.values()) sh.remove();
            t.hostScripts.clear();
        }
        invalidateActive();
        if (shield != null) updateShield();
    }

    /** 主框架即将打开 url：为该主机注册 document-start 脚本（页面脚本之前执行，不经 eval）；每个标签各自注册 */
    private void prepare(Tab t, String url) {
        if (!docStartSupported || !engineReady || t.webView == null) return;
        String host = hostOf(url);
        if (host == null) return;
        host = host.toLowerCase(Locale.ROOT);
        if (store.builtAt() != t.hostScriptsBuiltAt) {
            for (ScriptHandler sh : t.hostScripts.values()) sh.remove();
            t.hostScripts.clear();
            t.activeCacheHost = "\u0000";
            t.hostScriptsBuiltAt = store.builtAt();
        }
        if (t.hostScripts.containsKey(host)) {
            ScriptHandler sh = t.hostScripts.remove(host);
            t.hostScripts.put(host, sh); // LRU
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
            ScriptHandler sh = WebViewCompat.addDocumentStartJavaScript(t.webView, wrapped, rules);
            t.hostScripts.put(host, sh);
        } catch (Exception e) {
            return;
        }
        while (t.hostScripts.size() > 8) {
            String oldest = t.hostScripts.keySet().iterator().next();
            ScriptHandler old = t.hostScripts.remove(oldest);
            if (old != null) old.remove();
        }
        installGenericScript(t);
    }

    private class Bridge {
        private final Tab t;

        Bridge(Tab t) { this.t = t; }

        @JavascriptInterface
        public String script(String url, boolean top) {
            String host = hostOf(top ? url : t.topUrl);
            if (!engineReady || !activeFor(t, host)) return null;
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
            if (!engineReady || !activeFor(t, hostOf(t.topUrl))) return null;
            long h = store.acquire();
            if (h == 0) return null;
            try {
                return AdblockNative.genericCss(h, url, json);
            } finally {
                store.release();
            }
        }
    }

    // ---------------------------------------------------------------- debug smoke（CI 模拟器：adb am start … --ez mioTabsSmoke true）

    private void runTabsSmoke() {
        try {
            final JSONObject r = new JSONObject();
            final long first = current != null ? current.id : -1;
            r.put("initial", tabs.size());
            openTab("https://example.com/", true, false, null);
            final Tab second = current;
            r.put("afterOpen", tabs.size());
            r.put("distinctWebViews", second != null && loaded.get(first) != null && second.webView != loaded.get(first).webView);
            // 后台标签也装了按 WebView 的脚本（YouTube 防沉迷）
            TabsCore.Tab bg = openTab("https://m.youtube.com/", false, true, null);
            r.put("activeStillSecond", current == second);
            main.postDelayed(() -> {
                Tab bt = bg != null ? loaded.get(bg.id) : null;
                if (bt == null) { logSmoke(r, false); return; }
                bt.webView.evaluateJavascript("!!window.__mioYTFocus", v -> {
                    try {
                        r.put("backgroundYtFocus", "true".equals(v));
                        r.put("secondUrl", second != null && second.webView.getUrl() != null ? second.webView.getUrl() : "null");
                        selectTab(first);
                        r.put("switchedBack", current != null && current.id == first && current.webView.getVisibility() == View.VISIBLE);
                        int before = tabs.size();
                        if (second != null) closeTab(second.id);
                        r.put("afterClose", tabs.size());
                        r.put("closedFreed", second == null || !loaded.containsKey(second.id));
                        reopenClosedTab();
                        r.put("afterReopen", tabs.size());
                        r.put("saved", new JSONObject(tabs.serialize()).getJSONArray("tabs").length());
                        boolean ok = r.getInt("afterOpen") == r.getInt("initial") + 1 && r.getBoolean("distinctWebViews")
                                && r.getBoolean("activeStillSecond") && r.getBoolean("backgroundYtFocus") && r.getBoolean("switchedBack")
                                && r.getInt("afterClose") == before - 1 && r.getBoolean("closedFreed") && r.getInt("afterReopen") == before;
                        logSmoke(r, ok);
                    } catch (Exception e) {
                        android.util.Log.e(TAG, "smoke", e);
                        logSmoke(r, false);
                    }
                });
            }, 12000);
        } catch (Exception e) {
            android.util.Log.e(TAG, "smoke", e);
        }
    }

    private void logSmoke(JSONObject r, boolean ok) {
        try { r.put("ok", ok); } catch (Exception ignored) {}
        android.util.Log.i(TAG, "smoke " + r);
    }

    // ---------------------------------------------------------------- actions

    private void share() {
        String u = curUrl();
        if (u == null) return;
        Intent i = new Intent(Intent.ACTION_SEND);
        i.setType("text/plain");
        i.putExtra(Intent.EXTRA_TEXT, u);
        startActivity(Intent.createChooser(i, "分享"));
    }

    private void openExternal(String url) {
        if (url == null) return;
        boolean launched = false;
        try {
            Intent i = new Intent(Intent.ACTION_VIEW, Uri.parse(url));
            startActivity(Intent.createChooser(i, "用浏览器打开"));
            launched = true;
        } catch (ActivityNotFoundException ignored) {}
        closeAfterExternal.onLaunchResult(BrowserPrefs.closeTabAfterExternal(this), launched);
    }

    private void showShieldMenu() {
        String host = hostOf(curUrl());
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
        if (reload && current != null && webView.getUrl() != null) {
            prepare(current, webView.getUrl());
            webView.reload();
        }
    }

    /** 当前标签的地址（没有标签 → null） */
    private String curUrl() {
        return webView != null ? webView.getUrl() : null;
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
        String host = hostOf(curUrl());
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

        Switch closeTab = new Switch(this);
        closeTab.setText("跳转系统浏览器后自动关闭标签页");
        closeTab.setChecked(BrowserPrefs.closeTabAfterExternal(this));
        closeTab.setOnCheckedChangeListener((b, on) -> BrowserPrefs.setCloseTabAfterExternal(this, on));
        box.addView(closeTab);

        Button newTabBtn = new Button(this);
        newTabBtn.setAllCaps(false);
        String customNewTab = BrowserPrefs.newTabUrl(this);
        newTabBtn.setText("新标签页地址：" + (customNewTab == null || customNewTab.isEmpty() ? "MioCore 导航（默认）" : customNewTab));
        newTabBtn.setOnClickListener(v -> editNewTabUrl(newTabBtn));
        box.addView(newTabBtn);

        TextView title = new TextView(this);
        title.setText("\n过滤规则（AdGuard 官方源，超过 24 小时自动检查更新）");
        title.setTypeface(Typeface.DEFAULT_BOLD);
        box.addView(title);
        TextView status = new TextView(this);
        status.setText(statusText());
        status.setTextIsSelectable(true);
        box.addView(status);

        YouTubeFocus.addSettings(this, box, () -> {
            // 每个标签各自重新注册
            for (Tab t : loaded.values()) {
                t.ytFocus.install();
                if (YouTubeFocus.isYouTubeUrl(t.webView.getUrl())) t.webView.reload();
            }
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
            if (finishOnClose && curUrl() == null) finish();
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
                    String h = hostOf(curUrl());
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

    private void editNewTabUrl(Button label) {
        EditText input = new EditText(this);
        input.setHint(TabsCore.DEFAULT_NEW_TAB_URL);
        input.setInputType(InputType.TYPE_TEXT_VARIATION_URI);
        input.setText(BrowserPrefs.newTabUrl(this));
        new AlertDialog.Builder(this)
                .setTitle("新标签页地址")
                .setMessage("留空 = MioCore 导航（沿用主界面的登录状态）")
                .setView(input)
                .setPositiveButton("保存", (d, w) -> {
                    String n = TabsCore.normalizeNewTabUrl(input.getText().toString());
                    if (n == null) {
                        Toast.makeText(this, "无效的网址（只支持 http / https）", Toast.LENGTH_LONG).show();
                        return;
                    }
                    String v = n.equals(TabsCore.DEFAULT_NEW_TAB_URL) ? "" : n;
                    BrowserPrefs.setNewTabUrl(this, v);
                    label.setText("新标签页地址：" + (v.isEmpty() ? "MioCore 导航（默认）" : v));
                })
                .setNeutralButton("恢复默认", (d, w) -> {
                    BrowserPrefs.setNewTabUrl(this, "");
                    label.setText("新标签页地址：MioCore 导航（默认）");
                })
                .setNegativeButton("取消", null)
                .show();
    }
}
