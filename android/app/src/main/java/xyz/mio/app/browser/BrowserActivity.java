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
        /** 媒体（SponsorBlock / MediaSession / 后台播放通知，MioMedia.java） */
        MioMedia media;
        /** 阅读模式 / 强制深色 / 存到 Mio（PageTools.java）；阅读按钮只交给当前标签，后台标签用自己的占位 View */
        PageTools pageTools;
        View readerDummy;
        /** 翻译 / WebRTC 控制 / 用户脚本：每个标签的 WebView 各自安装 */
        TranslateBridge translate;
        final WebRtcGuard rtc = new WebRtcGuard();
        UserScripts userScripts;
        /** 这个标签 WebView 实际用的容器（系统不支持多 Profile 时 = default） */
        String containerId = TabsCore.DEFAULT_CONTAINER;
        int progress = 100;
        /** 请求桌面网站（页面菜单） */
        boolean desktop;
        String mobileUa;
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
    private MioMedia media;
    private PageTools pageTools;
    private Button readerBtn;
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
    /** 当前标签的翻译 / 用户脚本（工具栏、设置按「当前页」操作的代码用；每个标签各自一份，见 Tab） */
    private TranslateBridge translate;
    private UserScripts userScripts;
    /** 容器（登录状态隔离，xyz.mio.app.containers.ContainerManager）：删除容器时关掉它的标签、改名换色时刷新 */
    private xyz.mio.app.containers.ContainerManager.Listener containerListener;

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
        // 容器模块接入（TabContainers → ContainerManager）：容器列表、Profile 绑定、新标签选容器、标签映射
        TabContainers.useContainerManager(this);
        tabs.restore(readSession(), TabContainers.knownIds());
        TabContainers.retainTabs(tabs.tabs());
        containerListener = new xyz.mio.app.containers.ContainerManager.Listener() {
            @Override
            public void onContainerRemoved(String containerId, List<String> tabKeys) {
                closeContainerTabs(containerId);
            }

            @Override
            public void onContainersChanged() {
                if (overview != null && overview.getVisibility() == View.VISIBLE) renderOverview();
                updateButtons();
                updateContainerBadge();
                main.postDelayed(BrowserActivity.this::maybeShowContainerTip, 800);
            }
        };
        xyz.mio.app.containers.ContainerManager.get(this).addListener(containerListener);
        // 容器管理里的「打开」按钮：在该容器里开新标签
        xyz.mio.app.containers.ContainerUi.opener = id -> { hideOverview(); openTab(newTabUrl(), true, false, id); };

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
                if (in.getBooleanExtra("mioLayoutSmoke", false) && isDebuggable()) main.postDelayed(this::runLayoutSmoke, 8000);
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
        if (intent.getBooleanExtra("mioLayoutSmoke", false) && isDebuggable()) main.postDelayed(this::runLayoutSmoke, 8000);
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
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (userScripts != null) userScripts.onActivityResult(requestCode, resultCode, data, userScripts::showManager);
    }

    @Override
    protected void onDestroy() {
        worker.shutdownNow();
        main.removeCallbacks(saveRunnable);
        for (Tab t : new ArrayList<>(loaded.values())) destroyWebView(t);
        loaded.clear();
        if (containerListener != null) xyz.mio.app.containers.ContainerManager.get(this).removeListener(containerListener);
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

    /** 底部胶囊 / 收缩后的域名胶囊（Safari 紧凑布局，MobileChromeCore） */
    private LinearLayout capsule;
    private TextView pill;
    /** 地址栏左侧的容器色点 + 名称（默认容器不显示） */
    private TextView containerBadge;
    /** 标签概览的容器切换器：null = 全部 */
    private String overviewFilter;
    private final MobileChromeCore.Collapse collapse = new MobileChromeCore.Collapse(48);

    /**
     * Safari（iOS 27）紧凑布局：页面上方没有任何栏（只避开状态栏）；底部一条胶囊
     * [‹ 后退（长按历史）][☰ 页面菜单][地址栏：域名 + 进度 + ↻/✕][⧉ 标签（长按菜单）]。
     * 向下滚动收缩成底部小域名胶囊，向上滚动 / 到顶 / 到底 / 点胶囊恢复。原来底部 8 个按钮的功能都在页面菜单（BottomSheet）里。
     */
    @SuppressLint("ClickableViewAccessibility")
    private void buildUi() {
        boolean dark = (getResources().getConfiguration().uiMode & android.content.res.Configuration.UI_MODE_NIGHT_MASK) == android.content.res.Configuration.UI_MODE_NIGHT_YES;
        int fg = dark ? 0xFFEEEEEE : 0xFF111111;
        FrameLayout root = new FrameLayout(this);
        root.setBackgroundColor(dark ? 0xFF000000 : 0xFFF2F2F7);
        LinearLayout col = new LinearLayout(this);
        col.setOrientation(LinearLayout.VERTICAL);
        root.addView(col, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));

        // 每个标签的 WebView 都放在这里，只有当前标签可见
        webFrame = new FrameLayout(this);
        col.addView(webFrame, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1));

        backBtn = glyph("‹", "后退（长按：历史）", v -> { if (webView != null && webView.canGoBack()) webView.goBack(); });
        backBtn.setTextSize(TypedValue.COMPLEX_UNIT_SP, 26);
        backBtn.setTextColor(fg);
        backBtn.setOnLongClickListener(v -> { showHistory(); return true; });
        fwdBtn = glyph("›", "前进", v -> { if (webView != null && webView.canGoForward()) webView.goForward(); });
        Button menuBtn = glyph("☰", "页面菜单", v -> showPageMenu());
        menuBtn.setTextColor(fg);
        reloadBtn = glyph("↻", "刷新", v -> {
            if (webView == null) return;
            if (current != null && current.progress < 100) webView.stopLoading();
            else webView.reload();
        });
        reloadBtn.setTextSize(TypedValue.COMPLEX_UNIT_SP, 17);
        reloadBtn.setTextColor(fg);
        readerBtn = glyph("📖", "阅读模式", v -> { if (pageTools != null) pageTools.openReader(false); });
        readerBtn.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15);
        readerBtn.setVisibility(View.GONE);
        shield = new TextView(this);   // 状态在页面菜单「广告拦截」里显示；保留对象给 updateShield

        address = new EditText(this);
        address.setSingleLine(true);
        address.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15);
        address.setTypeface(Typeface.DEFAULT_BOLD);
        address.setTextColor(fg);
        address.setGravity(Gravity.CENTER);
        address.setBackground(null);
        address.setPadding(dp(4), 0, dp(4), 0);
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
        progress = new ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal);
        progress.setMax(100);

        tabsBtn = glyph("1", "标签页", v -> showOverview());
        tabsBtn.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
        tabsBtn.setTypeface(Typeface.DEFAULT_BOLD);
        tabsBtn.setTextColor(fg);
        GradientDrawable box = new GradientDrawable();
        box.setCornerRadius(dp(5));
        box.setStroke(dp(2), fg);
        tabsBtn.setBackground(new InsetDrawable(box, dp(12), dp(12), dp(12), dp(12)));
        tabsBtn.setOnLongClickListener(v -> { showTabsMenu(); return true; });

        // 地址栏：[阅读][域名 / 编辑框][刷新]，下沿是进度条
        FrameLayout addrBox = new FrameLayout(this);
        LinearLayout addrRow = new LinearLayout(this);
        addrRow.setGravity(Gravity.CENTER_VERTICAL);
        containerBadge = new TextView(this);
        containerBadge.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
        containerBadge.setTypeface(Typeface.DEFAULT_BOLD);
        containerBadge.setSingleLine(true);
        containerBadge.setMaxWidth(dp(90));
        containerBadge.setEllipsize(TextUtils.TruncateAt.END);
        containerBadge.setPadding(dp(8), 0, 0, 0);
        containerBadge.setVisibility(View.GONE);
        addrRow.addView(containerBadge, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        addrRow.addView(readerBtn, new LinearLayout.LayoutParams(dp(36), dp(40)));
        addrRow.addView(address, new LinearLayout.LayoutParams(0, dp(40), 1));
        addrRow.addView(reloadBtn, new LinearLayout.LayoutParams(dp(40), dp(40)));
        addrBox.addView(addrRow, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(44), Gravity.CENTER_VERTICAL));
        FrameLayout.LayoutParams pl = new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(3), Gravity.BOTTOM);
        pl.setMargins(dp(16), 0, dp(16), dp(2));
        addrBox.addView(progress, pl);

        capsule = new LinearLayout(this);
        capsule.setGravity(Gravity.CENTER_VERTICAL);
        capsule.setPadding(dp(4), 0, dp(4), 0);
        GradientDrawable glass = new GradientDrawable();
        glass.setCornerRadius(dp(26));
        glass.setColor(dark ? 0xE62C2C2E : 0xF2FFFFFF);
        glass.setStroke(1, dark ? 0x33FFFFFF : 0x22000000);
        capsule.setBackground(glass);
        capsule.setElevation(dp(6));
        capsule.addView(backBtn, new LinearLayout.LayoutParams(dp(44), dp(48)));
        capsule.addView(menuBtn, new LinearLayout.LayoutParams(dp(44), dp(48)));
        capsule.addView(addrBox, new LinearLayout.LayoutParams(0, dp(48), 1));
        capsule.addView(tabsBtn, new LinearLayout.LayoutParams(dp(48), dp(48)));
        LinearLayout.LayoutParams cl = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(52));
        cl.setMargins(dp(10), dp(6), dp(10), dp(6));
        col.addView(capsule, cl);
        // 地址栏手势：点 = 编辑完整网址；左右滑 = 切换标签；上滑 = 标签概览；长按 = 复制 / 粘贴并前往 / 分享
        android.view.GestureDetector gd = new android.view.GestureDetector(this, new android.view.GestureDetector.SimpleOnGestureListener() {
            @Override public boolean onDown(android.view.MotionEvent e) { return true; }
            @Override public boolean onSingleTapUp(android.view.MotionEvent e) {
                address.requestFocus();
                InputMethodManager imm = (InputMethodManager) getSystemService(INPUT_METHOD_SERVICE);
                if (imm != null) imm.showSoftInput(address, InputMethodManager.SHOW_IMPLICIT);
                return true;
            }
            @Override public void onLongPress(android.view.MotionEvent e) { showAddressMenu(); }
            @Override public boolean onFling(android.view.MotionEvent a, android.view.MotionEvent b, float vx, float vy) {
                if (a == null) return false;
                float d = getResources().getDisplayMetrics().density;
                int sw = MobileChromeCore.classifySwipe((b.getX() - a.getX()) / d, (b.getY() - a.getY()) / d, vx / d, vy / d);
                if (sw == MobileChromeCore.SWIPE_OVERVIEW) { showOverview(); return true; }
                if (sw == MobileChromeCore.SWIPE_NEXT || sw == MobileChromeCore.SWIPE_PREV) { switchTab(sw == MobileChromeCore.SWIPE_NEXT); return true; }
                return false;
            }
        });
        address.setOnTouchListener((v, ev) -> !address.hasFocus() && gd.onTouchEvent(ev));
        address.setOnFocusChangeListener((v, has) -> {
            backBtn.setVisibility(has ? View.GONE : View.VISIBLE);
            menuBtn.setVisibility(has ? View.GONE : View.VISIBLE);
            tabsBtn.setVisibility(has ? View.GONE : View.VISIBLE);
            reloadBtn.setVisibility(has ? View.GONE : View.VISIBLE);
            address.setGravity(has ? Gravity.START | Gravity.CENTER_VERTICAL : Gravity.CENTER);
            if (has) address.setText(webView != null && webView.getUrl() != null ? webView.getUrl() : "");
            else updateAddress();
        });

        pill = new TextView(this);
        pill.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13);
        pill.setTypeface(Typeface.DEFAULT_BOLD);
        pill.setTextColor(fg);
        pill.setGravity(Gravity.CENTER);
        pill.setPadding(dp(16), 0, dp(16), 0);
        pill.setSingleLine(true);
        GradientDrawable pg = new GradientDrawable();
        pg.setCornerRadius(dp(14));
        pg.setColor(dark ? 0xE62C2C2E : 0xF2FFFFFF);
        pill.setBackground(pg);
        pill.setContentDescription("显示地址栏");
        pill.setOnClickListener(v -> setCollapsed(false));
        pill.setVisibility(View.GONE);
        LinearLayout.LayoutParams pll = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, dp(28));
        pll.gravity = Gravity.CENTER_HORIZONTAL;
        pll.setMargins(0, dp(3), 0, dp(3));
        col.addView(pill, pll);

        overview = new FrameLayout(this);
        overview.setVisibility(View.GONE);
        root.addView(overview, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));

        fullscreen = new FrameLayout(this);
        fullscreen.setBackgroundColor(Color.BLACK);
        fullscreen.setVisibility(View.GONE);
        root.addView(fullscreen, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));

        // Android 15 起强制 edge-to-edge：内容避开状态栏 / 导航栏 / 键盘（页面上方没有栏，只让出状态栏）
        ViewCompat.setOnApplyWindowInsetsListener(col, (v, insets) -> {
            Insets bars = insets.getInsets(WindowInsetsCompat.Type.systemBars() | WindowInsetsCompat.Type.displayCutout() | WindowInsetsCompat.Type.ime());
            v.setPadding(bars.left, bars.top, bars.right, bars.bottom);
            overview.setPadding(bars.left, bars.top, bars.right, bars.bottom);
            return WindowInsetsCompat.CONSUMED;
        });
        setContentView(root);
        updateButtons();
    }

    /** 滚动收缩（每个标签的 WebView 滚动时调用） */
    private void onWebScroll(Tab t, int y, int oldY) {
        if (t != current || t.webView == null || address.hasFocus()) return;
        WebView wv = t.webView;
        int contentPx = (int) (wv.getContentHeight() * getResources().getDisplayMetrics().density);
        int a = collapse.scrolled(y, oldY, contentPx - wv.getHeight());
        if (a == MobileChromeCore.HIDE) applyCollapsed(true);
        else if (a == MobileChromeCore.SHOW) applyCollapsed(false);
    }

    private void setCollapsed(boolean hide) {
        int a = hide ? collapse.forceHide() : collapse.forceShow();
        if (a != MobileChromeCore.NONE) applyCollapsed(hide);
    }

    private void applyCollapsed(boolean hide) {
        if (capsule == null) return;
        if (hide && address.hasFocus()) { hideKeyboard(); address.clearFocus(); }
        capsule.setVisibility(hide ? View.GONE : View.VISIBLE);
        pill.setVisibility(hide ? View.VISIBLE : View.GONE);
    }

    /** 左右滑地址栏：下一个（最后一个再往左 = 新标签，Safari）/ 上一个 */
    private void switchTab(boolean next) {
        List<TabsCore.Tab> list = tabs.tabs();
        Long active = tabs.activeId();
        int i = -1;
        for (int k = 0; k < list.size(); k++) if (active != null && list.get(k).id == active) i = k;
        if (next) {
            if (i >= 0 && i + 1 < list.size()) selectTab(list.get(i + 1).id);
            else openTab(newTabUrl(), true, false, null);
        } else if (i > 0) {
            selectTab(list.get(i - 1).id);
        }
    }

    private void showHistory() {
        if (webView == null) return;
        android.webkit.WebBackForwardList h = webView.copyBackForwardList();
        int cur = h.getCurrentIndex();
        if (cur <= 0) return;
        List<String> items = new ArrayList<>();
        List<Integer> steps = new ArrayList<>();
        for (int i = cur - 1; i >= 0 && items.size() < 20; i--) {
            android.webkit.WebHistoryItem it = h.getItemAtIndex(i);
            String title = it.getTitle();
            items.add((title == null || title.isEmpty() ? "" : title + "\n") + MobileChromeCore.displayHost(it.getUrl()));
            steps.add(i - cur);
        }
        new AlertDialog.Builder(this).setTitle("历史记录")
                .setItems(items.toArray(new String[0]), (d, w) -> { if (webView != null) webView.goBackOrForward(steps.get(w)); })
                .show();
    }

    private void showAddressMenu() {
        List<String> items = new ArrayList<>();
        List<Runnable> actions = new ArrayList<>();
        String u = curUrl();
        ClipboardManager cm = (ClipboardManager) getSystemService(CLIPBOARD_SERVICE);
        if (u != null) {
            items.add("复制链接");
            actions.add(() -> { if (cm != null) cm.setPrimaryClip(ClipData.newPlainText("url", u)); });
        }
        if (cm != null && cm.hasPrimaryClip()) {
            items.add("粘贴并前往");
            actions.add(() -> {
                ClipData c = cm.getPrimaryClip();
                CharSequence t = c != null && c.getItemCount() > 0 ? c.getItemAt(0).coerceToText(this) : null;
                String target = t != null ? urlFromInput(t.toString()) : null;
                if (target != null) load(target);
            });
        }
        if (u != null) { items.add("分享"); actions.add(this::share); }
        if (items.isEmpty()) return;
        new AlertDialog.Builder(this).setItems(items.toArray(new String[0]), (d, w) -> actions.get(w).run()).show();
    }

    /** 页面菜单：底部弹出的紧凑面板（BottomSheet 样式），条目见 MobileChromeCore.menuSections */
    private android.app.Dialog pageMenu;

    private void showPageMenu() {
        String url = curUrl();
        boolean web = url != null && url.startsWith("http");
        String host = web ? hostOf(url) : null;
        boolean dark = (getResources().getConfiguration().uiMode & android.content.res.Configuration.UI_MODE_NIGHT_MASK) == android.content.res.Configuration.UI_MODE_NIGHT_YES;
        int fg = dark ? 0xFFEEEEEE : 0xFF111111;
        android.app.Dialog d = new android.app.Dialog(this);
        d.requestWindowFeature(android.view.Window.FEATURE_NO_TITLE);
        ScrollView scroll = new ScrollView(this);
        LinearLayout list = new LinearLayout(this);
        list.setOrientation(LinearLayout.VERTICAL);
        list.setPadding(dp(8), dp(6), dp(8), dp(16));
        GradientDrawable bg = new GradientDrawable();
        bg.setColor(dark ? 0xFF1C1C1E : 0xFFF2F2F7);
        bg.setCornerRadii(new float[]{dp(18), dp(18), dp(18), dp(18), 0, 0, 0, 0});
        scroll.setBackground(bg);
        View grab = new View(this);
        GradientDrawable gb = new GradientDrawable();
        gb.setColor(0x55888888);
        gb.setCornerRadius(dp(3));
        grab.setBackground(gb);
        LinearLayout.LayoutParams gl = new LinearLayout.LayoutParams(dp(36), dp(5));
        gl.gravity = Gravity.CENTER_HORIZONTAL;
        gl.setMargins(0, dp(2), 0, dp(6));
        list.addView(grab, gl);
        for (MobileChromeCore.Section sec : MobileChromeCore.menuSections(web, host, BrowserPrefs.adblockEnabled(this), WebRtcGuard.enabled(this), TabContainers.supported())) {
            TextView h = new TextView(this);
            h.setText(sec.title);
            h.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
            h.setTextColor(0xFF888888);
            h.setPadding(dp(12), dp(10), dp(12), dp(2));
            list.addView(h);
            for (String id : sec.items) {
                Boolean state = menuState(id, host);
                TextView row = new TextView(this);
                String sub = id.equals("forward") && (webView == null || !webView.canGoForward()) ? null : "";
                row.setText(MobileChromeCore.title(id, current != null && current.desktop) + (state == null ? "" : (state ? "　✓ 开" : "　关")));
                row.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16);
                row.setTextColor(sub == null ? 0xFF999999 : fg);
                row.setPadding(dp(14), dp(11), dp(14), dp(11));
                row.setBackgroundResource(android.R.drawable.list_selector_background);
                row.setContentDescription(row.getText());
                row.setOnClickListener(v -> { d.dismiss(); runMenuItem(id, host); });
                list.addView(row);
            }
            if (sec.items.contains("userScripts") && userScripts != null && webView != null) {
                // 本页用户脚本的菜单命令（GM_registerMenuCommand）
                List<String> items = new ArrayList<>();
                List<Runnable> actions = new ArrayList<>();
                userScripts.addMenuItems(webView.getUrl(), items, actions);
                for (int i = 0; i < items.size() - 1; i++) {
                    final Runnable r = actions.get(i);
                    TextView row = new TextView(this);
                    row.setText(items.get(i));
                    row.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15);
                    row.setTextColor(fg);
                    row.setPadding(dp(14), dp(10), dp(14), dp(10));
                    row.setOnClickListener(v -> { d.dismiss(); r.run(); });
                    list.addView(row);
                }
            }
        }
        scroll.addView(list);
        d.setContentView(scroll);
        android.view.Window w = d.getWindow();
        if (w != null) {
            w.setBackgroundDrawable(new android.graphics.drawable.ColorDrawable(Color.TRANSPARENT));
            w.setGravity(Gravity.BOTTOM);
            w.setLayout(ViewGroup.LayoutParams.MATCH_PARENT, (int) (getResources().getDisplayMetrics().heightPixels * 0.62f));
        }
        pageMenu = d;
        d.show();
    }

    /** 开关类条目的当前状态（null = 普通条目） */
    private Boolean menuState(String id, String host) {
        switch (id) {
            case "adblock": return BrowserPrefs.adblockEnabled(this);
            case "adblockSite": return BrowserPrefs.allowlistEntry(this, host) == null;
            case "webrtcSite": return WebRtcGuard.isAllowed(this, host);
            case "youtubeFocus": return YouTubeFocus.enabled(this);
            default: return null;
        }
    }

    private void runMenuItem(String id, String host) {
        switch (id) {
            case "forward": if (webView != null && webView.canGoForward()) webView.goForward(); break;
            case "share": share(); break;
            case "findInPage": showFind(); break;
            case "requestDesktop": toggleDesktop(); break;
            case "openExternal": openExternal(curUrl()); break;
            case "translateBilingual": if (translate != null) translate.showMenu(); break;
            case "translateSettings": if (translate != null) translate.showSettings(); break;
            case "reader": if (pageTools != null) pageTools.openReader(true); break;
            case "darkSite": if (pageTools != null) pageTools.showMenu(); break;
            case "saveBookmark": if (pageTools != null) pageTools.save("bookmark", null); break;
            case "saveNote": if (pageTools != null) pageTools.save("note", null); break;
            case "saveClip": if (pageTools != null) pageTools.save("clip", null); break;
            case "adblock": BrowserPrefs.setAdblockEnabled(this, !BrowserPrefs.adblockEnabled(this)); afterSettingChange(true); break;
            case "adblockSite":
                if (host != null) { BrowserPrefs.setAllowlisted(this, host, BrowserPrefs.allowlistEntry(this, host) == null); afterSettingChange(true); }
                break;
            case "webrtcSite":
                if (host != null) { WebRtcGuard.setAllowed(this, host, !WebRtcGuard.isAllowed(this, host)); reinstallRtc(); if (webView != null) webView.reload(); }
                break;
            case "userScripts": if (userScripts != null) userScripts.showManager(); break;
            case "youtubeFocus":
                BrowserPrefs.putBoolean(this, "youtubeFocus", !YouTubeFocus.enabled(this));
                for (Tab t : loaded.values()) {
                    t.ytFocus.install();
                    if (YouTubeFocus.isYouTubeUrl(t.webView.getUrl())) t.webView.reload();
                }
                break;
            case "adblockSettings":
            case "settings": showSettings(false); break;
            case "backToMio": hideBrowser(); break;
            case "openInContainer": {
                String u = curUrl();
                if (u == null) break;
                pickContainer("在容器中打开此页", current != null ? current.containerId : null, false, cid -> openTab(u, true, false, cid));
                break;
            }
            case "siteContainer": {
                if (host == null) break;
                xyz.mio.app.containers.ContainerManager cm = xyz.mio.app.containers.ContainerManager.get(this);
                String ruleHost = null;
                String cur = null;
                for (xyz.mio.app.containers.ContainerState.SiteRule r : cm.state().siteRules()) {
                    if (host.equals(r.host) || host.endsWith("." + r.host)) { ruleHost = r.host; cur = r.containerId; }
                }
                final String existing = ruleHost;
                pickContainer("此网站始终用这个容器打开（" + (existing != null ? existing : host) + "，含子域名）", cur, true, cid -> {
                    try {
                        if (cid != null) cm.setSiteRule(host, cid);
                        else if (existing != null) cm.removeSiteRule(existing);
                    } catch (Exception e) {
                        Toast.makeText(this, e.getMessage(), Toast.LENGTH_LONG).show();
                    }
                });
                break;
            }
            default: break;
        }
    }

    private void showFind() {
        if (webView == null) return;
        final WebView wv = webView;
        EditText input = new EditText(this);
        input.setSingleLine(true);
        input.setHint("查找");
        AlertDialog d = new AlertDialog.Builder(this)
                .setTitle("查找页面内容")
                .setView(input)
                .setPositiveButton("下一个", null)
                .setNeutralButton("上一个", null)
                .setNegativeButton("完成", (x, w) -> wv.clearMatches())
                .create();
        d.setOnShowListener(x -> {
            d.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener(v -> {
                if (input.getTag() == null || !input.getTag().equals(input.getText().toString())) {
                    input.setTag(input.getText().toString());
                    wv.findAllAsync(input.getText().toString());
                } else {
                    wv.findNext(true);
                }
            });
            d.getButton(AlertDialog.BUTTON_NEUTRAL).setOnClickListener(v -> wv.findNext(false));
        });
        d.show();
    }

    private void toggleDesktop() {
        if (current == null || current.webView == null) return;
        Tab t = current;
        t.desktop = !t.desktop;
        WebSettings s = t.webView.getSettings();
        if (t.mobileUa == null) t.mobileUa = s.getUserAgentString();
        s.setUserAgentString(t.desktop ? MobileChromeCore.desktopUserAgent(t.mobileUa) : t.mobileUa);
        t.webView.reload();
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
        String shown = MobileChromeCore.displayHost(u);
        address.setText(shown.isEmpty() ? (title != null ? title : "") : shown);
        if (pill != null) pill.setText(shown);
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
        // 锁定的打开者 > 显式指定 > 站点默认容器 > 未锁定的打开者 > 默认容器（ContainerManager.containerForNewTab）
        TabsCore.Tab opener = fromCurrent && current != null ? tabs.get(current.id) : null;
        String[] c = TabContainers.forNewTab(TabsCore.isHttp(url) ? url : null, opener, containerId);
        TabsCore.Tab rec = tabs.add(target, TabsCore.Opts.make().activate(activate).fromActive(fromCurrent).container(c[0]).locked("1".equals(c[1])));
        if (rec == null) {
            Toast.makeText(this, "最多同时打开 " + tabs.maxTabs + " 个标签", Toast.LENGTH_SHORT).show();
            return null;
        }
        TabContainers.mirror(rec);
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
        if (current != null && current != t && current.webView != null) {
            captureThumb(current);
            if (current.pageTools != null) current.pageTools.setReaderButton(current.readerDummy);
        }
        boolean switched = current != t;
        current = t;
        webView = t.webView;
        ytFocus = t.ytFocus;
        media = t.media;
        pageTools = t.pageTools;
        translate = t.translate;
        userScripts = t.userScripts;
        if (switched && t.pageTools != null) {
            t.pageTools.setReaderButton(readerBtn);
            t.pageTools.onUrlChanged();
        }
        for (Tab x : loaded.values()) x.webView.setVisibility(x == t ? View.VISIBLE : View.INVISIBLE);
        t.webView.bringToFront();
        if (switched) setCollapsed(false);
        updateContainerBadge();
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
        if (current == t) { current = null; webView = null; ytFocus = null; media = null; pageTools = null; translate = null; userScripts = null; readerBtn.setVisibility(View.GONE); }
        if (tabs.close(id) == null) return;
        TabContainers.removeTab(id);
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
        TabContainers.mirror(rec);
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
        if (t.media != null) {
            try { t.media.destroy(); } catch (Exception ignored) {}
        }
        if (t.translate != null) {
            try { t.translate.shutdown(); } catch (Exception ignored) {}
        }
        if (t.userScripts != null) {
            try { t.userScripts.shutdown(); } catch (Exception ignored) {}
        }
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

    /** WebRTC 设置变了：每个已加载标签重新注册脚本（下一次加载生效） */
    private void reinstallRtc() {
        for (Tab x : loaded.values()) x.rtc.install(this, x.webView);
    }

    /** 删除容器：关掉它的所有标签（数据随后被删除，所以也从「最近关闭」里去掉） */
    private void closeContainerTabs(String containerId) {
        if (containerId == null || TabsCore.DEFAULT_CONTAINER.equals(containerId)) return;
        List<Long> ids = new ArrayList<>();
        for (TabsCore.Tab r : tabs.tabs()) if (containerId.equals(r.containerId)) ids.add(r.id);
        for (Long id : ids) {
            if (!tabs.isEmpty()) closeTab(id);
        }
        tabs.removeContainer(containerId);
        saveNow();
    }

    /** 概览里长按标签卡片：在容器中重新打开 / 锁定容器 / 关闭 */
    private void showTabCardMenu(long id) {
        TabsCore.Tab rec = tabs.get(id);
        if (rec == null) return;
        List<String> items = new ArrayList<>();
        List<Runnable> actions = new ArrayList<>();
        if (TabContainers.list(this).size() > 1 && TabContainers.supported()) {
            if (!rec.locked) {
                items.add("在容器中重新打开…");
                actions.add(() -> pickContainer(cid -> { if (!cid.equals(rec.containerId)) { hideOverview(); openTab(rec.url, true, false, cid); } }));
            }
            items.add(rec.locked ? "解除容器锁定" : "锁定在此容器");
            actions.add(() -> setTabLocked(rec.id, !rec.locked));
        }
        items.add("关闭标签页");
        actions.add(() -> { closeTab(rec.id); if (!isFinishing()) renderOverview(); });
        TabContainers.Info ci = TabContainers.find(this, rec.containerId);
        new AlertDialog.Builder(this)
                .setTitle(ci != null && !TabsCore.DEFAULT_CONTAINER.equals(ci.id) ? "容器：" + ci.name : TabsCore.displayHost(rec.url))
                .setItems(items.toArray(new String[0]), (d, which) -> actions.get(which).run())
                .show();
    }

    /** 锁定 / 解锁当前标签的容器 */
    private void setTabLocked(long id, boolean locked) {
        if (!tabs.setLocked(id, locked)) return;
        TabsCore.Tab r = tabs.get(id);
        if (r != null) TabContainers.mirror(r);
        scheduleSave();
        if (overview.getVisibility() == View.VISIBLE) renderOverview();
    }

    private void showTabsMenu() {
        List<String> items = new ArrayList<>();
        List<Runnable> actions = new ArrayList<>();
        // 新建标签页 / 新建无痕 / 在容器中新建 / 新建容器（与 iOS 同样的入口）
        addNewTabItems(items, actions);
        List<TabContainers.Info> containers = TabContainers.list(this);
        if (tabs.hasClosed()) {
            items.add("重新打开关闭的标签页");
            actions.add(this::reopenClosedTab);
        }
        TabsCore.Tab cur = current != null ? tabs.get(current.id) : null;
        if (cur != null && containers.size() > 1 && TabContainers.supported()) {
            if (!cur.locked) {
                items.add("在容器中重新打开…");
                actions.add(() -> pickContainer(id -> { if (!id.equals(cur.containerId)) openTab(cur.url, true, false, id); }));
            }
            items.add(cur.locked ? "解除容器锁定" : "锁定在此容器");
            actions.add(() -> setTabLocked(cur.id, !cur.locked));
        }
        items.add("关闭此标签页");
        actions.add(() -> { if (current != null) closeTab(current.id); });
        items.add("回到 Mio 导航（标签保留）");
        actions.add(this::hideBrowser);
        new AlertDialog.Builder(this)
                .setItems(items.toArray(new String[0]), (d, which) -> actions.get(which).run())
                .show();
    }

    interface ContainerPick { void pick(String id); }

    private void pickContainer(ContainerPick cb) { pickContainer("选择容器", null, false, cb); }

    /** 选容器（带色点；可新建；includeNone = 「不指定」→ cb.pick(null)） */
    private void pickContainer(String title, String current, boolean includeNone, ContainerPick cb) {
        if (!TabContainers.supported()) { containersUnsupported(); return; }
        List<TabContainers.Info> list = TabContainers.list(this);
        List<CharSequence> names = new ArrayList<>();
        List<String> ids = new ArrayList<>();
        if (includeNone) { names.add("不指定（跟随打开方式）" + (current == null ? "  ✓" : "")); ids.add(null); }
        for (TabContainers.Info i : list) {
            android.text.SpannableString sp = new android.text.SpannableString("●  " + i.name + (i.id.equals(current) ? "  ✓" : ""));
            sp.setSpan(new android.text.style.ForegroundColorSpan(i.color), 0, 1, 0);
            names.add(sp);
            ids.add(i.id);
        }
        names.add("＋ 新建容器…");
        ids.add("\u0000new");
        new AlertDialog.Builder(this)
                .setTitle(title)
                .setItems(names.toArray(new CharSequence[0]), (d, which) -> {
                    String id = ids.get(which);
                    if ("\u0000new".equals(id)) createContainer(cb);
                    else cb.pick(id);
                })
                .setNegativeButton("取消", null)
                .show();
    }

    private void containersUnsupported() {
        new AlertDialog.Builder(this)
                .setTitle("容器不可用")
                .setMessage("当前系统的 Android System WebView 版本过旧，不支持多配置文件（MULTI_PROFILE），只能使用默认容器。请在 Google Play 更新「Android System WebView」或 Chrome 后重试。")
                .setPositiveButton("好", null)
                .show();
    }

    /** 新建容器 → 回调新容器 id；第一次创建后出现一次性引导 */
    private void createContainer(ContainerPick then) {
        if (!TabContainers.supported()) { containersUnsupported(); return; }
        EditText input = new EditText(this);
        input.setSingleLine(true);
        input.setHint("名称，例如 工作、小号");
        new AlertDialog.Builder(this)
                .setTitle("新建容器")
                .setMessage("容器里的登录状态、Cookie 和网站数据与其他容器互不相通")
                .setView(input)
                .setNegativeButton("取消", null)
                .setPositiveButton("创建", (d, w) -> {
                    try {
                        xyz.mio.app.containers.ContainerManager cm = xyz.mio.app.containers.ContainerManager.get(this);
                        String n = input.getText().toString().trim();
                        xyz.mio.app.containers.ContainerState.Container c = cm.create(n.isEmpty() ? "容器 " + cm.list().size() : n, null);
                        if (then != null) then.pick(c.id);
                        main.postDelayed(this::maybeShowContainerTip, 800);
                    } catch (Exception e) {
                        Toast.makeText(this, "无法创建容器：" + e.getMessage(), Toast.LENGTH_LONG).show();
                    }
                })
                .show();
    }

    /** 新建标签菜单条目（标签按钮长按 / 概览「+」长按） */
    private void addNewTabItems(List<String> items, List<Runnable> actions) {
        items.add("新建标签页");
        actions.add(() -> openTab(newTabUrl(), true, false, null));
        items.add("新建无痕标签页");
        actions.add(() -> Toast.makeText(this, "Android 版暂不支持无痕标签：系统 WebView 不能为单个标签关闭存储（可新建一个容器代替）", Toast.LENGTH_LONG).show());
        items.add("在容器中新建…");
        actions.add(() -> pickContainer(id -> { hideOverview(); openTab(newTabUrl(), true, false, id); }));
        items.add("新建容器…");
        actions.add(() -> createContainer(id -> { hideOverview(); openTab(newTabUrl(), true, false, id); }));
    }

    private void showNewTabMenu() {
        List<String> items = new ArrayList<>();
        List<Runnable> actions = new ArrayList<>();
        addNewTabItems(items, actions);
        new AlertDialog.Builder(this).setItems(items.toArray(new String[0]), (d, w) -> actions.get(w).run()).show();
    }

    /** 第一次有了非默认容器：一次性说明三种用法 */
    private void maybeShowContainerTip() {
        if (isFinishing() || BrowserPrefs.getBoolean(this, "containers.tipShown", false)) return;
        if (!TabContainers.supported() || TabContainers.list(this).size() < 2) return;
        BrowserPrefs.putBoolean(this, "containers.tipShown", true);
        new AlertDialog.Builder(this)
                .setTitle("容器已创建，这样使用")
                .setMessage("① 长按标签按钮或概览里的「＋」→ 在容器中新建\n② 页面菜单 → 在容器中打开此页 / 此网站始终用某容器打开\n③ 标签概览底部切换容器，只看该容器的标签，「＋」直接在该容器里新建\n容器标签在地址栏左侧显示色点和名称。")
                .setPositiveButton("知道了", null)
                .show();
    }

    private void updateContainerBadge() {
        if (containerBadge == null) return;
        TabContainers.Info ci = current == null || TabsCore.DEFAULT_CONTAINER.equals(current.containerId) ? null : TabContainers.find(this, current.containerId);
        if (ci == null) { containerBadge.setVisibility(View.GONE); return; }
        containerBadge.setText("● " + ci.name);
        containerBadge.setTextColor(ci.color);
        containerBadge.setContentDescription("容器：" + ci.name);
        containerBadge.setVisibility(View.VISIBLE);
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
        count.setText(overviewFilter == null ? tabs.size() + " 个标签页" : overviewTabs().size() + " / " + tabs.size() + " 个标签页");
        count.setTextColor(fg);
        count.setGravity(Gravity.CENTER);
        count.setTypeface(Typeface.DEFAULT_BOLD);
        bar.addView(count, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1));
        final String filterNow = overviewFilter;
        Button add = glyph("＋", "新建标签页", v -> { hideOverview(); openTab(newTabUrl(), true, false, filterNow); });
        add.setOnLongClickListener(v -> { showNewTabMenu(); return true; });
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
        List<TabsCore.Tab> list = overviewTabs();
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
            // 容器色条在卡片顶部
            TabContainers.Info ci = "default".equals(rec.containerId) ? null : TabContainers.find(this, rec.containerId);
            if (ci != null) {
                View stripe = new View(this);
                stripe.setBackgroundColor(ci.color);
                c.addView(stripe, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(5)));
            }
            c.addView(thumbBox, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(150)));
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
            h.setText(ci != null ? "● " + ci.name + " · " + host : host);
            if (ci != null) h.setTextColor(ci.color);
            h.setSingleLine(true);
            h.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
            if (ci == null) h.setTextColor(0xFF888888);
            h.setPadding(dp(2), 0, dp(2), 0);
            c.addView(h);
            c.setContentDescription(title.getText() + "，" + host + (isActive ? "，当前标签" : ""));
            c.setOnClickListener(v -> { hideOverview(); selectTab(rec.id); });
            c.setOnLongClickListener(v -> { showTabCardMenu(rec.id); return true; });
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1);
            lp.setMargins(dp(6), dp(6), dp(6), dp(6));
            row.addView(c, lp);
        }
        if (row != null) {
            for (int k = list.size() % columns; k != 0 && k < columns; k++) {
                row.addView(new View(this), new LinearLayout.LayoutParams(0, 1, 1));
            }
        }
        // 底部容器切换器（Safari 描述文件 / 标签组式）：全部 / 默认 / 各容器；选中后只显示该容器的标签，「＋」在该容器里新建
        List<TabContainers.Info> containers = TabContainers.list(this);
        if (containers.size() > 1) {
            android.widget.HorizontalScrollView hs = new android.widget.HorizontalScrollView(this);
            hs.setHorizontalScrollBarEnabled(false);
            LinearLayout chips = new LinearLayout(this);
            chips.setPadding(dp(8), dp(6), dp(8), dp(6));
            hs.addView(chips);
            chips.addView(filterChip("全部", 0xFF888888, null, dark, fg));
            for (TabContainers.Info ci : containers) chips.addView(filterChip(ci.name, ci.color, ci.id, dark, fg));
            TextView manage = filterChip("管理…", 0xFF888888, "\u0000manage", dark, fg);
            chips.addView(manage);
            col.addView(hs, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        }
    }

    private List<TabsCore.Tab> overviewTabs() {
        List<TabsCore.Tab> all = tabs.tabs();
        if (overviewFilter == null) return all;
        List<TabsCore.Tab> out = new ArrayList<>();
        for (TabsCore.Tab t : all) if (overviewFilter.equals(t.containerId)) out.add(t);
        return out;
    }

    private TextView filterChip(String name, int color, String id, boolean dark, int fg) {
        TextView t = new TextView(this);
        boolean selected = id == null ? overviewFilter == null : id.equals(overviewFilter);
        android.text.SpannableString sp = new android.text.SpannableString((id == null || id.startsWith("\u0000") ? "" : "● ") + name);
        if (id != null && !id.startsWith("\u0000")) sp.setSpan(new android.text.style.ForegroundColorSpan(color), 0, 1, 0);
        t.setText(sp);
        t.setTextColor(fg);
        t.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14);
        t.setPadding(dp(14), dp(8), dp(14), dp(8));
        GradientDrawable g = new GradientDrawable();
        g.setCornerRadius(dp(18));
        g.setColor(selected ? (dark ? 0xFF3A3A3C : 0xFFFFFFFF) : 0x00000000);
        g.setStroke(dp(1), selected ? color : 0x33888888);
        t.setBackground(g);
        t.setContentDescription((selected ? "已选：" : "") + "容器 " + name);
        t.setOnClickListener(v -> {
            if ("\u0000manage".equals(id)) {
                xyz.mio.app.containers.ContainerUi.show(this, this::renderOverview);
                return;
            }
            overviewFilter = id;
            renderOverview();
        });
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        lp.setMarginEnd(dp(6));
        t.setLayoutParams(lp);
        return t;
    }

    // ---------------------------------------------------------------- WebView（per-tab setup）

    /** 一个标签的 WebView 和它的全部按 WebView 注册的功能。新的按 WebView 功能挂在这里，每个标签各自安装 */
    @SuppressLint({"SetJavaScriptEnabled", "AddJavascriptInterface"})
    private void createWebView(Tab t) {
        WebView wv = new WebView(this);
        t.webView = wv;
        TabsCore.Tab rec = tabs.get(t.id);
        // 容器（登录隔离）：ContainerManager.apply 绑定容器的 Profile，必须紧跟 new WebView、任何 getSettings / loadUrl 之前
        t.containerId = TabContainers.bind(wv, rec != null ? rec.containerId : TabsCore.DEFAULT_CONTAINER);
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
        CookieManager cookies = xyz.mio.app.containers.ContainerManager.get(this).cookieManager(t.containerId);
        cookies.setAcceptCookie(true);
        cookies.setAcceptThirdPartyCookies(wv, true);
        wv.addJavascriptInterface(new Bridge(t), "MioAdblockBridge");
        // YouTube 防沉迷：先于通用脚本注册（通用脚本之后每次都会重新注册到最后）
        t.ytFocus = new YouTubeFocus(this, wv);
        t.ytFocus.install();
        // 媒体：YouTube 脚本（SponsorBlock / MediaSession）、后台播放通知、Widevine 权限（MioMedia.java）
        t.media = new MioMedia(this, wv);
        t.media.install();
        t.pageTools = new PageTools(this, wv);
        t.readerDummy = new View(this);
        t.pageTools.setReaderButton(t.readerDummy);
        // 翻译（网页双语 / 划词 / YouTube 双语字幕）：document-start 脚本 + WebMessageListener 原生桥（TranslateBridge）
        t.translate = new TranslateBridge(this, wv);
        t.translate.install();
        // WebRTC 控制（与 iOS 同一段脚本）
        t.rtc.install(this, wv);
        // 用户脚本：GM_xmlhttpRequest 用这个标签容器的 CookieManager
        t.userScripts = new UserScripts(this, wv);
        t.userScripts.setCookieManager(() -> xyz.mio.app.containers.ContainerManager.get(this).cookieManager(t.containerId));
        t.userScripts.install();
        installGenericScript(t);

        wv.setOnLongClickListener(v -> onLongPress(t));
        wv.setOnScrollChangeListener((v, x, y, ox, oy) -> onWebScroll(t, y, oy));

        wv.setWebViewClient(new WebViewClient() {
            @Override
            public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                Uri uri = request.getUrl();
                String scheme = uri.getScheme() == null ? "" : uri.getScheme().toLowerCase(Locale.ROOT);
                if (scheme.equals("http") || scheme.equals("https")) {
                    if (request.isForMainFrame() && t.userScripts != null && t.userScripts.maybeOfferInstall(uri.toString())) return true;
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
                if (t == current) setCollapsed(false);
                if (t.userScripts != null) {
                    t.userScripts.onPageStarted();
                    if (t.userScripts.maybeOfferInstall(url)) view.stopLoading();
                }
                t.pageTools.onPageStarted(url);
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
                t.pageTools.onPageFinished();
                if (tabs.update(t.id, TabsCore.isHttp(url) ? url : null, view.getTitle())) scheduleSave();
                if (t == current) {
                    updateAddress();
                    updateButtons();
                }
            }

            @Override
            public void doUpdateVisitedHistory(WebView view, String url, boolean isReload) {
                t.topUrl = url;
                t.pageTools.onUrlChanged();
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
            public void onPermissionRequest(android.webkit.PermissionRequest request) {
                // 只放行 RESOURCE_PROTECTED_MEDIA_ID（Widevine，Spotify 等 DRM）；其它资源照旧拒绝
                MioMedia.onPermissionRequest(request);
            }

            @Override
            public boolean onCreateWindow(WebView view, boolean isDialog, boolean isUserGesture, Message resultMsg) {
                // 新窗口 = 新标签（继承容器 / 锁定，插在来源标签右边）；没有用户手势的弹窗不开
                if (!isUserGesture) return false;
                if (current != t) selectTab(t.id);
                // 弹窗必须和打开者同一个 Profile（WebViewTransport），所以总是继承打开者的容器（锁定也继承）
                TabsCore.Tab opener = tabs.get(t.id);
                TabsCore.Tab rec = tabs.add("", TabsCore.Opts.make().activate(true).fromActive(true)
                        .container(t.containerId).locked(opener != null && opener.locked));
                if (rec == null) {
                    Toast.makeText(BrowserActivity.this, "最多同时打开 " + tabs.maxTabs + " 个标签", Toast.LENGTH_SHORT).show();
                    return false;
                }
                TabContainers.mirror(rec);
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

    /** CI 模拟器：Safari 紧凑布局截图冒烟（adb am start … --ez mioLayoutSmoke true）。每步打 MioLayout step 日志，脚本据此截图 */
    private void runLayoutSmoke() {
        final JSONObject r = new JSONObject();
        try {
            setCollapsed(false);
            r.put("capsuleVisible", capsule.getVisibility() == View.VISIBLE && capsule.getHeight() > 0);
            int[] loc = new int[2];
            capsule.getLocationOnScreen(loc);
            int[] wl = new int[2];
            webFrame.getLocationOnScreen(wl);
            r.put("capsuleBelowWeb", loc[1] >= wl[1] + webFrame.getHeight() - 2);
            r.put("noTopBar", wl[1] <= dp(60));   // 页面紧贴状态栏下方，上面没有栏
            android.util.Log.i(TAG, "MioLayout step 1 expanded");
            main.postDelayed(() -> {
                setCollapsed(true);
                try {
                    r.put("collapsed", capsule.getVisibility() == View.GONE && pill.getVisibility() == View.VISIBLE);
                } catch (Exception ignored) {}
                android.util.Log.i(TAG, "MioLayout step 2 collapsed");
                main.postDelayed(() -> {
                    setCollapsed(false);
                    showPageMenu();
                    try { r.put("menuShown", pageMenu != null && pageMenu.isShowing()); } catch (Exception ignored) {}
                    android.util.Log.i(TAG, "MioLayout step 3 page-menu");
                    main.postDelayed(() -> {
                        if (pageMenu != null) pageMenu.dismiss();
                        showOverview();
                        android.util.Log.i(TAG, "MioLayout step 4 tab-overview");
                        main.postDelayed(() -> {
                            hideOverview();
                            // 容器：支持 MULTI_PROFILE → 建一个容器开标签，地址栏显示色点 + 名称；不支持 → 选择容器时弹降级提示
                            boolean sup = TabContainers.supported();
                            try { r.put("containersSupported", sup); } catch (Exception ignored) {}
                            if (sup) {
                                try {
                                    xyz.mio.app.containers.ContainerState.Container c = xyz.mio.app.containers.ContainerManager.get(this).create("冒烟", null);
                                    r.put("autoColor", c.color);
                                    openTab(newTabUrl(), true, false, c.id);
                                } catch (Exception e) { android.util.Log.e(TAG, "smoke container", e); }
                            } else {
                                pickContainer(id -> {});
                            }
                            main.postDelayed(() -> {
                                try { r.put("containerStep", sup ? (containerBadge.getVisibility() == View.VISIBLE && containerBadge.getText().toString().contains("冒烟")) : true); } catch (Exception ignored) {}
                                android.util.Log.i(TAG, "MioLayout step 5 " + (sup ? "container-badge" : "containers-unsupported"));
                                main.postDelayed(() -> {
                                    boolean ok = r.optBoolean("capsuleVisible") && r.optBoolean("capsuleBelowWeb") && r.optBoolean("noTopBar")
                                            && r.optBoolean("collapsed") && r.optBoolean("menuShown") && r.optBoolean("containerStep");
                                    try { r.put("ok", ok); } catch (Exception ignored) {}
                                    android.util.Log.i(TAG, "MioLayout result " + r);
                                }, 2500);
                            }, 3500);
                        }, 3000);
                    }, 3000);
                }, 3000);
            }, 3000);
        } catch (Exception e) {
            android.util.Log.e(TAG, "MioLayout result {\"ok\":false}", e);
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
        if (host != null && WebRtcGuard.enabled(this)) {
            boolean rtcAllowed = WebRtcGuard.isAllowed(this, host);
            items.add(rtcAllowed ? "此站点恢复屏蔽 WebRTC" : "此站点允许 WebRTC（网页通话）");
            actions.add(() -> { WebRtcGuard.setAllowed(this, host, !rtcAllowed); reinstallRtc(); if (webView != null) webView.reload(); });
        }
        if (userScripts != null && webView != null) userScripts.addMenuItems(webView.getUrl(), items, actions);
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

        if (current != null) current.rtc.addSettingsRows(this, box, host, webView);
        if (userScripts != null) userScripts.addSettingsRow(box);

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

        Button translateSettings = new Button(this);
        translateSettings.setText("翻译设置…（网页翻译 / 划词 / YouTube 双语字幕）");
        translateSettings.setOnClickListener(v -> { if (translate != null) translate.showSettings(); });
        box.addView(translateSettings);

        Button allow = new Button(this);
        allow.setText("白名单（" + BrowserPrefs.allowlist(this).size() + "）…");
        allow.setOnClickListener(v -> showAllowlist(allow));
        box.addView(allow);

        xyz.mio.app.containers.ContainerUi.addSettingsButton(this, box);

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
            reinstallRtc();
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
