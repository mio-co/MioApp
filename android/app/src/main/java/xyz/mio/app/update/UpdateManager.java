package xyz.mio.app.update;

import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageInfo;
import android.content.pm.PackageInstaller;
import android.content.pm.PackageManager;
import android.content.pm.Signature;
import android.content.pm.SigningInfo;
import android.net.Uri;
import android.os.Build;

import androidx.core.content.FileProvider;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/**
 * 软件内更新：查 GitHub Releases latest → 下载 Mio.apk 到应用私有目录 → 校验 sha256 → 校验签名证书与当前应用一致 →
 * PackageInstaller 安装（需要「安装未知应用」授权；失败时退回 FileProvider + ACTION_VIEW）。
 * 所有网络 / IO 方法都是阻塞的，由 UpdateUi 放在后台线程调用。
 */
public final class UpdateManager {
    private UpdateManager() {}

    public static final String ACTION_INSTALL_STATUS = "xyz.mio.app.update.INSTALL_STATUS";

    public interface Progress { void onProgress(long done, long total); boolean cancelled(); }

    public static String currentVersion(Context c) {
        try {
            String v = c.getPackageManager().getPackageInfo(c.getPackageName(), 0).versionName;
            return v == null ? "0" : v;
        } catch (Exception e) {
            return "0";
        }
    }

    @SuppressWarnings("deprecation")
    static long versionCode(PackageInfo p) {
        return Build.VERSION.SDK_INT >= 28 ? p.getLongVersionCode() : p.versionCode;
    }

    private static HttpURLConnection open(Context c, String url, String accept) throws IOException {
        HttpURLConnection conn = (HttpURLConnection) new URL(url).openConnection();
        conn.setConnectTimeout(15000);
        conn.setReadTimeout(60000);
        conn.setInstanceFollowRedirects(true);
        conn.setRequestProperty("User-Agent", "Mio-Android/" + currentVersion(c));
        conn.setRequestProperty("Accept", accept);
        conn.setUseCaches(false);
        return conn;
    }

    private static String getText(Context c, String url, String accept, int maxBytes) throws IOException {
        HttpURLConnection conn = open(c, url, accept);
        try {
            int code = conn.getResponseCode();
            if (code == 404) return null;
            if (code / 100 != 2) throw new IOException("HTTP " + code);
            try (InputStream in = conn.getInputStream()) {
                ByteArrayOutputStream out = new ByteArrayOutputStream();
                byte[] buf = new byte[8192];
                int n;
                while ((n = in.read(buf)) > 0) {
                    out.write(buf, 0, n);
                    if (out.size() > maxBytes) throw new IOException("response too large");
                }
                return new String(out.toByteArray(), StandardCharsets.UTF_8);
            }
        } finally {
            conn.disconnect();
        }
    }

    /** null = 仓库还没有正式 Release */
    public static UpdateLogic.Release fetchLatest(Context c) throws Exception {
        String json = getText(c, UpdateLogic.LATEST_API, "application/vnd.github+json", 2 * 1024 * 1024);
        return json == null ? null : UpdateLogic.parseRelease(json);
    }

    /** Mio.apk 的期望 sha256：Mio.apk.sha256（签名脚本上传）优先，其次 SHA256SUMS.txt，再加 GitHub 资产 digest 交叉校验 */
    static String expectedApkSha256(Context c, UpdateLogic.Release r, UpdateLogic.Asset apk) throws Exception {
        Map<String, String> sums = null;
        for (String name : new String[]{UpdateLogic.APK_SHA_ASSET, UpdateLogic.SUMS_ASSET}) {
            UpdateLogic.Asset a = r.asset(name);
            if (a == null) continue;
            String text = getText(c, a.url, "application/octet-stream", 256 * 1024);
            Map<String, String> m = UpdateLogic.parseSha256Sums(text);
            if (m.containsKey(apk.name) || (name.equals(UpdateLogic.APK_SHA_ASSET) && m.containsKey(""))) { sums = m; break; }
        }
        return UpdateLogic.expectedSha256(apk, sums);
    }

    static File updatesDir(Context c) {
        File d = new File(c.getFilesDir(), "updates");
        //noinspection ResultOfMethodCallIgnored
        d.mkdirs();
        return d;
    }

    /** 下载并校验；返回校验通过的 APK（应用私有目录 files/updates/） */
    public static File download(Context c, UpdateLogic.Release r, Progress progress) throws Exception {
        UpdateLogic.Asset apk = r.asset(UpdateLogic.APK_ASSET);
        if (apk == null) throw new IllegalStateException("Release " + r.tag + " 里还没有签名安装包 Mio.apk");
        String expected = expectedApkSha256(c, r, apk);
        File dir = updatesDir(c);
        File out = new File(dir, "Mio-" + r.version.replaceAll("[^0-9A-Za-z.-]", "_") + ".apk");
        // 清理旧版本的安装包
        File[] old = dir.listFiles();
        if (old != null) for (File f : old) if (!f.getName().equals(out.getName())) //noinspection ResultOfMethodCallIgnored
            f.delete();
        if (out.exists()) {
            try (InputStream in = new FileInputStream(out)) {
                if (UpdateLogic.sha256Matches(UpdateLogic.sha256Hex(in), expected)) return out;
            }
            //noinspection ResultOfMethodCallIgnored
            out.delete();
        }
        File part = new File(dir, out.getName() + ".part");
        HttpURLConnection conn = open(c, apk.url, "application/octet-stream");
        String actual;
        try {
            int code = conn.getResponseCode();
            if (code / 100 != 2) throw new IOException("下载失败：HTTP " + code);
            long total = conn.getContentLengthLong() > 0 ? conn.getContentLengthLong() : apk.size;
            MessageDigest md = MessageDigest.getInstance("SHA-256");
            try (InputStream in = conn.getInputStream(); OutputStream os = new FileOutputStream(part)) {
                byte[] buf = new byte[64 * 1024];
                long done = 0;
                int n;
                while ((n = in.read(buf)) > 0) {
                    if (progress != null && progress.cancelled()) throw new InterruptedException("已取消");
                    os.write(buf, 0, n);
                    md.update(buf, 0, n);
                    done += n;
                    if (progress != null) progress.onProgress(done, total);
                }
            }
            actual = UpdateLogic.hex(md.digest());
        } catch (Exception e) {
            //noinspection ResultOfMethodCallIgnored
            part.delete();
            throw e;
        } finally {
            conn.disconnect();
        }
        if (apk.size > 0 && part.length() != apk.size) {
            //noinspection ResultOfMethodCallIgnored
            part.delete();
            throw new IOException("下载的文件大小不对（" + part.length() + " / " + apk.size + "）");
        }
        if (!UpdateLogic.sha256Matches(actual, expected)) {
            //noinspection ResultOfMethodCallIgnored
            part.delete();
            throw new SecurityException("SHA-256 校验失败，已删除下载的文件");
        }
        if (!part.renameTo(out)) throw new IOException("无法保存安装包");
        return out;
    }

    static List<String> certDigests(Signature[] sigs) throws Exception {
        List<String> out = new ArrayList<>();
        if (sigs == null) return out;
        for (Signature s : sigs) {
            MessageDigest md = MessageDigest.getInstance("SHA-256");
            out.add(UpdateLogic.hex(md.digest(s.toByteArray())));
        }
        return out;
    }

    @SuppressWarnings("deprecation")
    static List<String> signers(PackageInfo p) throws Exception {
        if (p == null) return new ArrayList<>();
        if (Build.VERSION.SDK_INT >= 28 && p.signingInfo != null) {
            SigningInfo si = p.signingInfo;
            Signature[] s = si.hasMultipleSigners() ? si.getApkContentsSigners() : si.getSigningCertificateHistory();
            return certDigests(s);
        }
        return certDigests(p.signatures);
    }

    @SuppressWarnings("deprecation")
    static PackageInfo archiveInfo(PackageManager pm, File apk) {
        PackageInfo info = null;
        if (Build.VERSION.SDK_INT >= 28) info = pm.getPackageArchiveInfo(apk.getPath(), PackageManager.GET_SIGNING_CERTIFICATES);
        if (info == null || (Build.VERSION.SDK_INT >= 28 && info.signingInfo == null)) {
            PackageInfo legacy = pm.getPackageArchiveInfo(apk.getPath(), PackageManager.GET_SIGNATURES);
            if (legacy != null) info = legacy;
        }
        return info;
    }

    /** 安装前检查：包名一致、版本号不回退、签名证书与当前安装的应用一致。不通过抛 SecurityException */
    @SuppressWarnings("deprecation")
    public static void verifyApk(Context c, File apk) throws Exception {
        PackageManager pm = c.getPackageManager();
        PackageInfo info = archiveInfo(pm, apk);
        if (info == null) throw new SecurityException("无法解析下载的安装包");
        if (!c.getPackageName().equals(info.packageName)) throw new SecurityException("安装包的包名不对：" + info.packageName);
        PackageInfo cur = Build.VERSION.SDK_INT >= 28
                ? pm.getPackageInfo(c.getPackageName(), PackageManager.GET_SIGNING_CERTIFICATES)
                : pm.getPackageInfo(c.getPackageName(), PackageManager.GET_SIGNATURES);
        if (versionCode(info) < versionCode(cur)) throw new SecurityException("安装包版本号比当前低，不能降级安装");
        if (!UpdateLogic.signersMatch(signers(cur), signers(info))) {
            throw new SignatureMismatchException();
        }
    }

    public static final class SignatureMismatchException extends SecurityException {
        SignatureMismatchException() {
            super("新安装包的签名证书与当前应用不一致（当前安装的可能是调试版或其他来源的包），无法覆盖安装");
        }
    }

    public static boolean canInstall(Context c) {
        return Build.VERSION.SDK_INT < 26 || c.getPackageManager().canRequestPackageInstalls();
    }

    public static Intent unknownSourcesSettings(Context c) {
        return new Intent(android.provider.Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:" + c.getPackageName()));
    }

    /** PackageInstaller 会话安装；结果（含需要用户确认）发到 UpdateInstallReceiver */
    public static void install(Context c, File apk) throws Exception {
        PackageInstaller pi = c.getPackageManager().getPackageInstaller();
        PackageInstaller.SessionParams params = new PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL);
        params.setAppPackageName(c.getPackageName());
        params.setSize(apk.length());
        int id = pi.createSession(params);
        try (PackageInstaller.Session s = pi.openSession(id)) {
            try (InputStream in = new FileInputStream(apk); OutputStream out = s.openWrite("Mio.apk", 0, apk.length())) {
                byte[] buf = new byte[64 * 1024];
                int n;
                while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
                s.fsync(out);
            }
            Intent i = new Intent(c, UpdateInstallReceiver.class).setAction(ACTION_INSTALL_STATUS);
            int flags = PendingIntent.FLAG_UPDATE_CURRENT | (Build.VERSION.SDK_INT >= 31 ? PendingIntent.FLAG_MUTABLE : 0);
            PendingIntent p = PendingIntent.getBroadcast(c, id, i, flags);
            s.commit(p.getIntentSender());
        } catch (Exception e) {
            try { pi.abandonSession(id); } catch (Exception ignored) {}
            throw e;
        }
    }

    /** 兜底：交给系统安装器（FileProvider content:// URI） */
    @SuppressWarnings("deprecation")
    public static Intent viewIntent(Context c, File apk) {
        Uri uri = FileProvider.getUriForFile(c, c.getPackageName() + ".fileprovider", apk);
        Intent i = new Intent(Intent.ACTION_INSTALL_PACKAGE, uri);
        i.setDataAndType(uri, "application/vnd.android.package-archive");
        i.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_ACTIVITY_NEW_TASK);
        return i;
    }
}
