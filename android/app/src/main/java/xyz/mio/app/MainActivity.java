package xyz.mio.app;

import android.os.Bundle;
import android.util.Log;
import android.webkit.WebView;

import com.getcapacitor.BridgeActivity;
import com.getcapacitor.CapConfig;
import com.getcapacitor.WebViewListener;

import java.lang.reflect.Field;

import xyz.mio.app.adblock.AdblockUpdateWorker;
import xyz.mio.app.browser.MioBrowserPlugin;

public class MainActivity extends BridgeActivity {
    static final String TAG = "MioStart";

    @Override
    public void onCreate(Bundle savedInstanceState) {
        // 应用内插件要在 super.onCreate（创建 Bridge）之前注册
        registerPlugin(MioBrowserPlugin.class);
        // Capacitor 用 server.url + appStartPath 直接拼字符串；先把 appStartPath 规范成 "/..."，避免拼成 https://hostpath
        try {
            config = CapConfig.loadDefault(this);
            normalizeStartPath(config);
        } catch (Throwable t) {
            Log.w(TAG, "normalize config failed", t);
            config = null;
        }
        super.onCreate(savedInstanceState);

        if (bridge != null) {
            String server = config != null ? config.getServerUrl() : null;
            String start = config != null ? config.getStartPath() : null;
            String appUrl = bridge.getAppUrl();
            Log.i(TAG, "appUrl=" + appUrl);
            if (server != null && !server.isEmpty()) {
                String expected = StartUrl.resolve(server, start);
                if (!expected.equals(appUrl) && bridge.getWebView() != null) {
                    // 兜底：Capacitor 拼出来的地址不对，就直接加载规范化后的地址
                    Log.w(TAG, "appUrl mismatch, loading " + expected);
                    bridge.getWebView().loadUrl(expected);
                }
            }
            bridge.addWebViewListener(new WebViewListener() {
                @Override
                public void onPageLoaded(WebView webView) {
                    Log.i(TAG, "pageLoaded " + webView.getUrl());
                }

                @Override
                public void onReceivedError(WebView webView) {
                    Log.w(TAG, "receivedError " + webView.getUrl());
                }
            });
        }
        // 内置浏览器的拦截规则：每天检查一次；距上次超过 24 小时则马上检查
        AdblockUpdateWorker.schedule(this);
        // 软件内更新：回到前台时距上次检查超过 24 小时就查 GitHub Releases（xyz.mio.app.update）
        xyz.mio.app.update.UpdateUi.attach(this);
    }

    /** CapConfig 没有 setter：只在路径需要规范化时用反射改 startPath */
    static void normalizeStartPath(CapConfig cfg) throws Exception {
        String start = cfg.getStartPath();
        String fixed = StartUrl.normalizePath(start);
        if (start == null || start.equals(fixed)) return;
        Field f = CapConfig.class.getDeclaredField("startPath");
        f.setAccessible(true);
        f.set(cfg, fixed);
        Log.i(TAG, "appStartPath " + start + " -> " + fixed);
    }
}
