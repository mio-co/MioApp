package xyz.mio.app.browser;

import android.annotation.SuppressLint;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.webkit.JavascriptInterface;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Toast;

import org.json.JSONObject;

/**
 * 存到 MioCore（主进程）：内置浏览器在 :browser 进程，拿不到 MioCore 主界面的登录 Cookie；
 * 这里在主进程（与 Capacitor 主界面同一个 WebView 数据目录）建一个不显示的 WebView，打开 MioCore 同源的空白文档，
 * 用 mio-save.js 的同源 fetch 调 API（复用主界面的会话 Cookie / Cloudflare Access），完成后 Toast 提示。
 */
public class MioSaveService extends Service {
    static final String EXTRA_KIND = "kind";
    static final String EXTRA_PAYLOAD = "payload";
    private static final String ORIGIN = "https://mio.300031.xyz";

    private final Handler main = new Handler(Looper.getMainLooper());
    private int running;

    static void start(Context c, String kind, JSONObject payload) {
        Intent i = new Intent(c, MioSaveService.class);
        i.putExtra(EXTRA_KIND, kind);
        i.putExtra(EXTRA_PAYLOAD, payload.toString());
        c.startService(i);
    }

    @Override
    public IBinder onBind(Intent intent) { return null; }

    @SuppressLint({"SetJavaScriptEnabled", "AddJavascriptInterface"})
    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent == null) { stopSelfIfIdle(); return START_NOT_STICKY; }
        String kind = intent.getStringExtra(EXTRA_KIND);
        JSONObject payload;
        try { payload = new JSONObject(intent.getStringExtra(EXTRA_PAYLOAD)); } catch (Exception e) { payload = new JSONObject(); }
        String src = PageScripts.asset(this, "mio-save");
        if (src == null || kind == null) { toast("App 包里缺少 mio-save.js"); stopSelfIfIdle(); return START_NOT_STICKY; }
        JSONObject opts = new JSONObject();
        try {
            opts.put("origin", ORIGIN);
            opts.put("category", PageToolsPrefs.saveCategory(this));
        } catch (Exception ignored) {}
        final String code = PageScripts.save(src, kind, payload, opts);
        running++;
        WebView w = new WebView(getApplicationContext());
        w.getSettings().setJavaScriptEnabled(true);
        final boolean[] done = {false};
        w.addJavascriptInterface(new Object() {
            @JavascriptInterface
            public void done(String json) {
                main.post(() -> finish(w, json, done));
            }
        }, "MioSaveBridge");
        w.setWebViewClient(new WebViewClient() {
            @Override
            public void onPageFinished(WebView view, String url) {
                view.evaluateJavascript(code, null);
            }
        });
        // MioCore 同源的空白文档（不发网络请求），fetch 时带上主界面的 Cookie
        w.loadDataWithBaseURL(ORIGIN + "/", "<!doctype html><meta charset=\"utf-8\"><title>Mio</title>", "text/html", "utf-8", null);
        main.postDelayed(() -> finish(w, "{\"ok\":false,\"message\":\"保存超时（30 秒）\"}", done), 30000);
        return START_NOT_STICKY;
    }

    private void finish(WebView w, String json, boolean[] done) {
        if (done[0]) return;
        done[0] = true;
        JSONObject r = null;
        try { r = new JSONObject(json); } catch (Exception ignored) {}
        toast(PageScripts.saveMessage(r));
        try { w.destroy(); } catch (Exception ignored) {}
        running--;
        stopSelfIfIdle();
    }

    private void stopSelfIfIdle() {
        if (running <= 0) stopSelf();
    }

    private void toast(String text) {
        main.post(() -> Toast.makeText(getApplicationContext(), text, Toast.LENGTH_LONG).show());
    }
}
