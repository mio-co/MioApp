package xyz.mio.app.update;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.IOException;
import java.io.InputStream;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * 软件内更新的纯逻辑（不依赖 Android 框架，本地 JUnit 测）：版本比较、GitHub Release 解析、sha256 清单 / 校验、检查节奏。
 * 与 Electron（desktop/src/update-core.js）、iOS / Mac（MioUpdateCore.swift）同一套规则。
 */
public final class UpdateLogic {
    private UpdateLogic() {}

    public static final String REPO = "mio-co/MioApp";
    public static final String LATEST_API = "https://api.github.com/repos/" + REPO + "/releases/latest";
    public static final String RELEASES_PAGE = "https://github.com/" + REPO + "/releases/latest";
    /** CI 之后由本地固定 keystore 签名再上传的安装包（mioapp-keys/sign-and-upload.sh），以及它的 sha256 */
    public static final String APK_ASSET = "Mio.apk";
    public static final String APK_SHA_ASSET = "Mio.apk.sha256";
    public static final String SUMS_ASSET = "SHA256SUMS.txt";
    public static final long CHECK_INTERVAL_MS = 24L * 3600 * 1000;
    public static final long RETRY_INTERVAL_MS = 3600L * 1000;

    // ---- versions ----

    private static final Pattern VERSION = Pattern.compile("^\\s*[vV]?(\\d+(?:\\.\\d+){0,3})(?:-([0-9A-Za-z.-]+))?(?:\\+[0-9A-Za-z.-]+)?\\s*$");

    /** 不合法返回 null；否则 [core..., pre...] 拆成两部分 */
    static Object[] parseVersion(String s) {
        if (s == null) return null;
        Matcher m = VERSION.matcher(s);
        if (!m.matches()) return null;
        String[] c = m.group(1).split("\\.");
        long[] core = new long[Math.max(3, c.length)];
        for (int i = 0; i < c.length; i++) {
            try { core[i] = Long.parseLong(c[i]); } catch (NumberFormatException e) { return null; }
        }
        String[] pre = m.group(2) == null ? new String[0] : m.group(2).split("\\.");
        return new Object[]{core, pre};
    }

    /** semver 比较：-1 / 0 / 1；任一不合法返回 null */
    public static Integer compareVersions(String a, String b) {
        Object[] x = parseVersion(a), y = parseVersion(b);
        if (x == null || y == null) return null;
        long[] xc = (long[]) x[0], yc = (long[]) y[0];
        for (int i = 0; i < Math.max(xc.length, yc.length); i++) {
            long p = i < xc.length ? xc[i] : 0, q = i < yc.length ? yc[i] : 0;
            if (p != q) return p < q ? -1 : 1;
        }
        String[] xp = (String[]) x[1], yp = (String[]) y[1];
        if (xp.length == 0 && yp.length == 0) return 0;
        if (xp.length == 0) return 1;
        if (yp.length == 0) return -1;
        for (int i = 0; i < Math.max(xp.length, yp.length); i++) {
            if (i >= xp.length) return -1;
            if (i >= yp.length) return 1;
            String p = xp[i], q = yp[i];
            if (p.equals(q)) continue;
            boolean pn = p.matches("\\d+"), qn = q.matches("\\d+");
            if (pn && qn) {
                int c = Long.compare(Long.parseLong(p), Long.parseLong(q));
                if (c != 0) return c < 0 ? -1 : 1;
                continue;
            }
            if (pn) return -1;
            if (qn) return 1;
            int c = p.compareTo(q);
            return c < 0 ? -1 : 1;
        }
        return 0;
    }

    public static boolean isNewer(String remote, String current) {
        Integer c = compareVersions(remote, current);
        return c != null && c > 0;
    }

    // ---- release ----

    public static final class Asset {
        public final String name, url, digest;
        public final long size;
        Asset(String name, String url, long size, String digest) { this.name = name; this.url = url; this.size = size; this.digest = digest; }
    }

    public static final class Release {
        public final String tag, version, name, notes, url;
        public final List<Asset> assets;
        Release(String tag, String version, String name, String notes, String url, List<Asset> assets) {
            this.tag = tag; this.version = version; this.name = name; this.notes = notes; this.url = url; this.assets = assets;
        }

        public Asset asset(String name) {
            for (Asset a : assets) if (a.name.equals(name)) return a;
            return null;
        }
    }

    /** GitHub releases/latest JSON → Release；草稿 / 预发布 / tag 不是版本号 → null */
    public static Release parseRelease(String json) throws Exception {
        JSONObject r = new JSONObject(json);
        if (r.optBoolean("draft") || r.optBoolean("prerelease")) return null;
        String tag = r.optString("tag_name", "");
        if (parseVersion(tag) == null) return null;
        String version = tag.replaceFirst("^[vV]", "");
        String html = r.optString("html_url", "");
        if (!html.startsWith("https://github.com/")) html = RELEASES_PAGE;
        List<Asset> assets = new ArrayList<>();
        JSONArray a = r.optJSONArray("assets");
        if (a != null) {
            for (int i = 0; i < a.length(); i++) {
                JSONObject o = a.optJSONObject(i);
                if (o == null || !(o.opt("name") instanceof String)) continue;
                String url = o.optString("browser_download_url", "");
                if (!url.startsWith("https://")) continue;
                String digest = o.isNull("digest") ? null : o.optString("digest", null);
                assets.add(new Asset(o.getString("name"), url, o.optLong("size", 0), digest));
            }
        }
        String name = r.optString("name", "");
        String body = r.isNull("body") ? "" : r.optString("body", "");
        return new Release(tag, version, name.isEmpty() ? tag : name, body, html, assets);
    }

    // ---- sha256 ----

    private static final Pattern SUM_LINE = Pattern.compile("^([0-9a-fA-F]{64}) [ *](.+)$");
    private static final Pattern BSD_LINE = Pattern.compile("^SHA256 \\((.+)\\) = ([0-9a-fA-F]{64})$");
    private static final Pattern HEX64 = Pattern.compile("^[0-9a-fA-F]{64}$");

    /** sha256sum / BSD 格式 → name → hex；只有一行哈希时 key 为 "" */
    public static Map<String, String> parseSha256Sums(String text) {
        Map<String, String> out = new HashMap<>();
        if (text == null) return out;
        for (String raw : text.split("\\r?\\n")) {
            String line = raw.trim();
            if (line.isEmpty() || line.startsWith("#")) continue;
            Matcher m = SUM_LINE.matcher(line);
            if (m.matches()) { out.put(m.group(2).trim(), m.group(1).toLowerCase(Locale.ROOT)); continue; }
            m = BSD_LINE.matcher(line);
            if (m.matches()) { out.put(m.group(1), m.group(2).toLowerCase(Locale.ROOT)); continue; }
            if (HEX64.matcher(line).matches()) out.put("", line.toLowerCase(Locale.ROOT));
        }
        return out;
    }

    /**
     * 期望的 sha256：清单（Mio.apk.sha256 / SHA256SUMS.txt）+ GitHub 资产 digest（"sha256:hex"），
     * 两边都有时必须一致；都没有时抛异常（不安装未校验的文件）。
     */
    public static String expectedSha256(Asset asset, Map<String, String> sums) {
        String fromSums = null;
        if (sums != null) {
            fromSums = sums.get(asset.name);
            if (fromSums == null) fromSums = sums.get("");
        }
        String fromDigest = null;
        if (asset.digest != null && asset.digest.startsWith("sha256:") && HEX64.matcher(asset.digest.substring(7)).matches()) {
            fromDigest = asset.digest.substring(7).toLowerCase(Locale.ROOT);
        }
        if (fromSums != null && fromDigest != null && !fromSums.equals(fromDigest)) {
            throw new IllegalStateException(asset.name + " 的 SHA-256 清单与 GitHub 记录不一致");
        }
        String v = fromSums != null ? fromSums : fromDigest;
        if (v == null) throw new IllegalStateException(asset.name + " 没有 SHA-256 校验值");
        return v;
    }

    public static String hex(byte[] b) {
        StringBuilder sb = new StringBuilder(b.length * 2);
        for (byte x : b) sb.append(String.format(Locale.ROOT, "%02x", x));
        return sb.toString();
    }

    public static String sha256Hex(InputStream in) throws IOException {
        try {
            MessageDigest md = MessageDigest.getInstance("SHA-256");
            byte[] buf = new byte[64 * 1024];
            int n;
            while ((n = in.read(buf)) > 0) md.update(buf, 0, n);
            return hex(md.digest());
        } catch (java.security.NoSuchAlgorithmException e) {
            throw new IOException(e);
        }
    }

    public static boolean sha256Matches(String actualHex, String expectedHex) {
        return actualHex != null && expectedHex != null && actualHex.equalsIgnoreCase(expectedHex.trim());
    }

    /** 签名证书比较：新 APK 的每个签名证书都必须在当前应用的证书（含轮换历史）里 */
    public static boolean signersMatch(List<String> currentCerts, List<String> apkCerts) {
        if (currentCerts == null || apkCerts == null || currentCerts.isEmpty() || apkCerts.isEmpty()) return false;
        for (String c : apkCerts) {
            boolean found = false;
            for (String d : currentCerts) if (d.equalsIgnoreCase(c)) { found = true; break; }
            if (!found) return false;
        }
        return true;
    }

    // ---- schedule ----

    public static boolean shouldAutoCheck(boolean enabled, long lastCheck, long lastAttempt, long now) {
        if (!enabled) return false;
        if (lastAttempt <= now && now - lastAttempt < RETRY_INTERVAL_MS) return false;
        return lastCheck > now || now - lastCheck >= CHECK_INTERVAL_MS;
    }

    /** 发布说明（Markdown）→ 对话框纯文本 */
    public static String plainNotes(String md, int maxLen) {
        String t = md == null ? "" : md.replace("\r\n", "\n");
        t = t.replaceAll("(?s)```.*?```", "")
                .replaceAll("(?m)^#{1,6}\\s*", "")
                .replaceAll("\\*\\*([^*]+)\\*\\*", "$1")
                .replaceAll("`([^`]+)`", "$1")
                .replaceAll("\\[([^\\]]+)\\]\\(([^)]+)\\)", "$1")
                .replaceAll("\\n{3,}", "\n\n")
                .trim();
        if (t.length() > maxLen) t = t.substring(0, maxLen - 1) + "…";
        return t;
    }
}
