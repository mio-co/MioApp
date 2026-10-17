package xyz.mio.app.browser;

import android.content.Context;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.Base64;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.security.KeyStore;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.TreeSet;

import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

/**
 * 翻译设置（files/mio-translate-prefs.json，每次读盘：:browser 进程和主进程都能看到最新值）。
 * OpenAI 兼容 API 的 Key 用 Android Keystore 里的 AES-GCM 密钥加密后保存（密钥不可导出；
 * 与 EncryptedSharedPreferences 同样的保护方式，不额外引入已停止维护的 security-crypto 依赖）。
 */
public final class TranslatePrefs {
    private TranslatePrefs() {}

    private static final String KEY_ALIAS = "mio.translate.openai";

    private static File file(Context c) { return new File(c.getFilesDir(), "mio-translate-prefs.json"); }

    private static synchronized JSONObject read(Context c) {
        try {
            File f = file(c);
            if (f.exists()) {
                try (FileInputStream in = new FileInputStream(f)) {
                    ByteArrayOutputStream out = new ByteArrayOutputStream();
                    byte[] buf = new byte[8192];
                    int n;
                    while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
                    return new JSONObject(new String(out.toByteArray(), StandardCharsets.UTF_8));
                }
            }
        } catch (Exception ignored) {}
        return new JSONObject();
    }

    private static synchronized void write(Context c, JSONObject o) {
        try {
            File f = file(c);
            File tmp = new File(f.getPath() + ".tmp");
            byte[] data = o.toString().getBytes(StandardCharsets.UTF_8);
            try (FileOutputStream out = new FileOutputStream(tmp)) { out.write(data); }
            if (!tmp.renameTo(f)) {
                try (FileOutputStream out = new FileOutputStream(f)) { out.write(data); }
                //noinspection ResultOfMethodCallIgnored
                tmp.delete();
            }
        } catch (Exception ignored) {}
    }

    private static void put(Context c, String k, Object v) {
        JSONObject o = read(c);
        try { o.put(k, v); } catch (Exception ignored) {}
        write(c, o);
    }

    public static String target(Context c) {
        String v = read(c).optString("target", "zh-CN");
        return TranslateCore.isLanguage(v) ? v : "zh-CN";
    }

    public static void setTarget(Context c, String v) { if (TranslateCore.isLanguage(v)) put(c, "target", v); }

    public static String engine(Context c) {
        String v = read(c).optString("engine", "microsoft");
        return TranslateCore.isEngine(v) ? v : "microsoft";
    }

    public static void setEngine(Context c, String v) { if (TranslateCore.isEngine(v)) put(c, "engine", v); }

    public static String display(Context c) { return "translation".equals(read(c).optString("display")) ? "translation" : "bilingual"; }

    public static void setDisplay(Context c, String v) { put(c, "display", "translation".equals(v) ? "translation" : "bilingual"); }

    public static boolean selection(Context c) { return read(c).optBoolean("selection", true); }

    public static void setSelection(Context c, boolean v) { put(c, "selection", v); }

    public static boolean youtube(Context c) { return read(c).optBoolean("youtube", true); }

    public static void setYoutube(Context c, boolean v) { put(c, "youtube", v); }

    public static boolean ytSubs(Context c) { return read(c).optBoolean("ytSubs", true); }

    public static void setYtSubs(Context c, boolean v) { put(c, "ytSubs", v); }

    public static String openaiBase(Context c) { return read(c).optString("openaiBase", ""); }

    public static void setOpenaiBase(Context c, String v) { put(c, "openaiBase", TranslateCore.normalizeBase(v)); }

    public static String openaiModel(Context c) { return read(c).optString("openaiModel", ""); }

    public static void setOpenaiModel(Context c, String v) { put(c, "openaiModel", v == null ? "" : v.trim()); }

    public static String openaiPrompt(Context c) { return read(c).optString("openaiPrompt", ""); }

    public static void setOpenaiPrompt(Context c, String v) {
        String s = v == null ? "" : v;
        put(c, "openaiPrompt", s.length() > 2000 ? s.substring(0, 2000) : s);
    }

    public static List<String> autoSites(Context c) {
        JSONArray a = read(c).optJSONArray("autoSites");
        List<String> out = new ArrayList<>();
        if (a != null) for (int i = 0; i < a.length(); i++) {
            String h = TranslateCore.normalizeHost(a.optString(i));
            if (h != null && !out.contains(h)) out.add(h);
        }
        Collections.sort(out);
        return out;
    }

    public static void setAutoSites(Context c, List<String> sites) {
        TreeSet<String> set = new TreeSet<>();
        for (String s : sites) {
            String h = TranslateCore.normalizeHost(s);
            if (h != null) set.add(h);
        }
        put(c, "autoSites", new JSONArray(set));
    }

    public static void setAuto(Context c, String host, boolean on) {
        String h = TranslateCore.normalizeHost(host);
        if (h == null) return;
        List<String> list = autoSites(c);
        if (on) {
            if (!list.contains(h)) list.add(h);
        } else {
            List<String> keep = new ArrayList<>();
            for (String e : list) if (!e.equals(h) && !TranslateCore.hostMatches(host, e)) keep.add(e);
            list = keep;
        }
        setAutoSites(c, list);
    }

    public static boolean isAuto(Context c, String host) { return TranslateCore.isAuto(host, autoSites(c)); }

    // ------------------------------------------------------------------ API Key（Keystore AES-GCM）

    private static SecretKey secretKey() throws Exception {
        KeyStore ks = KeyStore.getInstance("AndroidKeyStore");
        ks.load(null);
        if (ks.containsAlias(KEY_ALIAS)) {
            return ((KeyStore.SecretKeyEntry) ks.getEntry(KEY_ALIAS, null)).getSecretKey();
        }
        KeyGenerator g = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore");
        g.init(new KeyGenParameterSpec.Builder(KEY_ALIAS, KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build());
        return g.generateKey();
    }

    public static boolean hasKey(Context c) { return !read(c).optString("openaiKeyEnc", "").isEmpty(); }

    /** 保存 Key（空 = 删除）；返回是否成功 */
    public static boolean setKey(Context c, String key) {
        String k = key == null ? "" : key.trim();
        if (k.isEmpty()) {
            put(c, "openaiKeyEnc", "");
            return true;
        }
        try {
            Cipher ci = Cipher.getInstance("AES/GCM/NoPadding");
            ci.init(Cipher.ENCRYPT_MODE, secretKey());
            byte[] ct = ci.doFinal(k.getBytes(StandardCharsets.UTF_8));
            String enc = Base64.encodeToString(ci.getIV(), Base64.NO_WRAP) + ":" + Base64.encodeToString(ct, Base64.NO_WRAP);
            put(c, "openaiKeyEnc", enc);
            return true;
        } catch (Exception e) {
            android.util.Log.w("MioTranslate", "keystore encrypt failed", e);
            return false;
        }
    }

    public static String key(Context c) {
        String enc = read(c).optString("openaiKeyEnc", "");
        int i = enc.indexOf(':');
        if (i <= 0) return null;
        try {
            byte[] iv = Base64.decode(enc.substring(0, i), Base64.NO_WRAP);
            byte[] ct = Base64.decode(enc.substring(i + 1), Base64.NO_WRAP);
            Cipher ci = Cipher.getInstance("AES/GCM/NoPadding");
            ci.init(Cipher.DECRYPT_MODE, secretKey(), new GCMParameterSpec(128, iv));
            return new String(ci.doFinal(ct), StandardCharsets.UTF_8);
        } catch (Exception e) {
            return null;
        }
    }

    public static boolean openaiReady(Context c) {
        return !openaiBase(c).isEmpty() && !openaiModel(c).isEmpty() && hasKey(c);
    }

    /** 注入脚本用的配置（不含 Key），base64(JSON) */
    public static String configBase64(Context c, String token) {
        JSONObject o = new JSONObject();
        try {
            o.put("v", 1);
            o.put("token", token);
            o.put("platform", "android");
            o.put("target", target(c));
            o.put("engine", engine(c));
            o.put("display", display(c));
            o.put("autoSites", new JSONArray(autoSites(c)));
            o.put("selection", selection(c));
            o.put("youtube", youtube(c));
            o.put("ytSubs", ytSubs(c));
            JSONObject ai = new JSONObject();
            ai.put("base", openaiBase(c));
            ai.put("model", openaiModel(c));
            ai.put("prompt", openaiPrompt(c));
            ai.put("ready", openaiReady(c));
            o.put("openai", ai);
        } catch (Exception ignored) {}
        return Base64.encodeToString(o.toString().getBytes(StandardCharsets.UTF_8), Base64.NO_WRAP);
    }
}
