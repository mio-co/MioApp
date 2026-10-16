package xyz.mio.app;

import java.net.URI;

/**
 * 起始 URL 规范化。
 *
 * Capacitor Android 的 Bridge 直接字符串拼接 server.url + server.appStartPath：
 * "https://mio.300031.xyz" + "mio/nav" → "https://mio.300031.xyzmio/nav"（v0.3.0 安卓 net::ERR_CONNECTION_CLOSED）。
 * 这里统一成以 "/" 开头的路径，并用 URI 解析得到真正的起始地址。
 */
public final class StartUrl {
    private StartUrl() {}

    /** "mio/nav" / "/mio/nav" / " //mio/nav " → "/mio/nav"；空 → null */
    public static String normalizePath(String path) {
        if (path == null) return null;
        String p = path.trim();
        if (p.isEmpty()) return null;
        while (p.startsWith("//")) p = p.substring(1);
        if (!p.startsWith("/")) p = "/" + p;
        return p;
    }

    /** 用 URI 解析拼出起始地址：resolve("https://mio.300031.xyz", "mio/nav") → "https://mio.300031.xyz/mio/nav" */
    public static String resolve(String serverUrl, String startPath) {
        String path = normalizePath(startPath);
        URI base = URI.create(serverUrl.trim());
        if (path == null) return base.toString();
        return base.resolve(path).toString();
    }

    /** Capacitor Bridge 的拼接方式（serverUrl + startPath），用于校验配置不会拼错 */
    public static String capacitorConcat(String serverUrl, String startPath) {
        String url = serverUrl;
        if (startPath != null && !startPath.trim().isEmpty()) url += startPath;
        return url;
    }
}
