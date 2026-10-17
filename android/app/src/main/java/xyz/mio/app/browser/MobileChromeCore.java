package xyz.mio.app.browser;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Locale;

/**
 * 手机端内置浏览器照搬 iOS 27 Safari 紧凑布局的纯逻辑（不依赖 Android 框架，单测 MobileChromeCoreTest）。
 * 与 iOS ios/App/App/MioMobileChromeCore.swift 同一套规则 / 条目 id：
 * 页面上方没有栏；底部胶囊 [后退][页面菜单][地址栏（域名 + 进度 + 刷新/停止）][标签]；
 * 向下滚动收缩成底部小域名胶囊，向上滚动 / 到顶 / 到底 / 点胶囊恢复；页面菜单收纳原来底部 8 个按钮的全部功能。
 */
public final class MobileChromeCore {
    private MobileChromeCore() {}

    public static final String LAYOUT_COMPACT = "compact";

    /** 地址栏 / 收缩胶囊里的域名：小写、去掉端口 / 账号 / 路径和 www. */
    public static String displayHost(String url) {
        if (url == null) return "";
        String s = url.trim();
        if (s.isEmpty()) return "";
        int i = s.indexOf("://");
        String host = i >= 0 ? s.substring(i + 3) : s;
        for (int k = 0; k < host.length(); k++) {
            char c = host.charAt(k);
            if (c == '/' || c == '?' || c == '#') { host = host.substring(0, k); break; }
        }
        int at = host.lastIndexOf('@');
        if (at >= 0) host = host.substring(at + 1);
        if (host.startsWith("[")) {
            int end = host.indexOf(']');
            return (end > 0 ? host.substring(1, end) : host).toLowerCase(Locale.ROOT);
        }
        int colon = host.lastIndexOf(':');
        if (colon >= 0) host = host.substring(0, colon);
        host = host.toLowerCase(Locale.ROOT);
        if (host.startsWith("www.") && host.substring(4).contains(".")) host = host.substring(4);
        return host;
    }

    // ---------------------------------------------------------------- 滚动收缩（与 iOS MioToolbarAutoHide 同样的阈值规则）

    public static final int NONE = 0, HIDE = 1, SHOW = 2;

    public static final class Collapse {
        public final int threshold;
        private boolean hidden;
        private int accumulated;

        public Collapse(int thresholdPx) { threshold = thresholdPx; }

        public boolean hidden() { return hidden; }

        /** 每次 WebView 滚动。y / oldY：scrollY；maxY：最大 scrollY（内容高度 - 可视高度，<= 0 = 不够一屏） */
        public int scrolled(int y, int oldY, int maxY) {
            if (maxY <= 1) { accumulated = 0; return set(false); }
            if (y <= 0) { accumulated = 0; return set(false); }
            if (y >= maxY - 1) { accumulated = 0; return set(false); }   // 滚到底：显示（Safari）
            int dy = y - oldY;
            if (dy == 0) return NONE;
            if ((dy > 0) != (accumulated > 0) && accumulated != 0) accumulated = 0;
            accumulated += dy;
            if (accumulated > threshold && !hidden && y > threshold) { accumulated = 0; return set(true); }
            if (accumulated < -threshold && hidden) { accumulated = 0; return set(false); }
            return NONE;
        }

        public int forceShow() { accumulated = 0; return set(false); }

        public int forceHide() { accumulated = 0; return set(true); }

        private int set(boolean h) {
            if (h == hidden) return NONE;
            hidden = h;
            return h ? HIDE : SHOW;
        }
    }

    // ---------------------------------------------------------------- 地址栏手势

    public static final int SWIPE_NONE = 0, SWIPE_PREV = 1, SWIPE_NEXT = 2, SWIPE_OVERVIEW = 3;

    /** dx / dy：位移（dp，向右 / 向下为正）；vx / vy：速度（dp/s） */
    public static int classifySwipe(float dx, float dy, float vx, float vy) {
        float ax = Math.abs(dx), ay = Math.abs(dy);
        boolean horizontal = ax > ay * 1.5f, vertical = ay > ax * 1.5f;
        if (horizontal && (ax >= 50 || (ax >= 20 && Math.abs(vx) >= 500))) return dx < 0 ? SWIPE_NEXT : SWIPE_PREV;
        if (vertical && dy < 0 && (ay >= 40 || (ay >= 15 && vy <= -600))) return SWIPE_OVERVIEW;
        return SWIPE_NONE;
    }

    // ---------------------------------------------------------------- 页面菜单（条目 id 与 iOS MenuItem 一致）

    public static final class Section {
        public final String title;
        public final List<String> items;
        Section(String title, List<String> items) { this.title = title; this.items = items; }
    }

    /** Android 页面菜单：翻译的双语 / 仅译文 / 原文 / 自动 / 目标语言在「翻译…」（TranslateBridge.showMenu）里，深色在「存到 Mio 与深色…」里 */
    public static List<Section> menuSections(boolean webPage, String host, boolean adblockEnabled, boolean webrtcGuard) {
        boolean hasHost = host != null && !host.isEmpty();
        List<Section> out = new ArrayList<>();
        List<String> page = new ArrayList<>(Arrays.asList("forward"));
        if (webPage) { page.add("share"); page.add("findInPage"); page.add("requestDesktop"); }
        page.add("openExternal");
        out.add(new Section("页面", page));
        List<String> tools = new ArrayList<>();
        if (webPage) tools.add("translateBilingual");
        tools.add("translateSettings");
        if (webPage) tools.add("reader");
        tools.add("darkSite");
        out.add(new Section("翻译、阅读与外观", tools));
        if (webPage) out.add(new Section("存到 Mio", Arrays.asList("saveBookmark", "saveNote", "saveClip")));
        List<String> privacy = new ArrayList<>(Arrays.asList("adblock"));
        if (hasHost && adblockEnabled) privacy.add("adblockSite");
        if (hasHost && webrtcGuard) privacy.add("webrtcSite");
        privacy.add("userScripts");
        privacy.add("youtubeFocus");
        privacy.add("adblockSettings");
        out.add(new Section("拦截与隐私", privacy));
        out.add(new Section("Mio", Arrays.asList("settings", "backToMio")));
        return out;
    }

    public static String title(String id, boolean desktop) {
        switch (id) {
            case "forward": return "前进";
            case "share": return "分享";
            case "findInPage": return "查找页面内容";
            case "requestDesktop": return desktop ? "请求移动网站" : "请求桌面网站";
            case "openExternal": return "用系统浏览器打开";
            case "translateBilingual": return "翻译…（双语 / 仅译文 / 目标语言）";
            case "translateSettings": return "翻译设置…";
            case "reader": return "阅读模式";
            case "darkSite": return "强制深色 / 存到 Mio 选项…";
            case "saveBookmark": return "存为导航书签";
            case "saveNote": return "存为笔记";
            case "saveClip": return "推到云剪贴板";
            case "adblock": return "广告拦截";
            case "adblockSite": return "在此网站拦截广告";
            case "webrtcSite": return "此网站允许 WebRTC（网页通话）";
            case "userScripts": return "用户脚本…";
            case "youtubeFocus": return "YouTube 防沉迷";
            case "adblockSettings": return "拦截设置…";
            case "settings": return "浏览器设置…";
            case "backToMio": return "回到 Mio 导航";
            default: return id;
        }
    }

    /** 原来底部 8 个按钮 + 顶栏的每个入口的新去处（单测保证一个都不丢） */
    public static final String[][] LEGACY = {
            {"back", "capsule.back"}, {"forward", "menu.forward"}, {"reload", "capsule.reload"}, {"share", "menu.share"},
            {"translate", "menu.translateBilingual"}, {"external", "menu.openExternal"}, {"mio", "menu.saveBookmark"},
            {"settings", "menu.settings"}, {"tabs", "capsule.tabs"}, {"hide", "tabsMenu.backToMio"},
            {"reader", "menu.reader"}, {"shield", "menu.adblock"},
    };

    /** 桌面网站 UA：把 Android 手机 UA 换成 Linux 桌面 Chrome（去掉 Mobile） */
    public static String desktopUserAgent(String mobile) {
        if (mobile == null) return null;
        String ua = mobile.replaceFirst("\\(Linux; Android[^)]*\\)", "(X11; Linux x86_64)");
        return ua.replace(" Mobile Safari/", " Safari/").replace(" Mobile ", " ");
    }
}
