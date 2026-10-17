package xyz.mio.app.browser;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

import org.json.JSONArray;
import org.json.JSONObject;
import org.junit.Test;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.Map;

public class UserScriptCoreTest {
    static final String SAMPLE = "// ==UserScript==\n"
            + "// @name         Demo\n"
            + "// @name:zh-CN   演示\n"
            + "// @namespace    https://mio.test\n"
            + "// @version      1.2.0\n"
            + "// @match        https://*.example.com/*\n"
            + "// @include      /^https?://other\\.org/.*$/i\n"
            + "// @exclude      *://*.example.com/admin*\n"
            + "// @RUN-AT       document-start\n"
            + "// @grant        GM_setValue\n"
            + "// @connect      api.example.net\n"
            + "// @require      https://cdn.test/lib.js\n"
            + "// @resource     css https://cdn.test/a.css\n"
            + "// @updateURL    https://mio.test/demo.meta.js\n"
            + "// @downloadURL  https://mio.test/demo.user.js\n"
            + "// @noframes\n"
            + "// ==/UserScript==\n"
            + "window.__ran = true;\n";

    /** Gradle 单测的工作目录是 android/app */
    static File repo(String rel) {
        File f = new File("../../" + rel);
        if (!f.exists()) f = new File(rel);
        return f;
    }

    @Test
    public void rulesMatchSwiftFixture() throws Exception {
        JSONArray cases = new JSONArray(new String(Files.readAllBytes(repo("tools/MioAppTests/js/fixtures/userscript-rules.json").toPath()), StandardCharsets.UTF_8));
        assertTrue(cases.length() > 5);
        for (int i = 0; i < cases.length(); i++) {
            JSONObject c = cases.getJSONObject(i);
            String p = c.getString("pattern");
            UserScriptCore.Rule r = c.getString("kind").equals("match") ? UserScriptCore.matchPattern(p) : UserScriptCore.glob(p);
            assertNotNull(p, r);
            JSONObject want = c.getJSONObject("rule");
            assertEquals(p, want.getString("source"), r.source);
            assertEquals(p, want.getBoolean("ignoreCase"), r.ignoreCase);
            JSONObject urls = c.getJSONObject("urls");
            for (String u : urls.keySet()) {
                String test = c.getString("kind").equals("match") ? u.split("#", -1)[0] : u;
                assertEquals(p + " vs " + u, urls.getBoolean(u), r.test(test));
            }
        }
    }

    @Test
    public void invalidPatterns() {
        assertNull(UserScriptCore.matchPattern("example.com"));
        assertNull(UserScriptCore.matchPattern("chrome://x/*"));
        assertNull(UserScriptCore.matchPattern("https://exa*mple.com/*"));
        assertNull(UserScriptCore.matchPattern("file://host/x"));
        assertNotNull(UserScriptCore.matchPattern("https://a.com"));
        assertNull(UserScriptCore.glob("/(/"));
    }

    @Test
    public void parseMeta() throws Exception {
        UserScriptCore.Meta m = UserScriptCore.parse(SAMPLE);
        assertEquals("Demo", m.name);
        assertEquals("演示", m.displayName());
        assertEquals("document-start", m.runAt);
        assertEquals(Collections.singletonList("GM_setValue"), m.grants);
        assertEquals("https://cdn.test/a.css", m.resources.get("css"));
        assertTrue(m.noframes);
        assertFalse(m.grantsNone());
        assertTrue(m.header.startsWith("// ==UserScript=="));
        assertTrue(m.header.endsWith("// ==/UserScript=="));
        try { UserScriptCore.parse("var x"); fail(); } catch (UserScriptCore.ParseException e) { assertTrue(e.getMessage().contains("元数据块")); }
        try { UserScriptCore.parse("// ==UserScript==\n// @version 1\n// ==/UserScript=="); fail(); } catch (UserScriptCore.ParseException e) { assertTrue(e.getMessage().contains("@name")); }
        assertEquals("document-end", UserScriptCore.parse("// ==UserScript==\n// @name x\n// @run-at document-body\n// ==/UserScript==").runAt);
        assertTrue(UserScriptCore.parse("// ==UserScript==\n// @name x\n// @grant none\n// ==/UserScript==").grantsNone());
    }

    @Test
    public void ruleCombination() throws Exception {
        UserScriptCore.Rules r = UserScriptCore.rules(UserScriptCore.parse(SAMPLE));
        assertTrue(r.matches("https://www.example.com/a#b"));
        assertFalse(r.matches("https://www.example.com/admin/x"));
        assertTrue(r.matches("HTTPS://OTHER.org/x"));
        assertFalse(r.matches("https://evil.org/"));
        UserScriptCore.Rules all = UserScriptCore.rules(UserScriptCore.parse("// ==UserScript==\n// @name a\n// @match nope\n// ==/UserScript=="));
        assertEquals(Collections.singletonList("nope"), all.invalid);
        assertFalse(all.matchAll);
    }

    @Test
    public void versions() {
        assertEquals(1, UserScriptCore.compareVersions("1.10", "1.9"));
        assertEquals(0, UserScriptCore.compareVersions("1.0", "1.0.0"));
        assertEquals(-1, UserScriptCore.compareVersions("1.0b", "1.0"));
        assertEquals(-1, UserScriptCore.compareVersions("2", "10"));
    }

    @Test
    public void connect() {
        assertEquals("sameOrigin", UserScriptCore.connectVerdict("www.a.com", "www.a.com", Collections.emptyList()));
        assertEquals("declared", UserScriptCore.connectVerdict("api.b.com", "a.com", Collections.singletonList("b.com")));
        assertEquals("undeclared", UserScriptCore.connectVerdict("evilb.com", "a.com", Collections.singletonList("b.com")));
        assertEquals("declared", UserScriptCore.connectVerdict("sub.a.com", "a.com", Collections.singletonList("self")));
        assertEquals("::1", UserScriptCore.normalizeHost("https://[::1]:8080/x"));
    }

    @Test
    public void installUrls() throws Exception {
        assertEquals("https://raw.githubusercontent.com/u/r/main/a/b.user.js", UserScriptCore.installURL("https://github.com/u/r/blob/main/a/b.user.js"));
        assertEquals("https://greasyfork.org/scripts/12345/code/script.user.js", UserScriptCore.installURL("https://greasyfork.org/zh-CN/scripts/12345-some-name"));
        assertEquals("https://greasyfork.org/scripts/12345-x/code/x.user.js", UserScriptCore.installURL("https://greasyfork.org/scripts/12345-x/code/x.user.js"));
        assertNull(UserScriptCore.installURL("ftp://x/y"));
        assertEquals("https://a.test/x.user.js", UserScriptCore.installURL("https://a.test/x.user.js#frag"));
        assertTrue(UserScriptCore.looksLikeUserScript("https://a.test/X.USER.JS?x=1"));
        assertFalse(UserScriptCore.looksLikeUserScript("https://a.test/x.js"));
        UserScriptCore.Meta m = UserScriptCore.parse(SAMPLE);
        assertEquals("https://mio.test/demo.meta.js", UserScriptCore.updateCheckURL(m, null));
        assertEquals("https://mio.test/demo.user.js", UserScriptCore.downloadURL(m, null));
        assertEquals("https://cdn.test/x/lib.js", UserScriptCore.resolve("lib.js", "https://cdn.test/x/a.user.js"));
        assertNull(UserScriptCore.resolve("javascript:alert(1)", null));
    }

    @Test
    public void injectionSource() throws Exception {
        String runtime = new String(Files.readAllBytes(repo("android/app/src/main/assets/mio-userscript-runtime.js").toPath()), StandardCharsets.UTF_8);
        String swift = new String(Files.readAllBytes(repo("ios/App/App/MioUserScriptCore.swift").toPath()), StandardCharsets.UTF_8);
        java.util.regex.Matcher pm = java.util.regex.Pattern.compile("static let apiParams = \"([^\"]*)\"").matcher(swift);
        assertTrue(pm.find());
        assertEquals(pm.group(1), UserScriptCore.params(runtime));
        Map<String, String> req = new HashMap<>();
        req.put("https://cdn.test/lib.js", "LIB()");
        Map<String, String> values = new HashMap<>();
        values.put("n", "5");
        String src = UserScriptCore.source(runtime, "sid", UserScriptCore.parse(SAMPLE), "BODY()", req, null, values, "tok", "mioUserScriptNative", "0.3.3");
        assertNotNull(src);
        assertTrue(src.indexOf("LIB()") < src.indexOf("BODY()"));
        assertTrue(src.contains("\"token\":\"tok\""));
        assertTrue(src.contains("\"bridge\":\"mioUserScriptNative\""));
        assertTrue(src.contains("\"n\":\"5\""));
        assertTrue(src.endsWith("});\n"));
        // @grant none：不带 token / 值
        String none = UserScriptCore.source(runtime, "s2", UserScriptCore.parse("// ==UserScript==\n// @name p\n// @grant none\n// ==/UserScript=="), "X()", null, null, values, "tok", "b", "");
        assertFalse(none.contains("\"tok\""));
        assertFalse(none.contains("\"n\":\"5\""));
    }
}
