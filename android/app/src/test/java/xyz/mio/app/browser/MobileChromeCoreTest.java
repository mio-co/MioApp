package xyz.mio.app.browser;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/** 与 MobileChromeCoreTests.swift 同样的规则 */
public class MobileChromeCoreTest {
    @Test
    public void displayHost() {
        assertEquals("example.com", MobileChromeCore.displayHost("https://www.Example.com/a?b#c"));
        assertEquals("m.youtube.com", MobileChromeCore.displayHost("https://m.youtube.com/watch?v=1"));
        assertEquals("host.dev", MobileChromeCore.displayHost("http://user:pw@host.dev:8080/x"));
        assertEquals("www.com", MobileChromeCore.displayHost("https://www.com/"));
        assertEquals("::1", MobileChromeCore.displayHost("https://[::1]:8080/"));
        assertEquals("", MobileChromeCore.displayHost(null));
    }

    @Test
    public void collapseHidesOnScrollDownAndShowsOnUpTopBottom() {
        MobileChromeCore.Collapse c = new MobileChromeCore.Collapse(16);
        assertEquals(MobileChromeCore.NONE, c.scrolled(10, 0, 5000));
        assertEquals(MobileChromeCore.HIDE, c.scrolled(40, 10, 5000));
        assertTrue(c.hidden());
        assertEquals(MobileChromeCore.NONE, c.scrolled(300, 40, 5000));
        assertEquals(MobileChromeCore.NONE, c.scrolled(290, 300, 5000));
        assertEquals(MobileChromeCore.SHOW, c.scrolled(270, 290, 5000));
        c.scrolled(400, 270, 5000);
        assertTrue(c.hidden());
        assertEquals(MobileChromeCore.SHOW, c.scrolled(0, 400, 5000));
        c.scrolled(400, 0, 5000);
        assertEquals(MobileChromeCore.SHOW, c.scrolled(5000, 400, 5000));
        // 不够一屏：始终显示
        MobileChromeCore.Collapse s = new MobileChromeCore.Collapse(16);
        assertEquals(MobileChromeCore.NONE, s.scrolled(40, 0, 0));
        assertFalse(s.hidden());
    }

    @Test
    public void swipe() {
        assertEquals(MobileChromeCore.SWIPE_NEXT, MobileChromeCore.classifySwipe(-80, 5, 0, 0));
        assertEquals(MobileChromeCore.SWIPE_PREV, MobileChromeCore.classifySwipe(80, -10, 0, 0));
        assertEquals(MobileChromeCore.SWIPE_OVERVIEW, MobileChromeCore.classifySwipe(5, -60, 0, 0));
        assertEquals(MobileChromeCore.SWIPE_NONE, MobileChromeCore.classifySwipe(60, 50, 0, 0));
        assertEquals(MobileChromeCore.SWIPE_NONE, MobileChromeCore.classifySwipe(0, 80, 0, 0));
    }

    @Test
    public void menuKeepsEveryLegacyEntry() {
        Set<String> all = new HashSet<>();
        List<String> flat = new ArrayList<>();
        for (MobileChromeCore.Section s : MobileChromeCore.menuSections(true, "example.com", true, true)) { all.addAll(s.items); flat.addAll(s.items); }
        assertEquals("没有重复", all.size(), flat.size());
        for (String[] e : MobileChromeCore.LEGACY) {
            String[] p = e[1].split("\\.");
            if (p[0].equals("menu")) assertTrue(e[0] + " → " + e[1], all.contains(p[1]));
            else assertTrue(e[0], p[0].equals("capsule") || p[0].equals("tabsMenu"));
            assertFalse(MobileChromeCore.title(p[1], false).isEmpty());
        }
        List<MobileChromeCore.Section> off = MobileChromeCore.menuSections(false, null, false, false);
        Set<String> few = new HashSet<>();
        for (MobileChromeCore.Section s : off) few.addAll(s.items);
        assertFalse(few.contains("share"));
        assertFalse(few.contains("adblockSite"));
        assertTrue(few.contains("settings"));
        assertTrue(few.contains("backToMio"));
        Set<String> withC = new HashSet<>();
        for (MobileChromeCore.Section s : MobileChromeCore.menuSections(true, "a.com", true, true, true)) withC.addAll(s.items);
        assertTrue(withC.contains("openInContainer"));
        assertTrue(withC.contains("siteContainer"));
        assertFalse(all.contains("siteContainer"));
    }

    @Test
    public void desktopUa() {
        String m = "Mozilla/5.0 (Linux; Android 14; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Mobile Safari/537.36";
        assertEquals("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36",
                MobileChromeCore.desktopUserAgent(m));
    }
}
