package xyz.mio.app.browser;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import java.util.Arrays;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import org.junit.Test;

/** 强制深色按站点开关解析（与 iOS / 桌面 / dark.js 相同的规则） */
public class PageToolsPrefsTest {
    private static Map<String, Boolean> sites(Object... kv) {
        Map<String, Boolean> m = new LinkedHashMap<>();
        for (int i = 0; i < kv.length; i += 2) m.put((String) kv[i], (Boolean) kv[i + 1]);
        return m;
    }

    @Test
    public void perSiteBeatsGlobalWithParentDomains() {
        Map<String, Boolean> s = sites("example.com", true, "news.example.com", false);
        assertTrue(PageToolsPrefs.isDarkEnabled("example.com", false, s));
        assertTrue(PageToolsPrefs.isDarkEnabled("WWW.example.com", false, s));
        assertTrue(PageToolsPrefs.isDarkEnabled("blog.example.com", false, s));
        assertFalse(PageToolsPrefs.isDarkEnabled("news.example.com", true, s));
        assertFalse(PageToolsPrefs.isDarkEnabled("a.news.example.com", true, s));
        assertFalse(PageToolsPrefs.isDarkEnabled("other.org", false, s));
        assertTrue(PageToolsPrefs.isDarkEnabled("other.org", true, s));
        assertEquals("example.com", PageToolsPrefs.matchingSiteKey("x.example.com", s));
        assertNull(PageToolsPrefs.matchingSiteKey("x.org", s));
    }

    @Test
    public void siteToggleFollowsGlobalWhenEqual() {
        Map<String, Boolean> s = PageToolsPrefs.withSiteDark("www.example.com", true, false, sites());
        assertEquals(sites("example.com", true), s);
        s = PageToolsPrefs.withSiteDark("m.example.com", false, false, s);
        assertEquals(sites(), s);
        s = PageToolsPrefs.withSiteDark("m.example.com", false, true, s);
        assertEquals(sites("m.example.com", false), s);
        assertTrue(PageToolsPrefs.needsScript(false, sites("a.com", true)));
        assertFalse(PageToolsPrefs.needsScript(false, sites("a.com", false)));
    }

    @Test
    public void nativeHosts() {
        List<String> l = PageToolsPrefs.updatedNativeHosts(Collections.emptyList(), "www.github.com", true);
        assertEquals(Arrays.asList("github.com"), l);
        assertNull(PageToolsPrefs.updatedNativeHosts(l, "github.com", true));
        assertEquals(Collections.emptyList(), PageToolsPrefs.updatedNativeHosts(l, "github.com", false));
        assertNull(PageToolsPrefs.updatedNativeHosts(l, " ", true));
        assertEquals(12, PageToolsPrefs.clampFontSize(3));
        assertEquals(32, PageToolsPrefs.clampFontSize(99));
    }
}
