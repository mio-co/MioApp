package xyz.mio.app.adblock;

/**
 * JNI 绑定：native/mioadblock（Rust：Brave adblock-rust + AdGuard 高级规则索引 + AdGuard Scriptlets 代码生成）。
 * handle 由调用方用读写锁保护（见 AdblockStore）：shouldBlock / pageScript / genericCss 可并发，free / setResources 独占。
 */
public final class AdblockNative {
    private static boolean loaded;
    private static Throwable loadError;

    static {
        try {
            System.loadLibrary("mioadblock");
            loaded = true;
        } catch (Throwable t) {
            loadError = t;
        }
    }

    private AdblockNative() {}

    public static boolean isLoaded() { return loaded; }
    public static Throwable loadError() { return loadError; }

    public static native long build(String[] lists);
    public static native long load(byte[] serialized);
    public static native byte[] serialize(long handle);
    /** 返回 scriptlets 版本；失败 null */
    public static native String setResources(long handle, String scriptletsCorelibsJson, String extendedCssLib);
    public static native boolean shouldBlock(long handle, String url, String sourceUrl, String requestType);
    public static native String pageScript(long handle, String url);
    public static native String genericCss(long handle, String url, String json);
    public static native String stats(long handle);
    public static native void free(long handle);
}
