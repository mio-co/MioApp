package xyz.mio.app.update;

import android.content.Context;
import android.content.pm.ApplicationInfo;

import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;

/**
 * 更新设置（filesDir/mio-update-prefs.json，每次读盘：主进程和 :browser 进程的设置页都看到最新值）。
 * 键独立于浏览器设置（mio-browser-prefs.json）。
 */
public final class UpdatePrefs {
    private UpdatePrefs() {}

    private static File file(Context c) { return new File(c.getFilesDir(), "mio-update-prefs.json"); }

    private static synchronized JSONObject read(Context c) {
        File f = file(c);
        if (f.exists()) {
            try (FileInputStream in = new FileInputStream(f)) {
                ByteArrayOutputStream out = new ByteArrayOutputStream();
                byte[] buf = new byte[4096];
                int n;
                while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
                return new JSONObject(new String(out.toByteArray(), StandardCharsets.UTF_8));
            } catch (Exception ignored) {}
        }
        return new JSONObject();
    }

    private static synchronized void update(Context c, String key, Object value) {
        try {
            JSONObject o = read(c);
            o.put(key, value);
            File f = file(c);
            File tmp = new File(f.getPath() + ".tmp");
            try (FileOutputStream out = new FileOutputStream(tmp)) {
                out.write(o.toString().getBytes(StandardCharsets.UTF_8));
            }
            //noinspection ResultOfMethodCallIgnored
            tmp.renameTo(f);
        } catch (Exception ignored) {}
    }

    static boolean debuggable(Context c) {
        return (c.getApplicationInfo().flags & ApplicationInfo.FLAG_DEBUGGABLE) != 0;
    }

    /** 自动检查：默认开；调试包（Mio-x.y.z-android-debug.apk，签名与 Mio.apk 不同，不能覆盖安装）默认关 */
    public static boolean autoCheck(Context c) { return read(c).optBoolean("autoCheck", !debuggable(c)); }
    public static void setAutoCheck(Context c, boolean v) { update(c, "autoCheck", v); }

    public static long lastCheck(Context c) { return read(c).optLong("lastCheck", 0); }
    public static void setLastCheck(Context c, long v) { update(c, "lastCheck", v); }

    public static long lastAttempt(Context c) { return read(c).optLong("lastAttempt", 0); }
    public static void setLastAttempt(Context c, long v) { update(c, "lastAttempt", v); }

    public static String skipVersion(Context c) { return read(c).optString("skipVersion", ""); }
    public static void setSkipVersion(Context c, String v) { update(c, "skipVersion", v == null ? "" : v); }
}
