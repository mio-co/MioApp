package xyz.mio.app.browser;

import android.content.Intent;
import android.net.Uri;

import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;

/**
 * Capacitor 插件 MioBrowser（与 iOS 同名同接口）：MioCore 页面里点站外链接时
 * Capacitor.Plugins.MioBrowser.open({ url, mode? }) → App 内置浏览器（独立进程 :browser，独立 WebView 数据）
 */
@CapacitorPlugin(name = "MioBrowser")
public class MioBrowserPlugin extends Plugin {

    @PluginMethod
    public void open(PluginCall call) {
        String url = call.getString("url", "").trim();
        Uri uri = Uri.parse(url);
        String scheme = uri.getScheme() == null ? "" : uri.getScheme().toLowerCase();
        if (!scheme.equals("http") && !scheme.equals("https")) {
            call.reject("invalid url");
            return;
        }
        String mode = call.getString("mode", "auto");
        boolean system = "safari".equals(mode) || "system".equals(mode)
                || ("auto".equals(mode) && BrowserPrefs.preferSystemBrowser(getContext()));
        JSObject ret = new JSObject();
        try {
            if (system) {
                Intent i = new Intent(Intent.ACTION_VIEW, uri);
                i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                getContext().startActivity(i);
                ret.put("opened", "system");
            } else {
                getContext().startActivity(BrowserActivity.intent(getContext(), url, false));
                ret.put("opened", "inapp");
            }
            call.resolve(ret);
        } catch (Exception e) {
            call.reject(String.valueOf(e.getMessage()));
        }
    }

    @PluginMethod
    public void openSettings(PluginCall call) {
        getContext().startActivity(BrowserActivity.intent(getContext(), null, true));
        call.resolve();
    }

    @PluginMethod
    public void getInfo(PluginCall call) {
        JSObject ret = new JSObject();
        ret.put("adblock", BrowserPrefs.adblockEnabled(getContext()));
        ret.put("preferSafari", BrowserPrefs.preferSystemBrowser(getContext()));
        ret.put("platform", "android");
        call.resolve(ret);
    }
}
