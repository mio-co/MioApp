package xyz.mio.app.browser;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.Arrays;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

import org.junit.Test;

/** 翻译原生侧纯逻辑：请求白名单 / Key 只在原生加 / 正则摘取 / 站点规范化 / LRU / 脚本模板（规则与 iOS、Windows 一致） */
public class TranslateCoreTest {
    private static final String BASE = "https://api.example.com/v1/";

    private static TranslateCore.Checked check(String url, String method, String body, String auth) {
        return TranslateCore.check(url, method, null, body, 0, auth, null, BASE);
    }

    @Test
    public void allowsOnlyTranslationHostsAndConfiguredOpenAI() {
        assertTrue(check("https://www.bing.com/ttranslatev3?isVertical=1", "POST", "a=b", null).ok());
        assertTrue(check("https://translate.googleapis.com/translate_a/t?client=gtx", "GET", null, null).ok());
        assertFalse("免费引擎只允许 https", check("http://www.bing.com/x", "GET", null, null).ok());
        assertFalse(check("https://evil.example.org/steal", "GET", null, null).ok());
        TranslateCore.Checked ai = check("https://api.example.com/v1/chat/completions", "POST", "{}", "openai");
        assertTrue(ai.ok());
        assertTrue(ai.openAIAuth);
        assertFalse("Key 只给 chat/completions", check("https://api.example.com/v1/models", "GET", null, "openai").ok());
        assertFalse("不能把 Key 发给别的域名", check("https://www.bing.com/x", "GET", null, "openai").ok());
        assertFalse(TranslateCore.check("https://api.example.com/v1/chat/completions", "POST", null, null, 0, "openai", null, "").ok());
        assertFalse(check("https://www.bing.com/x", "PUT", null, null).ok());
        assertFalse(check("https://www.bing.com/x", "GET", "x", null).ok());
        char[] big = new char[300_000];
        Arrays.fill(big, 'x');
        assertFalse(check("https://www.bing.com/x", "POST", new String(big), null).ok());
        assertFalse(check("::not a url", "GET", null, null).ok());
    }

    @Test
    public void headersFilteredAndTimeoutClamped() {
        Map<String, String> h = new HashMap<>();
        h.put("Content-Type", "a");
        h.put("Cookie", "x");
        h.put("Authorization", "Bearer t");
        h.put("X-Evil", "1");
        TranslateCore.Checked c = TranslateCore.check("https://www.bing.com/x", "POST", h, null, 999_999, null, null, "");
        assertEquals(1, c.headers.size());
        assertEquals("a", c.headers.get("content-type"));
        assertEquals(90000, c.timeoutMs);
        TranslateCore.Checked e = TranslateCore.check("https://api-edge.cognitive.microsofttranslator.com/translate", "POST", h, null, 12000, null, null, "");
        assertEquals("Bearer t", e.headers.get("authorization"));
        assertEquals(12000, e.timeoutMs);
    }

    @Test
    public void runPicksMatchesBingPage() {
        String page = "x;IG:\"6F33281EA7124DA59F5AA885EEDCB22C\",y data-iid=\"translator.5023\" var params_AbusePreventionHelper = [1792195186283,\"Y0RQ\",3600000];";
        List<List<String>> p = TranslateCore.runPicks(page, Arrays.asList("IG:\"([0-9A-Fa-f]+)\"", "data-iid=\"(translator\\.\\d+)\"",
                "params_AbusePreventionHelper\\s*=\\s*\\[(\\d+),\"([^\"]+)\",(\\d+)", "nomatch(\\d)", "(unclosed"));
        assertEquals(Arrays.asList("6F33281EA7124DA59F5AA885EEDCB22C"), p.get(0));
        assertEquals(Arrays.asList("translator.5023"), p.get(1));
        assertEquals(Arrays.asList("1792195186283", "Y0RQ", "3600000"), p.get(2));
        assertNull(p.get(3));
        assertNull(p.get(4));
    }

    @Test
    public void hostsAndBase() {
        assertEquals("example.com", TranslateCore.normalizeHost("https://www.Example.com/path?q=1"));
        assertEquals("news.example.com", TranslateCore.normalizeHost("*.news.example.com"));
        assertEquals("example.com", TranslateCore.normalizeHost("example.com:8080/x"));
        assertNull(TranslateCore.normalizeHost("not a host"));
        assertTrue(TranslateCore.hostMatches("docs.example.com", "example.com"));
        assertFalse(TranslateCore.hostMatches("notexample.com", "example.com"));
        assertTrue(TranslateCore.isAuto("news.ycombinator.com", Arrays.asList("ycombinator.com")));
        assertEquals("https://api.openai.com/v1", TranslateCore.normalizeBase("https://api.openai.com/v1/?x=1#f"));
        assertEquals("", TranslateCore.normalizeBase("ftp://x/v1"));
        assertEquals("https://api.openai.com/v1/chat/completions", TranslateCore.openaiEndpoint("https://api.openai.com/v1/"));
        assertEquals("http://192.168.1.2:11434/v1/chat/completions", TranslateCore.openaiEndpoint("http://192.168.1.2:11434/v1/chat/completions"));
    }

    @Test
    public void lru() {
        TranslateCore.Lru l = new TranslateCore.Lru(3);
        l.putChecked("a", "1");
        l.putChecked("b", "2");
        l.putChecked("c", "3");
        assertEquals("1", l.getTouch("a"));
        l.putChecked("d", "4");
        assertNull(l.getTouch("b"));
        assertEquals(3, l.size());
        char[] big = new char[30_000];
        l.putChecked("big", new String(big));
        assertNull(l.getTouch("big"));
    }

    @Test
    public void scriptTemplateFromRepo() throws Exception {
        // gradle 单测的工作目录是 android/app（assets 来自仓库 shared/，见 build.gradle 的 srcDirs）
        File f = new File("../../shared/translate/mio-translate.js");
        if (!f.exists()) f = new File("../shared/translate/mio-translate.js");
        String tpl = new String(Files.readAllBytes(f.toPath()), StandardCharsets.UTF_8);
        String out = TranslateCore.script(tpl, "QUJD");
        assertNotNull(out);
        assertTrue(out.contains("var CONFIG_B64 = 'QUJD';"));
        assertFalse(out.contains("__MIO_TRANSLATE_CONFIG__"));
        assertNull(TranslateCore.script("nothing", "QUJD"));
        assertEquals("简体中文", TranslateCore.languageName("zh-CN"));
        assertTrue(TranslateCore.isEngine("openai"));
    }
}
