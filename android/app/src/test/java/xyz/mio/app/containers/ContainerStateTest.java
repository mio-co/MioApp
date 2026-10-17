package xyz.mio.app.containers;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

import org.junit.Test;

import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.Deque;
import java.util.List;

/** 容器（登录状态隔离）纯逻辑：元数据持久化（JSON 往返）、标签映射 / 锁定继承、站点规则、删除清理 */
public class ContainerStateTest {
    static final String ID1 = "11111111-1111-4111-8111-111111111111";
    static final String ID2 = "22222222-2222-4222-8222-222222222222";
    static final String ID3 = "33333333-3333-4333-8333-333333333333";
    static final ContainerState.TabContainer UN = ContainerState.TabContainer.UNASSIGNED;

    static ContainerState state(String... ids) {
        ContainerState s = new ContainerState();
        Deque<String> q = new ArrayDeque<>(Arrays.asList(ids));
        s.ids = () -> q.isEmpty() ? java.util.UUID.randomUUID().toString() : q.poll();
        s.clock = () -> 1000L;
        return s;
    }

    /** 新建容器自动配色：高对比顺序，跳过已在用的颜色，全用过才循环（与 iOS / Windows 同样的用例） */
    @Test
    public void autoColorOrderHighContrastAndSkipsUsed() {
        assertEquals(Arrays.asList("blue", "orange", "green", "pink", "purple", "yellow", "red", "turquoise", "gray"), ContainerState.COLORS);
        ContainerState s = state();
        List<String> got = new ArrayList<>();
        for (int i = 0; i < 9; i++) got.add(s.create("c" + i, null).color);
        assertEquals(ContainerState.COLORS, got);
        assertEquals("blue", s.create("c9", null).color);
        ContainerState t = state();
        assertEquals("orange", t.create("a", "orange").color);
        assertEquals("blue", t.create("b", null).color);
        assertEquals("green", t.create("c", null).color);
    }

    static ContainerState.TabContainer tc(String id, boolean locked) {
        return new ContainerState.TabContainer(id, locked);
    }

    static void assertThrowsMsg(String part, Runnable r) {
        try {
            r.run();
            fail("expected exception containing " + part);
        } catch (RuntimeException e) {
            assertTrue(e.getMessage(), e.getMessage().contains(part));
        }
    }

    @Test
    public void defaultContainerImmutable() {
        ContainerState s = new ContainerState();
        assertEquals(1, s.list().size());
        assertEquals("default", s.list().get(0).id);
        assertTrue(s.list().get(0).isDefault());
        assertThrowsMsg("默认容器不能删除", () -> s.remove("default"));
        assertThrowsMsg("默认容器不能修改", () -> s.update("default", "x", null));
        assertEquals("default", s.resolve("nope"));
        assertEquals("default", s.resolve(null));
    }

    @Test
    public void createRenameRecolor() {
        ContainerState s = state(ID1, ID2);
        ContainerState.Container a = s.create("  工作  账号 ", null);
        assertEquals(ID1, a.id);
        assertEquals("工作 账号", a.name);
        assertEquals("blue", a.color);
        assertEquals(1000L, a.createdAt);
        assertEquals("red", s.create("小号", "red").color);
        assertEquals("orange", s.nextColor());
        assertThrowsMsg("不能为空", () -> s.create("   ", null));
        assertThrowsMsg("无效的颜色", () -> s.update(ID1, null, "black"));
        assertEquals("公司", s.update(ID1, "公司", "green").name);
        assertEquals("green", s.get(ID1).color);
        assertEquals(ContainerState.MAX_NAME, s.create(new String(new char[50]).replace('\0', 'x'), null).name.length());
    }

    @Test
    public void maxContainers() {
        ContainerState s = new ContainerState();
        for (int i = 0; i < ContainerState.MAX_CONTAINERS; i++) s.create("c" + i, null);
        assertFalse(s.canCreate());
        assertThrowsMsg("最多", () -> s.create("one more", null));
    }

    @Test
    public void persistenceRoundTrip() {
        ContainerState s = state(ID1, ID2);
        s.create("A", "pink");
        s.create("B", null);
        s.setTab("tab-1", ID1, true);
        s.setTab("tab-2", ID2, false);
        s.setSiteRule("https://www.GitHub.com/login", ID2);
        ContainerState again = ContainerState.parse(s.toJson());
        assertEquals(s.list(), again.list());
        assertEquals(1000L, again.get(ID1).createdAt);
        assertEquals(tc(ID1, true), again.getTab("tab-1"));
        assertEquals(tc(ID2, false), again.getTab("tab-2"));
        assertEquals(UN, again.getTab("unknown"));
        assertEquals(ID2, again.containerForUrl("https://gist.github.com/x"));
    }

    /** 同一份 JSON 三端通用 */
    @Test
    public void parsesJsonWrittenByOtherPlatforms() {
        String json = "{\"version\":1,\"containers\":[{\"id\":\"" + ID1 + "\",\"name\":\"ok\",\"color\":\"nope\",\"createdAt\":5},{\"id\":\"" + ID1 + "\",\"name\":\"dup\"},"
                + "{\"id\":\"default\",\"name\":\"hijack\"},{\"id\":\"../../etc\",\"name\":\"path\"},{\"id\":\"" + ID2 + "\",\"name\":\"   \"}],"
                + "\"tabs\":{\"t1\":{\"containerId\":\"" + ID1 + "\",\"locked\":1},\"t2\":{\"containerId\":\"" + ID3 + "\",\"locked\":true},\"t3\":null},"
                + "\"siteRules\":[{\"host\":\"a.com\",\"containerId\":\"" + ID3 + "\"},{\"host\":\"b.com\",\"containerId\":\"" + ID1 + "\"},{\"host\":\"B.com\",\"containerId\":\"" + ID1 + "\"}],"
                + "\"pendingRemovals\":[\"" + ID3 + "\",\"" + ID3 + "\",\"x\",\"" + ID1 + "\"]}";
        ContainerState s = ContainerState.parse(json);
        assertEquals(2, s.list().size());
        assertEquals(ID1, s.list().get(1).id);
        assertEquals("blue", s.get(ID1).color);
        assertEquals(5L, s.get(ID1).createdAt);
        assertEquals(Collections.singleton("t1"), s.tabs().keySet());
        assertEquals(tc(ID1, true), s.getTab("t1"));
        assertEquals(1, s.siteRules().size());
        assertEquals("b.com", s.siteRules().get(0).host);
        assertEquals(Collections.singletonList(ID3), s.pendingRemovals());
        assertEquals(1, ContainerState.parse("{not json").list().size());
        assertEquals(1, ContainerState.parse(null).list().size());
    }

    @Test
    public void tabMapping() {
        ContainerState s = state(ID1);
        s.create("A", null);
        s.setTab("x", "default", false);
        assertTrue(s.tabs().isEmpty());
        s.setTab("x", "ghost", true);
        assertEquals(tc("default", true), s.getTab("x"));
        s.setTab("y", ID1, false);
        assertEquals(tc(ID1, true), s.setTabLocked("y", true));
        s.setTab("z", ID1, false);
        s.retainTabs(Collections.singletonList("y"));
        assertEquals(Collections.singleton("y"), s.tabs().keySet());
        assertThrowsMsg("tabKey", () -> s.setTab("", ID1, false));
    }

    @Test
    public void lockInheritance() {
        ContainerState.TabContainer lockedA = tc(ID1, true), openA = tc(ID1, false);
        assertEquals(lockedA, ContainerState.inherit(lockedA, ID2));
        assertEquals(tc(ID2, false), ContainerState.inherit(openA, ID2));
        assertEquals(openA, ContainerState.inherit(openA, null));
        assertEquals(tc(ID2, false), ContainerState.inherit(null, ID2));
        assertEquals(UN, ContainerState.inherit(null, null));
        ContainerState.TabContainer child = ContainerState.inherit(lockedA, null);
        assertEquals(lockedA, ContainerState.inherit(child, ID2));
    }

    @Test
    public void containerForNewTabPriority() {
        ContainerState s = state(ID1, ID2);
        s.create("A", null);
        s.create("B", null);
        s.setSiteRule("github.com", ID2);
        ContainerState.TabContainer lockedA = tc(ID1, true), openA = tc(ID1, false);
        assertEquals(lockedA, s.childOf(lockedA, ID2));
        assertEquals(openA, s.childOf(openA, "ghost"));
        assertEquals(UN, s.childOf(tc("ghost", true), null));
        assertEquals(lockedA, s.containerForNewTab("https://github.com", lockedA, ID2));
        assertEquals(UN, s.containerForNewTab("https://github.com", openA, "default"));
        assertEquals(tc(ID2, false), s.containerForNewTab("https://api.github.com/x", openA, null));
        assertEquals(openA, s.containerForNewTab("https://example.com", openA, null));
        assertEquals(UN, s.containerForNewTab("https://example.com", null, null));
    }

    @Test
    public void siteRules() {
        assertEquals("example.com", ContainerState.normalizeHost("https://WWW.Example.com:8443/a?b"));
        assertEquals("sub.example.com", ContainerState.normalizeHost("sub.example.com/path"));
        assertEquals("example.com", ContainerState.normalizeHost("example.com:8080"));
        assertNull(ContainerState.normalizeHost("localhost"));
        assertNull(ContainerState.normalizeHost("javascript:alert(1)"));
        assertNull(ContainerState.normalizeHost(""));
        ContainerState s = state(ID1, ID2);
        s.create("A", null);
        s.create("B", null);
        s.setSiteRule("example.com", ID1);
        s.setSiteRule("mail.example.com", ID2);
        assertEquals(ID2, s.containerForUrl("https://x.mail.example.com/"));
        assertEquals(ID1, s.containerForUrl("https://www.example.com/"));
        assertNull(s.containerForUrl("https://notexample.com/"));
        assertNull(s.containerForUrl("file:///etc/passwd"));
        assertThrowsMsg("非默认", () -> s.setSiteRule("a.com", "default"));
        assertThrowsMsg("非默认", () -> s.setSiteRule("a.com", ID3));
        assertThrowsMsg("无效的域名", () -> s.setSiteRule("nope", ID1));
        s.setSiteRule("a.com", ID1);
        s.setSiteRule("A.com", ID1);
        assertEquals(3, s.siteRules().size());
        s.removeSiteRule("https://a.com/");
        assertEquals(2, s.siteRules().size());
    }

    @Test
    public void removeCleansMappingsAndRules() {
        ContainerState s = state(ID1, ID2);
        s.create("A", null);
        s.create("B", null);
        s.setTab("t1", ID1, true);
        s.setTab("t2", ID1, false);
        s.setTab("t3", ID2, true);
        s.setSiteRule("a.com", ID1);
        List<String> keys = s.remove(ID1);
        assertEquals(Arrays.asList("t1", "t2"), keys);
        assertEquals(UN, s.getTab("t1"));
        assertEquals(tc(ID2, true), s.getTab("t3"));
        assertNull(s.containerForUrl("https://a.com"));
        assertEquals(Collections.singletonList(ID1), s.pendingRemovals());
        assertEquals(Collections.singletonList(ID1), ContainerState.parse(s.toJson()).pendingRemovals());
        s.markRemoved(ID1);
        assertTrue(s.pendingRemovals().isEmpty());
        assertThrowsMsg("不存在", () -> s.remove(ID1));
    }

    @Test
    public void colors() {
        assertEquals(0xFF37ADFF, ContainerState.argb("blue"));
        assertEquals(0xFF8E8E93, ContainerState.argb("nope"));
        assertEquals("蓝", ContainerState.colorName("blue"));
        assertTrue(ContainerState.isContainerId(ID1));
        assertFalse(ContainerState.isContainerId("AAAAAAAA-1111-4111-8111-111111111111"));
        assertFalse(ContainerState.isContainerId("default"));
    }
}
