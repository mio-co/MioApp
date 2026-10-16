package xyz.mio.app.adblock;

import android.content.Context;
import android.content.res.AssetManager;
import android.util.Base64;
import android.util.Log;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Date;
import java.util.List;
import java.util.Locale;
import java.util.TimeZone;
import java.util.concurrent.locks.ReentrantReadWriteLock;

/**
 * 过滤列表下载 / 缓存 / 引擎构建（与 iOS 的 MioAdblockCore 同一套逻辑）：
 * - App 内置：assets/adblock/filter-*.txt、manifest.json（ETag / Last-Modified）、scriptlets.corelibs.json、extended-css.min.js
 * - 本机缓存：files/adblock/（lists/、state.json、scriptlets.corelibs.json）
 * - 更新：超过 24 小时（WorkManager 每天 + App 启动时）逐个列表 If-None-Match / If-Modified-Since；
 *   Scriptlets：npm registry 同主版本 latest → jsDelivr 下载 → 用 jsDelivr data API 的 SHA-256 校验；失败回退已有 / 内置版本
 * 浏览器在独立进程（:browser）里用这里的 engine()；主进程只负责下载（WorkManager）。
 */
public final class AdblockStore {
    private static final String TAG = "MioAdblock";
    public static final long UPDATE_INTERVAL_MS = 24L * 3600 * 1000;

    public static final int[] REMOTE_IDS = {2, 11, 3, 101, 118, 224};
    public static final int[] ALL_IDS = {2, 11, 3, 101, 118, 224, 0};

    public static String listName(int id) {
        switch (id) {
            case 2: return "AdGuard Base";
            case 11: return "AdGuard 移动广告";
            case 3: return "AdGuard 跟踪保护";
            case 101: return "EasyList";
            case 118: return "EasyPrivacy";
            case 224: return "AdGuard 中文";
            case 0: return "Mio YouTube 补充";
            default: return "列表 " + id;
        }
    }

    private static AdblockStore instance;

    public static synchronized AdblockStore get(Context context) {
        if (instance == null) instance = new AdblockStore(context.getApplicationContext());
        return instance;
    }

    private final Context context;
    private final File dir;
    private final File listsDir;
    private final File stateFile;
    private final File scriptletsFile;
    private final ReentrantReadWriteLock lock = new ReentrantReadWriteLock();
    private long handle;
    private long builtAt;
    private long builtFromState;
    private String scriptletsVersion;
    private String lastBuildError;

    private AdblockStore(Context context) {
        this.context = context;
        dir = new File(context.getFilesDir(), "adblock");
        listsDir = new File(dir, "lists");
        stateFile = new File(dir, "state.json");
        scriptletsFile = new File(dir, "scriptlets.corelibs.json");
        //noinspection ResultOfMethodCallIgnored
        listsDir.mkdirs();
    }

    // ---------------- state ----------------

    public synchronized JSONObject state() {
        try {
            if (stateFile.exists()) return new JSONObject(readFile(stateFile));
        } catch (Exception ignored) {}
        return new JSONObject();
    }

    private synchronized void saveState(JSONObject s) {
        try {
            writeFileAtomic(stateFile, s.toString(2).getBytes(StandardCharsets.UTF_8));
        } catch (Exception e) {
            Log.w(TAG, "save state", e);
        }
    }

    private JSONObject listMeta(JSONObject s, int id) {
        JSONObject lists = s.optJSONObject("lists");
        if (lists == null) {
            lists = new JSONObject();
            try { s.put("lists", lists); } catch (Exception ignored) {}
        }
        JSONObject m = lists.optJSONObject(String.valueOf(id));
        if (m == null) {
            m = new JSONObject();
            try { lists.put(String.valueOf(id), m); } catch (Exception ignored) {}
        }
        return m;
    }

    public boolean needsUpdate() {
        long last = state().optLong("lastCheck", 0);
        return System.currentTimeMillis() - last >= UPDATE_INTERVAL_MS;
    }

    // ---------------- lists ----------------

    private String bundledText(String name) {
        try (InputStream in = context.getAssets().open("adblock/" + name, AssetManager.ACCESS_STREAMING)) {
            return new String(readAll(in), StandardCharsets.UTF_8);
        } catch (IOException e) {
            return null;
        }
    }

    private JSONObject bundledManifest() {
        String s = bundledText("manifest.json");
        try { return s == null ? new JSONObject() : new JSONObject(s).optJSONObject("lists"); } catch (Exception e) { return new JSONObject(); }
    }

    /** 首次 / App 升级带了更新的内置列表：用内置版本 */
    private synchronized void prepareLists() {
        JSONObject s = state();
        JSONObject manifest = bundledManifest();
        if (manifest == null) manifest = new JSONObject();
        boolean changed = false;
        for (int id : ALL_IDS) {
            File local = new File(listsDir, "filter-" + id + ".txt");
            JSONObject m = listMeta(s, id);
            String bundled = bundledText("filter-" + id + ".txt");
            if (bundled == null) continue;
            String bsha = sha256Hex(bundled.getBytes(StandardCharsets.UTF_8));
            boolean useBundle = !local.exists() || m.optString("sha256").isEmpty();
            if (!useBundle && "bundle".equals(m.optString("source", "bundle")) && !bsha.equals(m.optString("sha256"))) useBundle = true;
            if (!useBundle && id == 0 && !bsha.equals(m.optString("sha256"))) useBundle = true;
            JSONObject bm = manifest.optJSONObject(String.valueOf(id));
            if (!useBundle && "remote".equals(m.optString("source")) && bm != null) {
                Date bt = httpDate(bm.optString("lastModified", null));
                Date lt = httpDate(m.optString("lastModified", null));
                if (bt != null && lt != null && bt.after(lt)) useBundle = true;
            }
            if (useBundle) {
                try {
                    writeFileAtomic(local, bundled.getBytes(StandardCharsets.UTF_8));
                    m.put("source", "bundle");
                    m.put("sha256", bsha);
                    m.put("version", header(bundled, "! Version:"));
                    m.put("etag", bm != null ? bm.optString("etag", null) : JSONObject.NULL);
                    m.put("lastModified", bm != null ? bm.optString("lastModified", null) : JSONObject.NULL);
                    m.remove("fetchedAt");
                    changed = true;
                } catch (Exception e) {
                    Log.w(TAG, "copy bundled " + id, e);
                }
            }
        }
        if (changed) saveState(s);
    }

    // ---------------- engine ----------------

    /** 当前引擎；返回非 0 时持有读锁，用完必须 release()。构建由 ensureEngine()（后台线程）负责 */
    public long acquire() {
        lock.readLock().lock();
        if (handle == 0) {
            lock.readLock().unlock();
            return 0;
        }
        return handle;
    }

    public void release() {
        lock.readLock().unlock();
    }

    public boolean isReady() { return handle != 0; }
    public String scriptletsVersion() { return scriptletsVersion; }
    public String lastBuildError() { return lastBuildError; }
    public long builtAt() { return builtAt; }

    /** 主进程更新了列表（state.json 变了）→ 重建 */
    public synchronized void ensureEngine() {
        long stateMtime = stateFile.lastModified();
        if (handle != 0 && stateMtime <= builtFromState) return;
        if (!AdblockNative.isLoaded()) {
            lastBuildError = "native library: " + AdblockNative.loadError();
            return;
        }
        prepareLists();
        long t0 = System.currentTimeMillis();
        List<String> texts = new ArrayList<>();
        for (int id : ALL_IDS) {
            File f = new File(listsDir, "filter-" + id + ".txt");
            if (!f.exists()) continue;
            try { texts.add(readFile(f)); } catch (IOException e) { Log.w(TAG, "read " + f, e); }
        }
        long h = AdblockNative.build(texts.toArray(new String[0]));
        if (h == 0) {
            lastBuildError = "build failed";
            return;
        }
        String scriptlets = loadScriptletsJson();
        String ext = bundledText("extended-css.min.js");
        String v = AdblockNative.setResources(h, scriptlets == null ? "" : scriptlets, ext == null ? "" : ext);
        if (v == null && scriptlets != null && scriptletsFile.exists()) {
            // 远程缓存坏了 → 内置版本
            String b = bundledText("scriptlets.corelibs.json");
            v = AdblockNative.setResources(h, b == null ? "" : b, ext == null ? "" : ext);
        }
        lock.writeLock().lock();
        try {
            long old = handle;
            handle = h;
            scriptletsVersion = v;
            builtAt = System.currentTimeMillis();
            builtFromState = Math.max(stateMtime, stateFile.lastModified());
            lastBuildError = null;
            if (old != 0) AdblockNative.free(old);
        } finally {
            lock.writeLock().unlock();
        }
        Log.i(TAG, "engine built in " + (System.currentTimeMillis() - t0) + " ms, " + AdblockNative.stats(h));
    }

    private String loadScriptletsJson() {
        JSONObject s = state();
        JSONObject sm = s.optJSONObject("scriptlets");
        String bundled = bundledText("scriptlets.corelibs.json");
        if (sm != null && "remote".equals(sm.optString("source")) && scriptletsFile.exists()) {
            try {
                byte[] data = readAll(new java.io.FileInputStream(scriptletsFile));
                String sha = Base64.encodeToString(sha256(data), Base64.NO_WRAP);
                String bver = bundled != null ? new JSONObject(bundled).optString("version") : "0";
                if (sha.equals(sm.optString("sha256")) && compareVersions(sm.optString("version"), bver) >= 0) {
                    return new String(data, StandardCharsets.UTF_8);
                }
            } catch (Exception ignored) {}
        }
        return bundled;
    }

    // ---------------- update ----------------

    /** 下载更新（任意进程，阻塞，别在主线程调）。返回给用户看的结果文字 */
    public String update(boolean force) {
        prepareLists();
        JSONObject s = state();
        if (!force && System.currentTimeMillis() - s.optLong("lastCheck", 0) < UPDATE_INTERVAL_MS) return "24 小时内已检查过";
        int changed = 0, ok = 0;
        List<String> failed = new ArrayList<>();
        for (int id : REMOTE_IDS) {
            JSONObject m = listMeta(s, id);
            HttpURLConnection c = null;
            try {
                c = (HttpURLConnection) new URL("https://filters.adtidy.org/ios/filters/" + id + "_optimized.txt").openConnection();
                c.setConnectTimeout(30000);
                c.setReadTimeout(60000);
                c.setUseCaches(false);
                String etag = m.optString("etag", "");
                String lm = m.optString("lastModified", "");
                if (!etag.isEmpty() && !"null".equals(etag)) c.setRequestProperty("If-None-Match", etag);
                if (!lm.isEmpty() && !"null".equals(lm)) c.setRequestProperty("If-Modified-Since", lm);
                int code = c.getResponseCode();
                m.put("checkedAt", System.currentTimeMillis());
                if (code == 304) {
                    ok++;
                } else if (code == 200) {
                    byte[] data = readAll(c.getInputStream());
                    String text = new String(data, StandardCharsets.UTF_8);
                    if (!looksLikeFilter(text)) throw new IOException("内容不像过滤列表");
                    String sha = sha256Hex(data);
                    if (!sha.equals(m.optString("sha256"))) {
                        writeFileAtomic(new File(listsDir, "filter-" + id + ".txt"), data);
                        m.put("sha256", sha);
                        m.put("version", header(text, "! Version:"));
                        m.put("fetchedAt", System.currentTimeMillis());
                        m.put("source", "remote");
                        changed++;
                    }
                    m.put("etag", c.getHeaderField("ETag"));
                    m.put("lastModified", c.getHeaderField("Last-Modified"));
                    ok++;
                } else {
                    throw new IOException("HTTP " + code);
                }
                m.remove("error");
            } catch (Exception e) {
                try { m.put("error", String.valueOf(e.getMessage())); } catch (Exception ignored) {}
                failed.add(listName(id));
            } finally {
                if (c != null) c.disconnect();
            }
        }
        String sl = updateScriptlets(s);
        try {
            if (ok > 0) s.put("lastCheck", System.currentTimeMillis());
            String msg = failed.isEmpty()
                    ? (changed > 0 ? changed + " 个列表有更新" : "规则已是最新") + "；" + sl
                    : "部分失败：" + android.text.TextUtils.join("、", failed) + "；" + sl;
            s.put("lastCheckMessage", msg);
            s.put("lastCheckOK", failed.isEmpty());
            saveState(s);
            return msg;
        } catch (Exception e) {
            return String.valueOf(e);
        }
    }

    private String updateScriptlets(JSONObject s) {
        try {
            String bundled = bundledText("scriptlets.corelibs.json");
            JSONObject sm = s.optJSONObject("scriptlets");
            String current = sm != null && "remote".equals(sm.optString("source")) ? sm.optString("version")
                    : (bundled != null ? new JSONObject(bundled).optString("version") : "0");
            String major = current.split("\\.")[0];
            JSONObject reg = new JSONObject(new String(get("https://registry.npmjs.org/@adguard/scriptlets", "application/vnd.npm.install-v1+json"), StandardCharsets.UTF_8));
            String latest = reg.getJSONObject("dist-tags").getString("latest");
            if (!latest.split("\\.")[0].equals(major)) return "Scriptlets " + current + "（新主版本 " + latest + " 未自动采用）";
            if (compareVersions(latest, current) <= 0) return "Scriptlets " + current + " 已是最新";
            String path = "/dist/scriptlets.corelibs.json";
            JSONObject flat = new JSONObject(new String(get("https://data.jsdelivr.com/v1/packages/npm/@adguard/scriptlets@" + latest + "?structure=flat", null), StandardCharsets.UTF_8));
            JSONArray files = flat.getJSONArray("files");
            String expected = null;
            for (int i = 0; i < files.length(); i++) {
                JSONObject f = files.getJSONObject(i);
                if (path.equals(f.optString("name"))) expected = f.optString("hash");
            }
            if (expected == null) throw new IOException("jsDelivr 没有哈希");
            byte[] data = get("https://cdn.jsdelivr.net/npm/@adguard/scriptlets@" + latest + path, null);
            String got = Base64.encodeToString(sha256(data), Base64.NO_WRAP);
            if (!got.equals(expected)) throw new IOException("哈希不匹配");
            JSONObject parsed = new JSONObject(new String(data, StandardCharsets.UTF_8));
            if (!latest.equals(parsed.optString("version")) || parsed.optJSONArray("scriptlets") == null || parsed.getJSONArray("scriptlets").length() < 50) {
                throw new IOException("内容校验失败");
            }
            writeFileAtomic(scriptletsFile, data);
            JSONObject meta = new JSONObject();
            meta.put("version", latest);
            meta.put("sha256", got);
            meta.put("source", "remote");
            meta.put("fetchedAt", System.currentTimeMillis());
            s.put("scriptlets", meta);
            return "Scriptlets 更新到 " + latest;
        } catch (Exception e) {
            return "Scriptlets 更新失败：" + e.getMessage();
        }
    }

    // ---------------- helpers ----------------

    private static byte[] get(String url, String accept) throws IOException {
        HttpURLConnection c = (HttpURLConnection) new URL(url).openConnection();
        try {
            c.setConnectTimeout(30000);
            c.setReadTimeout(60000);
            if (accept != null) c.setRequestProperty("Accept", accept);
            int code = c.getResponseCode();
            if (code != 200) throw new IOException("HTTP " + code + " " + url);
            return readAll(c.getInputStream());
        } finally {
            c.disconnect();
        }
    }

    static boolean looksLikeFilter(String text) {
        if (text.length() < 1000) return false;
        String head = text.substring(0, Math.min(2048, text.length())).toLowerCase(Locale.ROOT);
        if (head.contains("<html") || head.contains("<!doctype")) return false;
        return head.contains("! title") || head.contains("[adblock") || head.contains("! version");
    }

    static String header(String text, String prefix) {
        int n = 0;
        for (String line : text.split("\n", 60)) {
            if (++n > 50) break;
            String l = line.trim();
            if (l.startsWith(prefix)) return l.substring(prefix.length()).trim();
        }
        return null;
    }

    static Date httpDate(String s) {
        if (s == null || s.isEmpty() || "null".equals(s)) return null;
        try {
            SimpleDateFormat f = new SimpleDateFormat("EEE, dd MMM yyyy HH:mm:ss zzz", Locale.US);
            f.setTimeZone(TimeZone.getTimeZone("GMT"));
            return f.parse(s);
        } catch (Exception e) {
            return null;
        }
    }

    static int compareVersions(String a, String b) {
        String[] pa = a.split("-")[0].split("\\."), pb = b.split("-")[0].split("\\.");
        for (int i = 0; i < Math.max(pa.length, pb.length); i++) {
            int x = i < pa.length ? parseInt(pa[i]) : 0, y = i < pb.length ? parseInt(pb[i]) : 0;
            if (x != y) return x < y ? -1 : 1;
        }
        boolean preA = a.contains("-"), preB = b.contains("-");
        if (preA != preB) return preA ? -1 : 1;
        return 0;
    }

    private static int parseInt(String s) { try { return Integer.parseInt(s); } catch (Exception e) { return 0; } }

    static byte[] readAll(InputStream in) throws IOException {
        try (InputStream is = in) {
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            byte[] buf = new byte[65536];
            int n;
            while ((n = is.read(buf)) > 0) out.write(buf, 0, n);
            return out.toByteArray();
        }
    }

    static String readFile(File f) throws IOException {
        return new String(readAll(new java.io.FileInputStream(f)), StandardCharsets.UTF_8);
    }

    static void writeFileAtomic(File f, byte[] data) throws IOException {
        File parent = f.getParentFile();
        if (parent != null) //noinspection ResultOfMethodCallIgnored
            parent.mkdirs();
        File tmp = new File(f.getPath() + ".tmp");
        try (FileOutputStream out = new FileOutputStream(tmp)) {
            out.write(data);
            out.getFD().sync();
        }
        if (!tmp.renameTo(f)) throw new IOException("rename " + tmp);
    }

    static byte[] sha256(byte[] data) {
        try { return MessageDigest.getInstance("SHA-256").digest(data); } catch (Exception e) { return new byte[0]; }
    }

    static String sha256Hex(byte[] data) {
        StringBuilder sb = new StringBuilder();
        for (byte b : sha256(data)) sb.append(String.format(Locale.ROOT, "%02x", b));
        return sb.toString();
    }
}
