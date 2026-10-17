package xyz.mio.app.containers;

import android.app.Activity;
import android.content.pm.PackageInfo;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.webkit.CookieManager;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.LinearLayout;

import androidx.webkit.ProfileStore;
import androidx.webkit.WebViewCompat;

import org.json.JSONObject;

import java.util.List;

/**
 * 只在 debug 包：模拟器冒烟（scripts/android-containers-smoke.sh）。
 * adb shell am start -n xyz.mio.app/xyz.mio.app.containers.ContainerSelfTestActivity
 * 检测 MULTI_PROFILE；支持时用 ContainerManager 建两个容器，验证 Cookie（Profile CookieManager）和 LocalStorage（页面 JS）互相隔离、
 * 默认容器看不到，然后删除容器并确认 Profile 被删掉。结果一行 JSON 写进 logcat（tag MioContainerSmoke）。
 */
public class ContainerSelfTestActivity extends Activity {
    private static final String TAG = "MioContainerSmoke";
    private static final String BASE = "https://mio-container-smoke.example/";
    private final Handler main = new Handler(Looper.getMainLooper());
    private final JSONObject result = new JSONObject();
    private WebView wa, wb, wd;
    private String ida, idb;

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        try {
            WebView.setDataDirectorySuffix("smoke");
        } catch (Throwable ignored) {
            // 已创建过 WebView
        }
        try {
            boolean supported = ContainerManager.isSupported();
            result.put("supported", supported);
            PackageInfo p = WebViewCompat.getCurrentWebViewPackage(this);
            result.put("webview", p != null ? p.packageName + " " + p.versionName : "?");
            if (!supported) {
                result.put("ok", true);
                result.put("note", "MULTI_PROFILE not supported by this WebView; containers disabled (isSupported=false)");
                finishWith();
                return;
            }
            run();
        } catch (Throwable t) {
            fail(t);
        }
    }

    private void run() throws Exception {
        ContainerManager cm = ContainerManager.get(this);
        ida = cm.create("smoke-a", null).id;
        idb = cm.create("smoke-b", null).id;
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        wa = new WebView(this);
        String appliedA = cm.apply(wa, ida);
        wb = new WebView(this);
        String appliedB = cm.apply(wb, idb);
        wd = new WebView(this);
        String appliedD = cm.apply(wd, ContainerState.DEFAULT_ID);
        result.put("applied", appliedA.equals(ida) && appliedB.equals(idb) && appliedD.equals(ContainerState.DEFAULT_ID));
        result.put("profiles", new JSONObject()
                .put("a", WebViewCompat.getProfile(wa).getName())
                .put("b", WebViewCompat.getProfile(wb).getName())
                .put("d", WebViewCompat.getProfile(wd).getName()));
        for (WebView w : new WebView[]{wa, wb, wd}) {
            w.getSettings().setJavaScriptEnabled(true);
            w.getSettings().setDomStorageEnabled(true);
            root.addView(w, new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1));
        }
        setContentView(root);

        // Cookie：每个 Profile 自己的 CookieManager
        CookieManager ca = cm.cookieManager(ida), cb = cm.cookieManager(idb), cd = CookieManager.getInstance();
        ca.setCookie(BASE, "k=A; Max-Age=3600");
        cb.setCookie(BASE, "k=B; Max-Age=3600");
        ca.flush();
        cb.flush();
        String sa = String.valueOf(ca.getCookie(BASE)), sb = String.valueOf(cb.getCookie(BASE)), sd = String.valueOf(cd.getCookie(BASE));
        result.put("cookies", new JSONObject().put("a", sa).put("b", sb).put("d", sd));
        boolean cookieIsolated = sa.contains("k=A") && !sa.contains("k=B") && sb.contains("k=B") && !sb.contains("k=A") && !sd.contains("k=");
        result.put("cookieIsolated", cookieIsolated);

        // LocalStorage：页面 JS（同一个 https 源）
        String html = "<!doctype html><title>smoke</title><p>container smoke</p>";
        int[] loaded = {0};
        WebViewClient client = new WebViewClient() {
            @Override public void onPageFinished(WebView v, String url) {
                if (++loaded[0] == 3) main.postDelayed(ContainerSelfTestActivity.this::writeStorage, 300);
            }
        };
        for (WebView w : new WebView[]{wa, wb, wd}) {
            w.setWebViewClient(client);
            w.loadDataWithBaseURL(BASE, html, "text/html", "utf-8", null);
        }
        main.postDelayed(() -> { if (!result.has("ok")) fail(new Exception("timeout")); }, 30000);
    }

    private void writeStorage() {
        wa.evaluateJavascript("localStorage.setItem('mio','A'); document.cookie='js=A; max-age=3600'; 'ok'", r1 ->
                wb.evaluateJavascript("localStorage.setItem('mio','B'); document.cookie='js=B; max-age=3600'; 'ok'", r2 -> main.postDelayed(this::readStorage, 300)));
    }

    private static final String READ = "JSON.stringify({ local: localStorage.getItem('mio'), cookie: document.cookie })";

    private void readStorage() {
        wa.evaluateJavascript(READ, ra -> wb.evaluateJavascript(READ, rb -> wd.evaluateJavascript(READ, rd -> {
            try {
                JSONObject a = new JSONObject(unquote(ra)), b = new JSONObject(unquote(rb)), d = new JSONObject(unquote(rd));
                result.put("storage", new JSONObject().put("a", a).put("b", b).put("d", d));
                boolean localIsolated = "A".equals(a.optString("local")) && "B".equals(b.optString("local")) && d.isNull("local");
                result.put("localStorageIsolated", localIsolated);
                // document.cookie 只报告（data: + baseURL 的页面是否允许写 Cookie 取决于 WebView 版本）
                result.put("docCookieLeak", d.optString("cookie").contains("js="));
                cleanup();
            } catch (Throwable t) {
                fail(t);
            }
        })));
    }

    private static String unquote(String js) throws Exception {
        // evaluateJavascript 返回 JSON 字符串字面量
        return new org.json.JSONTokener(js).nextValue().toString();
    }

    private void cleanup() throws Exception {
        for (WebView w : new WebView[]{wa, wb, wd}) {
            ((LinearLayout) w.getParent()).removeView(w);
            w.destroy();
        }
        ContainerManager cm = ContainerManager.get(this);
        cm.remove(ida);
        cm.remove(idb);
        result.put("metadataRemoved", cm.container(ida) == null && cm.container(idb) == null);
        // ContainerManager 在下一轮消息循环删 Profile（被占用时 1.5 秒重试）
        main.postDelayed(() -> {
            try {
                List<String> names = ProfileStore.getInstance().getAllProfileNames();
                boolean gone = !names.contains(ContainerManager.profileName(ida)) && !names.contains(ContainerManager.profileName(idb));
                result.put("profilesAfterDelete", names.toString());
                result.put("profilesDeleted", gone);
                result.put("pendingAfterDelete", cm.state().pendingRemovals().size());
                result.put("ok", result.optBoolean("applied") && result.optBoolean("cookieIsolated") && result.optBoolean("localStorageIsolated") && result.optBoolean("metadataRemoved"));
                finishWith();
            } catch (Throwable t) {
                fail(t);
            }
        }, 8000);
    }

    private void fail(Throwable t) {
        try {
            result.put("ok", false);
            result.put("error", String.valueOf(t));
        } catch (Exception ignored) {
            // ignore
        }
        Log.e(TAG, "error", t);
        finishWith();
    }

    private void finishWith() {
        Log.i(TAG, "result " + result);
        main.postDelayed(this::finish, 500);
    }
}
