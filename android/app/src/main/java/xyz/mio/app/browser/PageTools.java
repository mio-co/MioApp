package xyz.mio.app.browser;

import android.annotation.SuppressLint;
import android.app.Activity;
import android.app.AlertDialog;
import android.app.Dialog;
import android.graphics.Color;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.webkit.JavascriptInterface;
import android.webkit.WebResourceRequest;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.Toast;

import androidx.webkit.ScriptHandler;
import androidx.webkit.WebViewCompat;
import androidx.webkit.WebViewFeature;

import org.json.JSONObject;
import org.json.JSONTokener;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/**
 * 内置浏览器（:browser 进程）：阅读模式、强制深色、存到 Mio。页面脚本与 iOS / 桌面共用（assets/public/mio-browser）。
 *  - 强制深色：document-start 注入 dark.js（WebViewCompat.addDocumentStartJavaScript），按站点 + 全局开关，智能反色；
 *  - 阅读模式：页面加载完判断是否像文章（地址栏旁显示 📖），提取正文后在全屏对话框里显示（白 / 米 / 深、字号、字体）；
 *  - 存到 Mio：收集网址 / 标题 / 选中文字 / 正文，交给主进程的 MioSaveService（复用 MioCore 主界面的登录 Cookie）。
 */
final class PageTools {
    private final Activity act;
    private final WebView webView;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final boolean docStart;
    private final String readerJs;
    private final String darkJs;
    private ScriptHandler darkHandler;
    private View readerButton;
    private int checkToken;

    @SuppressLint("AddJavascriptInterface")
    PageTools(Activity act, WebView webView) {
        this.act = act;
        this.webView = webView;
        this.docStart = WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT);
        this.readerJs = PageScripts.asset(act, "reader");
        this.darkJs = PageScripts.asset(act, "dark");
        webView.addJavascriptInterface(new DarkBridge(), "MioDarkBridge");
        registerDark();
    }

    void setReaderButton(View v) {
        readerButton = v;
        v.setVisibility(View.GONE);
    }

    /** 深色脚本：设置变了 / 记住了新的「自带深色」站点后重新注册（对之后加载的页面生效） */
    void registerDark() {
        if (darkHandler != null) {
            darkHandler.remove();
            darkHandler = null;
        }
        if (!docStart || darkJs == null) return;
        if (!PageToolsPrefs.needsScript(PageToolsPrefs.darkGlobal(act), PageToolsPrefs.darkSites(act))) return;
        try {
            darkHandler = WebViewCompat.addDocumentStartJavaScript(webView, PageScripts.darkInstall(darkJs, PageToolsPrefs.darkConfig(act)), Collections.singleton("*"));
        } catch (Exception ignored) {}
    }

    void onPageStarted(String url) {
        checkToken++;
        if (readerButton != null) readerButton.setVisibility(View.GONE);
        boolean dark = PageToolsPrefs.isDarkEnabled(act, host(url));
        webView.setBackgroundColor(dark ? Color.rgb(18, 18, 18) : Color.WHITE);
    }

    void onPageFinished() { checkReaderable(300); }

    void onUrlChanged() { checkReaderable(1200); }

    private void checkReaderable(long delay) {
        final int token = ++checkToken;
        main.postDelayed(() -> {
            if (token != checkToken || readerJs == null || readerButton == null) return;
            String u = webView.getUrl();
            if (u == null || !u.startsWith("http")) { readerButton.setVisibility(View.GONE); return; }
            webView.evaluateJavascript(PageScripts.readerable(readerJs), v -> {
                if (token != checkToken) return;
                readerButton.setVisibility("true".equals(v) ? View.VISIBLE : View.GONE);
            });
        }, delay);
    }

    private static String host(String url) {
        try { return url == null ? null : Uri.parse(url).getHost(); } catch (Exception e) { return null; }
    }

    private int dp(float v) {
        return (int) TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, act.getResources().getDisplayMetrics());
    }

    private void toast(String s) { Toast.makeText(act, s, Toast.LENGTH_LONG).show(); }

    // ---------------------------------------------------------------- 菜单

    void showMenu() {
        String url = webView.getUrl();
        String h = host(url);
        boolean web = url != null && url.startsWith("http");
        List<String> items = new ArrayList<>();
        List<Runnable> actions = new ArrayList<>();
        if (web) {
            items.add("存为导航书签"); actions.add(() -> save("bookmark", null));
            items.add("新建笔记（标题 + 链接 + 选中文字 / 正文）"); actions.add(() -> save("note", null));
            items.add("在另一台设备继续（推到云剪贴板）"); actions.add(() -> save("clip", null));
            items.add("阅读模式"); actions.add(() -> openReader(true));
        }
        if (h != null) {
            boolean on = PageToolsPrefs.isDarkEnabled(act, h);
            items.add((on ? "✓ " : "") + "此网站深色（" + PageToolsPrefs.normalizeHost(h) + "）");
            actions.add(() -> { PageToolsPrefs.setSiteDark(act, h, !on); afterDarkChange(); });
        }
        boolean global = PageToolsPrefs.darkGlobal(act);
        items.add((global ? "✓ " : "") + "所有网站深色");
        actions.add(() -> { PageToolsPrefs.setDarkGlobal(act, !global); afterDarkChange(); });
        items.add("书签分类：" + PageToolsPrefs.saveCategory(act) + "…");
        actions.add(this::editCategory);
        new AlertDialog.Builder(act)
                .setTitle("存到 Mio")
                .setItems(items.toArray(new String[0]), (d, which) -> actions.get(which).run())
                .show();
    }

    private void afterDarkChange() {
        registerDark();
        if (webView.getUrl() != null) webView.reload();
    }

    private void editCategory() {
        EditText input = new EditText(act);
        input.setSingleLine(true);
        input.setText(PageToolsPrefs.saveCategory(act));
        new AlertDialog.Builder(act)
                .setTitle("书签分类")
                .setMessage("存为导航书签时放进这个分类（名称或 id），不存在时自动创建")
                .setView(input)
                .setNegativeButton("取消", null)
                .setPositiveButton("保存", (d, w) -> PageToolsPrefs.setSaveCategory(act, input.getText().toString()))
                .show();
    }

    // ---------------------------------------------------------------- 存到 Mio

    void save(String kind, JSONObject extracted) {
        if (extracted != null) { send(kind, extracted); return; }
        String url = webView.getUrl();
        if (url == null || !url.startsWith("http")) { toast("只能保存网页"); return; }
        if ("clip".equals(kind) || readerJs == null) {
            JSONObject p = new JSONObject();
            try { p.put("url", url); p.put("title", webView.getTitle()); } catch (Exception ignored) {}
            send(kind, p);
            return;
        }
        webView.evaluateJavascript(PageScripts.extract(readerJs, new JSONObject(), "note".equals(kind)), v -> {
            JSONObject out = parse(v);
            if (out == null) {
                out = new JSONObject();
                try { out.put("url", url); out.put("title", webView.getTitle()); } catch (Exception ignored) {}
            }
            send(kind, out);
        });
    }

    private void send(String kind, JSONObject out) {
        JSONObject p = new JSONObject();
        try {
            p.put("url", out.optString("url"));
            p.put("title", out.optString("title"));
            if ("note".equals(kind) && !out.optString("selection").isEmpty()) p.put("selection", out.optString("selection"));
            JSONObject a = out.optJSONObject("article");
            if (a != null) {
                JSONObject art = new JSONObject();
                if ("note".equals(kind)) {
                    for (String k : new String[]{"title", "byline", "siteName", "excerpt", "markdown"}) if (a.has(k)) art.put(k, a.opt(k));
                } else {
                    art.put("excerpt", a.optString("excerpt"));
                }
                p.put("article", art);
            }
        } catch (Exception ignored) {}
        MioSaveService.start(act, kind, p);
        toast("正在保存到 MioCore…");
    }

    /** evaluateJavascript 的结果是 JSON 编码的值 */
    private static JSONObject parse(String v) {
        if (v == null || "null".equals(v)) return null;
        try {
            Object o = new JSONTokener(v).nextValue();
            return o instanceof JSONObject ? (JSONObject) o : null;
        } catch (Exception e) {
            return null;
        }
    }

    // ---------------------------------------------------------------- 阅读模式

    void openReader(boolean force) {
        if (readerJs == null) return;
        JSONObject prefs = PageToolsPrefs.readerPrefs(act);
        webView.evaluateJavascript(PageScripts.extract(readerJs, prefs, force), v -> {
            JSONObject out = parse(v);
            if (out == null || out.optString("page").isEmpty()) { toast("这个页面没有可提取的正文"); return; }
            showReader(out);
        });
    }

    @SuppressLint("SetJavaScriptEnabled")
    private void showReader(JSONObject out) {
        Dialog dialog = new Dialog(act, android.R.style.Theme_DeviceDefault_Light_NoActionBar);
        LinearLayout col = new LinearLayout(act);
        col.setOrientation(LinearLayout.VERTICAL);
        WebView reader = new WebView(act);
        // 只为了切换主题时执行 applyPrefs；正文里的脚本已去掉，阅读页另有 CSP（default-src 'none'）禁止脚本
        reader.getSettings().setJavaScriptEnabled(true);
        reader.getSettings().setAllowFileAccess(false);
        reader.getSettings().setAllowContentAccess(false);
        reader.setWebViewClient(new WebViewClient() {
            @Override
            public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                String u = request.getUrl().toString();
                if (u.startsWith("http")) {
                    dialog.dismiss();
                    webView.loadUrl(u);
                }
                return true;
            }
        });
        String url = out.optString("url");
        reader.loadDataWithBaseURL(url, out.optString("page"), "text/html", "utf-8", null);
        col.addView(reader, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1));

        LinearLayout bar = new LinearLayout(act);
        bar.setOrientation(LinearLayout.HORIZONTAL);
        bar.setGravity(Gravity.CENTER);
        Runnable apply = () -> {
            JSONObject p = PageToolsPrefs.readerPrefs(act);
            reader.evaluateJavascript(PageScripts.applyPrefs(p), null);
            String t = p.optString("theme");
            int bg = "dark".equals(t) ? Color.rgb(18, 18, 18) : "sepia".equals(t) ? Color.rgb(246, 239, 225) : Color.WHITE;
            reader.setBackgroundColor(bg);
            bar.setBackgroundColor(bg);
            int fg = "dark".equals(t) ? Color.rgb(230, 230, 230) : Color.rgb(31, 35, 40);
            for (int i = 0; i < bar.getChildCount(); i++) ((Button) bar.getChildAt(i)).setTextColor(fg);
        };
        String[][] buttons = {{"完成", "返回原网页"}, {"白", "白色背景"}, {"米", "米色背景"}, {"深", "深色背景"}, {"A−", "字号变小"}, {"A+", "字号变大"}, {"字体", "切换字体"}, {"📥", "存到 Mio"}};
        for (String[] b : buttons) {
            Button btn = new Button(act, null, android.R.attr.borderlessButtonStyle);
            btn.setText(b[0]);
            btn.setAllCaps(false);
            btn.setContentDescription(b[1]);
            btn.setMinWidth(0);
            btn.setMinimumWidth(0);
            btn.setPadding(dp(6), 0, dp(6), 0);
            btn.setOnClickListener(v -> {
                JSONObject p = PageToolsPrefs.readerPrefs(act);
                switch (b[0]) {
                    case "完成": dialog.dismiss(); return;
                    case "白": PageToolsPrefs.setReaderPref(act, "readerTheme", "light"); break;
                    case "米": PageToolsPrefs.setReaderPref(act, "readerTheme", "sepia"); break;
                    case "深": PageToolsPrefs.setReaderPref(act, "readerTheme", "dark"); break;
                    case "A−": PageToolsPrefs.setReaderPref(act, "readerFontSize", p.optInt("fontSize", 18) - 1); break;
                    case "A+": PageToolsPrefs.setReaderPref(act, "readerFontSize", p.optInt("fontSize", 18) + 1); break;
                    case "字体": {
                        String f = p.optString("font");
                        PageToolsPrefs.setReaderPref(act, "readerFont", "sans".equals(f) ? "serif" : "serif".equals(f) ? "mono" : "sans");
                        break;
                    }
                    case "📥": {
                        String[] kinds = {"bookmark", "note", "clip"};
                        new AlertDialog.Builder(act).setTitle("存到 Mio")
                                .setItems(new String[]{"存为导航书签", "新建笔记", "在另一台设备继续"}, (d, w) -> save(kinds[w], out))
                                .show();
                        return;
                    }
                    default: break;
                }
                apply.run();
            });
            bar.addView(btn, new LinearLayout.LayoutParams(0, dp(48), 1));
        }
        col.addView(bar, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        // Android 15 起强制 edge-to-edge：避开状态栏 / 导航栏
        androidx.core.view.ViewCompat.setOnApplyWindowInsetsListener(col, (v, insets) -> {
            androidx.core.graphics.Insets bars = insets.getInsets(androidx.core.view.WindowInsetsCompat.Type.systemBars() | androidx.core.view.WindowInsetsCompat.Type.displayCutout());
            v.setPadding(bars.left, bars.top, bars.right, bars.bottom);
            return androidx.core.view.WindowInsetsCompat.CONSUMED;
        });
        dialog.setContentView(col);
        dialog.setOnDismissListener(d -> reader.destroy());
        apply.run();
        dialog.show();
    }

    // ---------------------------------------------------------------- dark.js 上报

    private class DarkBridge {
        @JavascriptInterface
        public void report(String json) {
            JSONObject o = null;
            try { o = new JSONObject(json); } catch (Exception ignored) {}
            if (o == null) return;
            String h = o.optString("host");
            boolean nativeDark = "native".equals(o.optString("verdict"));
            main.post(() -> {
                if (PageToolsPrefs.reportDark(act, h, nativeDark)) registerDark();
            });
        }
    }
}
