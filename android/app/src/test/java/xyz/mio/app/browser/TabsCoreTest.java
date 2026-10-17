package xyz.mio.app.browser;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import org.json.JSONArray;
import org.json.JSONObject;
import org.junit.Test;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;

/** 与 desktop/test/tabs-core.test.js、MioTabsCoreTests.swift 同样的用例 */
public class TabsCoreTest {
    private static List<String> hosts(TabsCore s) {
        List<String> out = new ArrayList<>();
        for (TabsCore.Tab t : s.tabs()) out.add(TabsCore.displayHost(t.url));
        return out;
    }

    private static TabsCore.Opts o() { return TabsCore.Opts.make(); }

    @Test
    public void newTabGoesRightOfActive() {
        TabsCore s = new TabsCore();
        TabsCore.Tab a = s.add("https://a.com/", o());
        s.add("https://b.com/", o());
        s.select(a.id);
        TabsCore.Tab c = s.add("https://c.com/", o());
        assertEquals(Arrays.asList("a.com", "c.com", "b.com"), hosts(s));
        assertEquals(Long.valueOf(c.id), s.activeId());
    }

    @Test
    public void backgroundTabsKeepOpeningOrder() {
        TabsCore s = new TabsCore();
        s.add("https://a.com/", o());
        s.add("https://z.com/", o().activate(false).index(1));
        s.selectIndex(0);
        for (int n = 1; n <= 3; n++) s.add("https://" + n + ".com/", o().activate(false).fromActive(true));
        assertEquals(Arrays.asList("a.com", "1.com", "2.com", "3.com", "z.com"), hosts(s));
        s.selectIndex(4);
        s.selectIndex(0);
        s.add("https://4.com/", o().activate(false).fromActive(true));
        assertEquals(Arrays.asList("a.com", "4.com", "1.com", "2.com", "3.com", "z.com"), hosts(s));
    }

    @Test
    public void foregroundChildKeepsOpener() {
        TabsCore s = new TabsCore();
        TabsCore.Tab a = s.add("https://a.com/", o());
        TabsCore.Tab b = s.add("https://b.com/", o().fromActive(true));
        assertEquals(Long.valueOf(b.id), s.activeId());
        assertEquals(Long.valueOf(a.id), b.openerId);
    }

    @Test
    public void closeActivatesRightThenLeft() {
        TabsCore s = new TabsCore();
        TabsCore.Tab a = s.add("https://a.com/", o());
        TabsCore.Tab b = s.add("https://b.com/", o());
        TabsCore.Tab c = s.add("https://c.com/", o());
        s.select(b.id);
        s.close(b.id);
        assertEquals(Long.valueOf(c.id), s.activeId());
        s.close(c.id);
        assertEquals(Long.valueOf(a.id), s.activeId());
        s.close(a.id);
        assertNull(s.activeId());
        assertTrue(s.isEmpty());
        assertNull(s.close(999));
    }

    @Test
    public void reopenRestoresPositionAndContainer() {
        TabsCore s = new TabsCore();
        s.add("https://a.com/", o());
        TabsCore.Tab b = s.add("https://b.com/", o().title("B").container("work").locked(true));
        s.add("https://c.com/", o());
        s.close(b.id);
        s.close(s.tabs().get(0).id);
        assertEquals("https://a.com/", s.reopenClosed().url);
        TabsCore.Tab r = s.reopenClosed();
        assertEquals("B", r.title);
        assertEquals("work", r.containerId);
        assertTrue(r.locked);
        assertEquals(Arrays.asList("a.com", "b.com", "c.com"), hosts(s));
        assertNull(s.reopenClosed());
    }

    @Test
    public void closedStackLimitAndHttpOnly() {
        TabsCore s = new TabsCore(50, 2);
        for (String u : new String[]{"https://1.com/", "about:blank", "https://2.com/", "https://3.com/"}) s.close(s.add(u, o()).id);
        assertEquals(2, s.closed().size());
        assertEquals("https://2.com/", s.closed().get(0).url);
    }

    @Test
    public void maxTabs() {
        TabsCore s = new TabsCore(2, 20);
        assertNotNull(s.add("https://a.com/", o()));
        assertNotNull(s.add("https://b.com/", o()));
        assertNull(s.add("https://c.com/", o()));
    }

    @Test
    public void selectRelativeAndMove() {
        TabsCore s = new TabsCore();
        for (String x : new String[]{"a", "b", "c"}) s.add("https://" + x + ".com/", o());
        s.selectIndex(2);
        s.selectRelative(1);
        assertEquals(0, s.activeIndex());
        s.selectRelative(-1);
        assertEquals(2, s.activeIndex());
        assertTrue(s.move(0, 2));
        assertEquals(Arrays.asList("b.com", "c.com", "a.com"), hosts(s));
        assertFalse(s.move(1, 1));
        assertFalse(s.move(5, 0));
    }

    @Test
    public void toUnloadLru() {
        TabsCore s = new TabsCore();
        long[] ids = new long[4];
        String[] names = {"a", "b", "c", "d"};
        for (int i = 0; i < 4; i++) ids[i] = s.add("https://" + names[i] + ".com/", o()).id;
        s.select(ids[1]);
        s.select(ids[0]);
        s.select(ids[3]);
        assertEquals(Arrays.asList(ids[2], ids[1]), s.toUnload(2, t -> true));
        assertEquals(Collections.emptyList(), s.toUnload(10, t -> true));
        assertFalse(s.toUnload(1, t -> true).contains(ids[3]));
    }

    @Test
    public void containerInheritanceAndLock() {
        TabsCore s = new TabsCore();
        TabsCore.Tab a = s.add("https://a.com/", o().container("shop"));
        assertEquals("shop", s.add("https://a.com/x", o().fromActive(true)).containerId);
        s.select(a.id);
        assertEquals("work", s.add("https://a.com/y", o().fromActive(true).container("work")).containerId);
        s.setLocked(a.id, true);
        s.select(a.id);
        TabsCore.Tab forced = s.add("https://a.com/z", o().fromActive(true).container("work"));
        assertEquals("shop", forced.containerId);
        assertTrue(forced.locked);
        assertFalse(s.setContainer(forced.id, "work"));
        s.setLocked(forced.id, false);
        assertTrue(s.setContainer(forced.id, "work"));
        assertEquals("default", s.add("https://b.com/", o().container("../evil")).containerId);
    }

    @Test
    public void removeContainer() {
        TabsCore s = new TabsCore();
        s.add("https://a.com/", o());
        s.add("https://b.com/", o().container("p2"));
        s.add("https://c.com/", o().container("p2"));
        TabsCore.Tab d = s.add("https://d.com/", o().container("p2"));
        s.close(d.id);
        assertEquals(2, s.removeContainer("p2").size());
        assertEquals(Collections.singletonList("a.com"), hosts(s));
        for (TabsCore.Closed c : s.closed()) assertFalse("p2".equals(c.containerId));
        assertTrue(s.removeContainer("default").isEmpty());
    }

    @Test
    public void serializeRestoreRoundTrip() throws Exception {
        TabsCore s = new TabsCore();
        s.add("https://a.com/", o().title("  A \n title "));
        s.add("about:blank", o());
        TabsCore.Tab c = s.add("https://c.com/x?y=1", o().title("C").container("acc2").locked(true));
        s.add("https://d.com/", o().container("gone"));
        s.select(c.id);
        String json = s.serialize();
        JSONObject root = new JSONObject(json);
        assertEquals(2, root.getInt("v"));
        assertEquals(1, root.getInt("active"));
        JSONArray items = root.getJSONArray("tabs");
        assertEquals(3, items.length());
        assertEquals("A title", items.getJSONObject(0).getString("title"));
        assertFalse(items.getJSONObject(0).has("container"));
        assertEquals("acc2", items.getJSONObject(1).getString("container"));
        assertTrue(items.getJSONObject(1).getBoolean("locked"));

        TabsCore r = new TabsCore();
        assertEquals(3, r.restore(json, Collections.singletonList("acc2")));
        assertEquals("https://c.com/x?y=1", r.active().url);
        assertEquals("acc2", r.active().containerId);
        assertTrue(r.active().locked);
        assertEquals("default", r.tabs().get(2).containerId);
        // 已删除容器里锁定的标签：回到默认容器并解锁
        TabsCore g = new TabsCore();
        assertEquals(1, g.restore("{\"tabs\":[{\"url\":\"https://e.com/\",\"container\":\"gone\",\"locked\":true}]}", Collections.singletonList("acc2")));
        assertEquals("default", g.tabs().get(0).containerId);
        assertFalse(g.tabs().get(0).locked);
        assertEquals(0, new TabsCore().restore("{\"tabs\":[{\"url\":\"javascript:alert(1)\"}]}", null));
        assertEquals(0, new TabsCore().restore(null, null));
        assertEquals(0, new TabsCore().restore("{broken", null));
        assertEquals(1, new TabsCore().restore("{\"v\":1,\"active\":0,\"tabs\":[{\"url\":\"https://a.com/\",\"title\":\"A\"}]}", null));
        StringBuilder many = new StringBuilder();
        for (int i = 0; i < 10; i++) many.append(i == 0 ? "" : ",").append("{\"url\":\"https://").append(i).append(".com/\"}");
        TabsCore big = new TabsCore(3, 20);
        assertEquals(3, big.restore("{\"active\":99,\"tabs\":[" + many + "]}", null));
        assertEquals(2, big.activeIndex());
    }

    @Test
    public void displayHostAndNewTabUrl() {
        assertEquals("youtube.com", TabsCore.displayHost("https://www.YouTube.com/watch?v=1"));
        assertEquals("", TabsCore.displayHost("about:blank"));
        assertEquals(TabsCore.DEFAULT_NEW_TAB_URL, TabsCore.normalizeNewTabUrl(""));
        assertEquals("https://example.com/", TabsCore.normalizeNewTabUrl("example.com"));
        assertEquals("https://localhost:8080/", TabsCore.normalizeNewTabUrl("localhost:8080"));
        assertEquals("http://example.com/a", TabsCore.normalizeNewTabUrl("http://example.com/a"));
        assertNull(TabsCore.normalizeNewTabUrl("javascript:alert(1)"));
        assertNull(TabsCore.normalizeNewTabUrl("file:///etc/passwd"));
        assertNull(TabsCore.normalizeNewTabUrl("nodot"));
    }
}
