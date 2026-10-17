package xyz.mio.app.browser;

import org.json.JSONArray;
import org.json.JSONObject;

import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.regex.Pattern;

/**
 * 用户脚本管理器纯逻辑（Android），与 iOS 的 MioUserScriptCore.swift / Windows 的 desktop/src/userscript-core.js 一一对应：
 * 元数据解析、@match / @include 编译成正则源码（与 Swift 逐字一致，单测用 tools/MioAppTests/js/fixtures/userscript-rules.json 校验）、
 * 版本比较、@connect 判定、安装地址、注入代码生成（运行时 assets/mio-userscript-runtime.js 由 scripts/sync-userscript-runtime.mjs 生成）。
 * 不依赖 Android API（org.json 除外），可在 JVM 单测里跑。
 */
public final class UserScriptCore {
    private UserScriptCore() {}

    public static final int MAX_SCRIPT_BYTES = 5 * 1024 * 1024;
    public static final int MAX_VALUE_BYTES = 5 * 1024 * 1024;
    static final String TLD_RE = "\\.(?:[a-z0-9-]{2,63}|(?:com?|net|org|gov|edu|ac|ne|or|go)\\.[a-z]{2})";

    public static final class ParseException extends Exception {
        public ParseException(String m) { super(m); }
    }

    // ---------------------------------------------------------------- 元数据

    public static final class Meta {
        public String name = "";
        public final Map<String, String> localizedNames = new LinkedHashMap<>();
        public String namespace = "", version = "", description = "", author = "";
        public final List<String> matches = new ArrayList<>(), includes = new ArrayList<>(), excludes = new ArrayList<>(), excludeMatches = new ArrayList<>();
        public String runAt = "document-idle";
        public final List<String> grants = new ArrayList<>(), requires = new ArrayList<>(), connects = new ArrayList<>();
        public final Map<String, String> resources = new LinkedHashMap<>();
        public boolean noframes;
        public String updateURL, downloadURL, homepage, icon;
        public String header = "";

        public boolean grantsNone() {
            boolean any = false;
            for (String g : grants) {
                if (g.isEmpty()) continue;
                any = true;
                if (g.equals("none")) return true;
            }
            return !any;
        }

        public String displayName() {
            for (String k : new String[]{"zh-CN", "zh-Hans", "zh-cn", "zh"}) {
                String n = localizedNames.get(k);
                if (n != null && !n.isEmpty()) return n;
            }
            return name;
        }

        public String identity() { return namespace + "\u001f" + name; }

        public JSONObject toJson() {
            JSONObject o = new JSONObject();
            try {
                o.put("name", name).put("localizedNames", new JSONObject(localizedNames)).put("namespace", namespace).put("version", version)
                        .put("description", description).put("author", author).put("matches", new JSONArray(matches)).put("includes", new JSONArray(includes))
                        .put("excludes", new JSONArray(excludes)).put("excludeMatches", new JSONArray(excludeMatches)).put("runAt", runAt)
                        .put("grants", new JSONArray(grants)).put("requires", new JSONArray(requires)).put("connects", new JSONArray(connects))
                        .put("resources", new JSONObject(resources)).put("noframes", noframes).put("header", header);
                if (updateURL != null) o.put("updateURL", updateURL);
                if (downloadURL != null) o.put("downloadURL", downloadURL);
                if (homepage != null) o.put("homepage", homepage);
                if (icon != null) o.put("icon", icon);
            } catch (Exception ignored) {}
            return o;
        }
    }

    static String runAtOf(String v) {
        String s = v == null ? "" : v.trim().toLowerCase(Locale.ROOT);
        if (s.equals("document-start")) return "document-start";
        if (s.equals("document-end") || s.equals("document-body")) return "document-end";
        return "document-idle";
    }

    private static boolean isMarker(String line, String marker) {
        return line.startsWith("//") && line.substring(2).trim().startsWith(marker);
    }

    public static Meta parse(String code) throws ParseException {
        int bytes = code.getBytes(StandardCharsets.UTF_8).length;
        if (bytes > MAX_SCRIPT_BYTES) throw new ParseException("文件太大（" + (bytes / 1024) + " KB）");
        Meta m = new Meta();
        boolean inBlock = false, found = false, sawName = false;
        StringBuilder header = new StringBuilder();
        for (String raw : code.split("\r\n|\r|\n", -1)) {
            String line = raw.trim();
            if (!inBlock) {
                if (isMarker(line, "==UserScript==")) { inBlock = true; header.append(raw); }
                continue;
            }
            header.append('\n').append(raw);
            if (isMarker(line, "==/UserScript==")) { found = true; break; }
            if (!line.startsWith("//")) continue;
            String body = line.substring(2).trim();
            if (!body.startsWith("@")) continue;
            String rest = body.substring(1);
            int ws = -1;
            for (int i = 0; i < rest.length(); i++) {
                char c = rest.charAt(i);
                if (c == ' ' || c == '\t') { ws = i; break; }
            }
            String rawKey = ws < 0 ? rest : rest.substring(0, ws);
            String value = ws < 0 ? "" : rest.substring(ws).trim();
            int ci = rawKey.indexOf(':');
            String key = (ci < 0 ? rawKey : rawKey.substring(0, ci)).toLowerCase(Locale.ROOT);
            String locale = ci < 0 ? null : rawKey.substring(ci + 1);
            switch (key) {
                case "name":
                    if (locale != null) m.localizedNames.put(locale, value); else { m.name = value; sawName = true; }
                    break;
                case "description": if (locale == null) m.description = value; break;
                case "namespace": m.namespace = value; break;
                case "version": m.version = value; break;
                case "author": m.author = value; break;
                case "match": if (!value.isEmpty()) m.matches.add(value); break;
                case "include": if (!value.isEmpty()) m.includes.add(value); break;
                case "exclude": if (!value.isEmpty()) m.excludes.add(value); break;
                case "exclude-match": if (!value.isEmpty()) m.excludeMatches.add(value); break;
                case "run-at": m.runAt = runAtOf(value); break;
                case "grant": if (!value.isEmpty()) m.grants.add(value); break;
                case "require": if (!value.isEmpty()) m.requires.add(value); break;
                case "resource": {
                    String[] kv = value.trim().split("[ \t]+");
                    if (kv.length >= 2) m.resources.put(kv[0], kv[kv.length - 1]);
                    break;
                }
                case "connect": if (!value.isEmpty()) m.connects.add(value); break;
                case "noframes": m.noframes = true; break;
                case "updateurl": m.updateURL = value.isEmpty() ? null : value; break;
                case "downloadurl": case "installurl": m.downloadURL = value.isEmpty() ? null : value; break;
                case "homepage": case "homepageurl": case "website": case "source": if (m.homepage == null && !value.isEmpty()) m.homepage = value; break;
                case "icon": case "iconurl": case "defaulticon": if (m.icon == null && !value.isEmpty()) m.icon = value; break;
                default: break;
            }
        }
        if (!found) throw new ParseException("没有找到 // ==UserScript== … // ==/UserScript== 元数据块");
        if (!sawName || m.name.isEmpty()) throw new ParseException("元数据缺少 @name");
        m.header = header.toString();
        return m;
    }

    // ---------------------------------------------------------------- URL 规则

    /** 编译好的规则：source 是 JS 正则源码，ignoreCase 单独存 */
    public static final class Rule {
        public final String source;
        public final boolean ignoreCase;
        Rule(String s, boolean i) { source = s; ignoreCase = i; }

        boolean test(String url) {
            try {
                return Pattern.compile(source, ignoreCase ? Pattern.CASE_INSENSITIVE : 0).matcher(url).find();
            } catch (Exception e) {
                return false;
            }
        }
    }

    static String escape(String s) {
        StringBuilder out = new StringBuilder();
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if ("\\^$.|?*+()[]{}/".indexOf(c) >= 0) out.append('\\');
            out.append(c);
        }
        return out.toString();
    }

    private static boolean allDigits(String s) {
        if (s.isEmpty()) return false;
        for (int i = 0; i < s.length(); i++) if (!Character.isDigit(s.charAt(i))) return false;
        return true;
    }

    public static Rule matchPattern(String pattern) {
        String p = pattern.trim();
        if (p.equals("<all_urls>")) return new Rule("^(?:https?|file):\\/\\/.*$", false);
        int sep = p.indexOf("://");
        if (sep < 0) return null;
        String scheme = p.substring(0, sep).toLowerCase(Locale.ROOT);
        String schemeRe;
        switch (scheme) {
            case "*": schemeRe = "https?"; break;
            case "http": case "https": case "file": case "ftp": case "ws": case "wss": schemeRe = scheme; break;
            default: return null;
        }
        String rest = p.substring(sep + 3);
        int slash = rest.indexOf('/');
        String hostPart = (slash < 0 ? rest : rest.substring(0, slash)).toLowerCase(Locale.ROOT);
        String pathPart = slash < 0 ? "/*" : rest.substring(slash);
        String hostRe;
        if (scheme.equals("file")) {
            if (!hostPart.isEmpty()) return null;
            hostRe = "";
        } else {
            if (hostPart.isEmpty()) return null;
            String host = hostPart;
            String portRe = "(?::\\d+)?";
            int colon = host.lastIndexOf(':');
            if (colon >= 0 && (!host.startsWith("[") || host.contains("]:"))) {
                String port = host.substring(colon + 1);
                if (port.equals("*") || allDigits(port)) {
                    portRe = port.equals("*") ? "(?::\\d+)?" : ":" + port;
                    host = host.substring(0, colon);
                }
            }
            boolean tld = false;
            if (host.endsWith(".tld")) { tld = true; host = host.substring(0, host.length() - 4); }
            if (host.equals("*")) hostRe = "[^\\/:?#]+";
            else if (host.startsWith("*.")) {
                String base = host.substring(2);
                if (base.isEmpty() || base.contains("*")) return null;
                hostRe = "(?:[^\\/:?#]+\\.)?" + escape(base);
            } else {
                if (host.contains("*")) return null;
                hostRe = escape(host);
            }
            if (tld) hostRe += TLD_RE;
            hostRe += portRe;
        }
        if (!pathPart.startsWith("/")) return null;
        String[] parts = pathPart.split("\\*", -1);
        StringBuilder pathRe = new StringBuilder();
        for (int i = 0; i < parts.length; i++) {
            if (i > 0) pathRe.append(".*");
            pathRe.append(escape(parts[i]));
        }
        return new Rule("^" + schemeRe + ":\\/\\/" + hostRe + pathRe + "$", false);
    }

    public static Rule glob(String pattern) {
        String p = pattern.trim();
        if (p.isEmpty()) return null;
        if (p.length() >= 2 && p.startsWith("/")) {
            int last = p.lastIndexOf('/');
            if (last > 0) {
                String flags = p.substring(last + 1);
                if (flags.matches("[igmsuy]*")) {
                    String src = p.substring(1, last);
                    if (src.isEmpty()) return null;
                    try { Pattern.compile(src); } catch (Exception e) { return null; }
                    return new Rule(src, flags.contains("i"));
                }
            }
        }
        if (p.equals("*")) return new Rule("^.*$", true);
        StringBuilder re = new StringBuilder();
        int i = 0;
        while (i < p.length()) {
            char c = p.charAt(i);
            if (c == '*') re.append(".*");
            else if (c == '.' && p.regionMatches(true, i, ".tld", 0, 4) && (i + 4 == p.length() || "/:?#".indexOf(p.charAt(i + 4)) >= 0)) {
                re.append(TLD_RE);
                i += 4;
                continue;
            } else re.append(escape(String.valueOf(c)));
            i++;
        }
        return new Rule("^" + re + "$", true);
    }

    public static final class Rules {
        public final List<Rule> matches = new ArrayList<>(), includes = new ArrayList<>(), excludes = new ArrayList<>(), excludeMatches = new ArrayList<>();
        public final List<String> invalid = new ArrayList<>();
        public boolean matchAll;

        public boolean matches(String url) {
            int h = url.indexOf('#');
            String noHash = h < 0 ? url : url.substring(0, h);
            String lower = url.toLowerCase(Locale.ROOT);
            boolean included;
            if (matchAll) included = lower.startsWith("http://") || lower.startsWith("https://");
            else {
                included = false;
                for (Rule r : matches) if (r.test(noHash)) { included = true; break; }
                if (!included) for (Rule r : includes) if (r.test(url)) { included = true; break; }
            }
            if (!included) return false;
            for (Rule r : excludes) if (r.test(url)) return false;
            for (Rule r : excludeMatches) if (r.test(noHash)) return false;
            return true;
        }
    }

    private interface Compiler { Rule compile(String s); }

    private static void compileInto(List<String> src, List<Rule> out, List<String> bad, Compiler f) {
        for (String s : src) {
            Rule r = f.compile(s);
            if (r != null) out.add(r); else bad.add(s);
        }
    }

    public static Rules rules(Meta m) {
        Rules r = new Rules();
        compileInto(m.matches, r.matches, r.invalid, UserScriptCore::matchPattern);
        compileInto(m.includes, r.includes, r.invalid, UserScriptCore::glob);
        compileInto(m.excludes, r.excludes, r.invalid, UserScriptCore::glob);
        compileInto(m.excludeMatches, r.excludeMatches, r.invalid, UserScriptCore::matchPattern);
        r.matchAll = m.matches.isEmpty() && m.includes.isEmpty();
        return r;
    }

    // ---------------------------------------------------------------- 版本 / @connect / 安装地址

    public static int compareVersions(String a, String b) {
        List<String> pa = segs(a), pb = segs(b);
        for (int i = 0; i < Math.max(pa.size(), pb.size()); i++) {
            String sa = i < pa.size() ? pa.get(i) : "0", sb = i < pb.size() ? pb.get(i) : "0";
            int da = digits(sa), db = digits(sb);
            long na = num(sa.substring(0, da)), nb = num(sb.substring(0, db));
            String xa = sa.substring(da), xb = sb.substring(db);
            if (na != nb) return na < nb ? -1 : 1;
            if (!xa.equals(xb)) {
                if (xa.isEmpty()) return 1;
                if (xb.isEmpty()) return -1;
                return xa.compareTo(xb) < 0 ? -1 : 1;
            }
        }
        return 0;
    }

    private static List<String> segs(String v) {
        List<String> out = new ArrayList<>();
        for (String s : (v == null ? "" : v.trim()).split("\\.")) if (!s.isEmpty()) out.add(s);
        return out;
    }

    private static int digits(String s) {
        int i = 0;
        while (i < s.length() && Character.isDigit(s.charAt(i))) i++;
        return i;
    }

    private static long num(String d) {
        if (d.isEmpty()) return 0;
        try { return Long.parseLong(d.length() > 18 ? d.substring(0, 18) : d); } catch (Exception e) { return 0; }
    }

    public static String normalizeHost(String s) {
        String h = s == null ? "" : s.trim().toLowerCase(Locale.ROOT);
        int r = h.indexOf("://");
        if (r >= 0) h = h.substring(r + 3);
        for (int i = 0; i < h.length(); i++) {
            char c = h.charAt(i);
            if (c == '/' || c == '?' || c == '#') { h = h.substring(0, i); break; }
        }
        if (h.startsWith("[") && h.indexOf(']') > 0) h = h.substring(1, h.indexOf(']'));
        else if (h.indexOf(':') >= 0 && h.indexOf(':') == h.lastIndexOf(':')) h = h.substring(0, h.lastIndexOf(':'));
        if (h.startsWith("*.")) h = h.substring(2);
        if (h.startsWith(".")) h = h.substring(1);
        if (h.endsWith(".")) h = h.substring(0, h.length() - 1);
        return h;
    }

    public static boolean isDeclared(String host, List<String> connects, String pageHost) {
        String h = normalizeHost(host);
        if (h.isEmpty()) return false;
        for (String c : connects) {
            String raw = c.trim().toLowerCase(Locale.ROOT);
            if (raw.equals("*")) return true;
            String d = raw.equals("self") ? normalizeHost(pageHost == null ? "" : pageHost) : normalizeHost(raw);
            if (d.isEmpty()) continue;
            if (h.equals(d) || h.endsWith("." + d)) return true;
        }
        return false;
    }

    /** "sameOrigin" / "declared" / "undeclared" */
    public static String connectVerdict(String target, String pageHost, List<String> connects) {
        String h = normalizeHost(target);
        if (pageHost != null && !pageHost.isEmpty() && normalizeHost(pageHost).equals(h)) return "sameOrigin";
        return isDeclared(h, connects, pageHost) ? "declared" : "undeclared";
    }

    public static String installURL(String input) {
        URI u;
        try { u = new URI(input.trim()); } catch (Exception e) { return null; }
        String scheme = u.getScheme() == null ? "" : u.getScheme().toLowerCase(Locale.ROOT);
        if (!scheme.equals("http") && !scheme.equals("https")) return null;
        String host = u.getHost() == null ? "" : u.getHost().toLowerCase(Locale.ROOT);
        if (host.isEmpty()) return null;
        List<String> segs = new ArrayList<>();
        for (String s : (u.getPath() == null ? "" : u.getPath()).split("/")) if (!s.isEmpty()) segs.add(s);
        if ((host.equals("github.com") || host.equals("www.github.com")) && segs.size() >= 5 && (segs.get(2).equals("blob") || segs.get(2).equals("raw"))) {
            StringBuilder sb = new StringBuilder("https://raw.githubusercontent.com/").append(segs.get(0)).append('/').append(segs.get(1));
            for (int i = 3; i < segs.size(); i++) sb.append('/').append(segs.get(i));
            return sb.toString();
        }
        if (host.equals("greasyfork.org") || host.equals("www.greasyfork.org") || host.equals("sleazyfork.org") || host.equals("www.sleazyfork.org")) {
            int i = !segs.isEmpty() && !segs.get(0).equals("scripts") ? 1 : 0;
            if (segs.size() > i + 1 && segs.get(i).equals("scripts")) {
                String idPart = segs.get(i + 1);
                String id = idPart.substring(0, digits(idPart));
                boolean isCode = segs.size() > i + 2 && segs.get(i + 2).equals("code");
                if (!id.isEmpty() && (!isCode || !segs.get(segs.size() - 1).endsWith(".user.js"))) {
                    return "https://" + host.replace("www.", "") + "/scripts/" + id + "/code/script.user.js";
                }
            }
        }
        String s = u.toString();
        int hash = s.indexOf('#');
        return hash < 0 ? s : s.substring(0, hash);
    }

    public static boolean looksLikeUserScript(String url) {
        try {
            URI u = new URI(url);
            String sc = u.getScheme() == null ? "" : u.getScheme().toLowerCase(Locale.ROOT);
            return (sc.equals("http") || sc.equals("https")) && u.getPath() != null && u.getPath().toLowerCase(Locale.ROOT).endsWith(".user.js");
        } catch (Exception e) {
            return false;
        }
    }

    static String httpURL(String s) {
        if (s == null || s.isEmpty()) return null;
        try {
            URI u = new URI(s);
            String sc = u.getScheme() == null ? "" : u.getScheme().toLowerCase(Locale.ROOT);
            return sc.equals("http") || sc.equals("https") ? s : null;
        } catch (Exception e) {
            return null;
        }
    }

    public static String updateCheckURL(Meta m, String sourceURL) {
        for (String s : new String[]{m.updateURL, m.downloadURL, sourceURL}) { String u = httpURL(s); if (u != null) return u; }
        return null;
    }

    public static String downloadURL(Meta m, String sourceURL) {
        List<String> c = new ArrayList<>();
        c.add(m.downloadURL);
        c.add(sourceURL);
        if (m.updateURL != null && !m.updateURL.toLowerCase(Locale.ROOT).endsWith(".meta.js")) c.add(m.updateURL);
        for (String s : c) { String u = httpURL(s); if (u != null) return u; }
        return null;
    }

    /** 相对 base 解析成 http(s) 绝对地址，失败 null */
    public static String resolve(String s, String base) {
        try {
            URI u = base != null ? new URI(base).resolve(s.trim()) : new URI(s.trim());
            return httpURL(u.toString()) != null && u.getHost() != null ? u.toString() : null;
        } catch (Exception e) {
            return null;
        }
    }

    // ---------------------------------------------------------------- 注入代码

    /** 生成的运行时文件第二行 `// MIO_PARAMS …` */
    public static String params(String runtime) {
        int i = runtime.indexOf("// MIO_PARAMS ");
        if (i < 0) return "";
        int e = runtime.indexOf('\n', i);
        return runtime.substring(i + 14, e < 0 ? runtime.length() : e).trim();
    }

    private static JSONArray ruleList(List<Rule> rules) {
        JSONArray a = new JSONArray();
        for (Rule r : rules) {
            JSONObject o = new JSONObject();
            try { o.put("s", r.source).put("i", r.ignoreCase); } catch (Exception ignored) {}
            a.put(o);
        }
        return a;
    }

    /**
     * 注入页面的完整代码（与 Swift MioUserScriptRuntime.source 相同的配置结构）。
     * Android 没有隔离 world：所有脚本跑页面世界，有 @grant 的经 WebMessageListener（bridge）+ 每脚本 token 调原生。
     */
    public static String source(String runtime, String id, Meta m, String code, Map<String, String> requireCache, Map<String, String> resourceCache,
                                Map<String, String> values, String token, String bridge, String appVersion) {
        Rules rules = rules(m);
        boolean isolated = !m.grantsNone();
        try {
            JSONObject res = new JSONObject();
            for (String k : m.resources.keySet()) res.put(k, resourceCache != null && resourceCache.get(k) != null ? resourceCache.get(k) : "");
            JSONArray resList = new JSONArray();
            for (Map.Entry<String, String> e : m.resources.entrySet()) resList.put(new JSONObject().put("name", e.getKey()).put("url", e.getValue()));
            JSONObject script = new JSONObject()
                    .put("name", m.name).put("namespace", m.namespace).put("version", m.version).put("description", m.description).put("author", m.author)
                    .put("matches", new JSONArray(m.matches)).put("includes", new JSONArray(m.includes)).put("excludes", new JSONArray(m.excludes))
                    .put("grant", new JSONArray(m.grants)).put("requires", new JSONArray(m.requires)).put("resources", resList)
                    .put("run-at", m.runAt).put("noframes", m.noframes).put("connects", new JSONArray(m.connects)).put("uuid", id);
            JSONObject info = new JSONObject().put("script", script).put("scriptMetaStr", m.header).put("scriptHandler", "Mio")
                    .put("version", appVersion == null ? "" : appVersion).put("platform", "android");
            JSONObject c = new JSONObject()
                    .put("id", id).put("name", m.displayName()).put("isolated", isolated).put("handler", "mioUserScript")
                    .put("bridge", bridge).put("token", isolated ? token : "").put("runAt", m.runAt).put("noframes", m.noframes)
                    .put("grants", new JSONArray(m.grants)).put("match", ruleList(rules.matches)).put("include", ruleList(rules.includes))
                    .put("exclude", ruleList(rules.excludes)).put("excludeMatch", ruleList(rules.excludeMatches)).put("matchAll", rules.matchAll)
                    .put("values", isolated && values != null ? new JSONObject(values) : new JSONObject()).put("resources", res).put("info", info);
            StringBuilder body = new StringBuilder();
            for (String url : m.requires) {
                String rc = requireCache == null ? null : requireCache.get(url);
                if (rc != null) body.append("// @require ").append(url.replace("\n", "")).append('\n').append(rc).append("\n;\n");
            }
            body.append(code);
            String json = c.toString().replace("\u2028", "\\u2028").replace("\u2029", "\\u2029");
            return runtime + "(" + json + ", function(" + params(runtime) + "){\n" + body + "\n});\n";
        } catch (Exception e) {
            return null;
        }
    }
}
