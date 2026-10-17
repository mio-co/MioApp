package xyz.mio.app.browser;

import java.net.URI;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * 翻译原生侧纯逻辑（不依赖 Android API，JVM 单测 TranslateCoreTest）：
 * 页面脚本（shared/translate/mio-translate.js）发来的网络请求校验（只放行翻译引擎域名 + 用户配置的 OpenAI 地址，
 * OpenAI Key 只在原生加）、Bing 页面参数正则摘取、站点规范化、LRU 缓存。与 iOS MioTranslateCore.swift / desktop translate-core.js 规则一致。
 */
public final class TranslateCore {
    private TranslateCore() {}

    public static final String[][] LANGS = {
            {"zh-CN", "简体中文"}, {"zh-TW", "繁體中文"}, {"en", "English"}, {"ja", "日本語"}, {"ko", "한국어"},
            {"fr", "Français"}, {"de", "Deutsch"}, {"es", "Español"}, {"ru", "Русский"}, {"pt", "Português"},
            {"it", "Italiano"}, {"vi", "Tiếng Việt"}, {"th", "ไทย"}, {"id", "Bahasa Indonesia"}, {"ar", "العربية"},
    };
    public static final String[][] ENGINES = {
            {"microsoft", "微软翻译（免费）"}, {"google", "谷歌翻译（免费）"}, {"openai", "自定义 OpenAI 兼容 API"},
    };
    public static final Set<String> FREE_HOSTS = Collections.unmodifiableSet(new HashSet<>(Arrays.asList(
            "www.bing.com", "bing.com", "edge.microsoft.com",
            "api-edge.cognitive.microsofttranslator.com", "api.cognitive.microsofttranslator.com",
            "translate.googleapis.com", "translate.google.com")));
    static final Set<String> ALLOWED_HEADERS = new HashSet<>(Arrays.asList("content-type", "accept", "authorization"));
    public static final int MAX_BODY = 256 * 1024;
    public static final int MAX_RESPONSE = 3 * 1024 * 1024;
    public static final String PLACEHOLDER = "'__MIO_TRANSLATE_CONFIG__'";

    public static String languageName(String code) {
        for (String[] l : LANGS) if (l[0].equals(code)) return l[1];
        return code;
    }

    public static boolean isLanguage(String code) {
        for (String[] l : LANGS) if (l[0].equals(code)) return true;
        return false;
    }

    public static boolean isEngine(String id) {
        for (String[] e : ENGINES) if (e[0].equals(id)) return true;
        return false;
    }

    public static String engineName(String id) {
        for (String[] e : ENGINES) if (e[0].equals(id)) return e[1];
        return id;
    }

    // ------------------------------------------------------------------ hosts / urls

    /** 用户输入的站点 → 规范化域名（去掉协议 / www. / 路径 / 端口）；无效返回 null */
    public static String normalizeHost(String input) {
        if (input == null) return null;
        String s = input.trim().toLowerCase(Locale.ROOT);
        if (s.isEmpty()) return null;
        if (s.contains("://")) {
            try {
                s = new URI(s).getHost();
            } catch (Exception e) {
                return null;
            }
            if (s == null || s.isEmpty()) return null;
        }
        if (s.startsWith("*.")) s = s.substring(2);
        if (s.startsWith("www.")) s = s.substring(4);
        int slash = s.indexOf('/');
        if (slash >= 0) s = s.substring(0, slash);
        int colon = s.indexOf(':');
        if (colon >= 0) s = s.substring(0, colon);
        while (s.endsWith(".")) s = s.substring(0, s.length() - 1);
        if (s.equals("localhost")) return s;
        return s.matches("[a-z0-9-]+(\\.[a-z0-9-]+)+") ? s : null;
    }

    public static boolean hostMatches(String host, String entry) {
        if (host == null) return false;
        String h = host.toLowerCase(Locale.ROOT);
        while (h.endsWith(".")) h = h.substring(0, h.length() - 1);
        String e = normalizeHost(entry);
        if (h.isEmpty() || e == null) return false;
        return h.equals(e) || h.endsWith("." + e);
    }

    public static boolean isAuto(String host, List<String> sites) {
        for (String s : sites) if (hostMatches(host, s)) return true;
        return false;
    }

    /** OpenAI 兼容地址：http(s)，去掉查询 / 片段 / 末尾斜杠；无效 = "" */
    public static String normalizeBase(String input) {
        if (input == null) return "";
        String s = input.trim();
        if (s.isEmpty()) return "";
        try {
            URI u = new URI(s);
            String scheme = u.getScheme() == null ? "" : u.getScheme().toLowerCase(Locale.ROOT);
            if (!scheme.equals("https") && !scheme.equals("http")) return "";
            if (u.getHost() == null || u.getHost().isEmpty()) return "";
            String out = scheme + "://" + u.getRawAuthority() + (u.getRawPath() == null ? "" : u.getRawPath());
            while (out.endsWith("/")) out = out.substring(0, out.length() - 1);
            return out;
        } catch (Exception e) {
            return "";
        }
    }

    public static String openaiEndpoint(String base) {
        String b = normalizeBase(base);
        if (b.isEmpty()) return "";
        return b.endsWith("/chat/completions") ? b : b + "/chat/completions";
    }

    // ------------------------------------------------------------------ request checking

    public static final class Checked {
        public String url;
        public String method;
        public final Map<String, String> headers = new LinkedHashMap<>();
        public String body;
        public int timeoutMs;
        public boolean openAIAuth;
        public List<String> picks;
        public String error;

        public boolean ok() { return error == null; }

        static Checked fail(String e) {
            Checked c = new Checked();
            c.error = e;
            return c;
        }
    }

    /**
     * 校验页面脚本发来的请求。headers 可为 null；timeoutMs ≤ 0 时默认 15 s；auth 只能是 "openai" 且只对配置的地址有效。
     */
    public static Checked check(String url, String method, Map<String, String> headers, String body, double timeoutMs,
                                String auth, List<String> picks, String openaiBase) {
        if (url == null) return Checked.fail("bad url");
        URI u;
        try {
            u = new URI(url);
        } catch (Exception e) {
            return Checked.fail("bad url");
        }
        String host = u.getHost() == null ? "" : u.getHost().toLowerCase(Locale.ROOT);
        String scheme = u.getScheme() == null ? "" : u.getScheme().toLowerCase(Locale.ROOT);
        String m = method == null ? "GET" : method.toUpperCase(Locale.ROOT);
        if (!m.equals("GET") && !m.equals("POST")) return Checked.fail("method");
        String endpoint = openaiEndpoint(openaiBase);
        int q = url.indexOf('?');
        String noQuery = q >= 0 ? url.substring(0, q) : url;
        boolean isOpenAI = !endpoint.isEmpty() && (url.equals(endpoint) || noQuery.equals(endpoint));
        if (!isOpenAI && !(scheme.equals("https") && FREE_HOSTS.contains(host))) return Checked.fail("host not allowed");
        if (auth != null && !(auth.equals("openai") && isOpenAI)) return Checked.fail("auth not allowed");
        if (body != null && body.length() > MAX_BODY) return Checked.fail("body too large");
        if (body != null && m.equals("GET")) return Checked.fail("GET with body");
        Checked c = new Checked();
        c.url = url;
        c.method = m;
        c.body = body;
        if (headers != null) {
            for (Map.Entry<String, String> e : headers.entrySet()) {
                String k = e.getKey() == null ? "" : e.getKey().toLowerCase(Locale.ROOT);
                if (!ALLOWED_HEADERS.contains(k)) continue;
                if (k.equals("authorization") && !host.endsWith("cognitive.microsofttranslator.com")) continue;
                String v = e.getValue() == null ? "" : e.getValue();
                c.headers.put(k, v.length() > 4096 ? v.substring(0, 4096) : v);
            }
        }
        double ms = timeoutMs > 0 ? timeoutMs : 15000;
        c.timeoutMs = (int) Math.max(1000, Math.min(ms, 90000));
        c.openAIAuth = isOpenAI && "openai".equals(auth);
        if (picks != null) c.picks = new ArrayList<>(picks.subList(0, Math.min(8, picks.size())));
        return c;
    }

    /** 对响应文本跑正则，返回每个正则的捕获组（没匹配 = null） */
    public static List<List<String>> runPicks(String text, List<String> patterns) {
        List<List<String>> out = new ArrayList<>();
        for (String p : patterns) {
            try {
                Matcher m = Pattern.compile(p).matcher(text);
                if (!m.find()) { out.add(null); continue; }
                List<String> g = new ArrayList<>();
                for (int i = 1; i <= m.groupCount(); i++) g.add(m.group(i) == null ? "" : m.group(i));
                out.add(g);
            } catch (Exception e) {
                out.add(null);
            }
        }
        return out;
    }

    /** 把 base64 配置填进脚本模板；没有占位符返回 null */
    public static String script(String template, String configBase64) {
        if (template == null || !template.contains(PLACEHOLDER)) return null;
        int i = template.indexOf(PLACEHOLDER);
        return template.substring(0, i) + "'" + configBase64 + "'" + template.substring(i + PLACEHOLDER.length());
    }

    // ------------------------------------------------------------------ LRU cache

    /** 访问顺序的 LRU（LinkedHashMap accessOrder） */
    public static final class Lru extends LinkedHashMap<String, String> {
        private final int limit;

        public Lru(int limit) {
            super(256, 0.75f, true);
            this.limit = Math.max(1, limit);
        }

        @Override
        protected boolean removeEldestEntry(Map.Entry<String, String> eldest) {
            return size() > limit;
        }

        public synchronized void putChecked(String k, String v) {
            if (k == null || v == null || k.length() > 200 || v.length() > 20000) return;
            put(k, v);
        }

        public synchronized String getTouch(String k) { return get(k); }
    }
}
