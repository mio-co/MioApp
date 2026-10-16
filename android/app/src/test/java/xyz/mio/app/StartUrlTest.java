package xyz.mio.app;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNull;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import org.junit.Test;

public class StartUrlTest {
    static final String EXPECTED = "https://mio.300031.xyz/mio/nav";

    @Test
    public void normalizePath() {
        assertEquals("/mio/nav", StartUrl.normalizePath("mio/nav"));
        assertEquals("/mio/nav", StartUrl.normalizePath("/mio/nav"));
        assertEquals("/mio/nav", StartUrl.normalizePath(" //mio/nav "));
        assertNull(StartUrl.normalizePath("  "));
        assertNull(StartUrl.normalizePath(null));
    }

    @Test
    public void resolve() {
        assertEquals(EXPECTED, StartUrl.resolve("https://mio.300031.xyz", "mio/nav"));
        assertEquals(EXPECTED, StartUrl.resolve("https://mio.300031.xyz/", "/mio/nav"));
        assertEquals(EXPECTED, StartUrl.resolve("https://mio.300031.xyz", "/mio/nav"));
        assertEquals("https://mio.300031.xyz", StartUrl.resolve("https://mio.300031.xyz", null));
    }

    /** 仓库里的 capacitor.config.json 经 Capacitor Android 的「字符串拼接」后，必须正好是 /mio/nav */
    @Test
    public void capacitorConfigProducesExpectedStartUrl() throws Exception {
        File f = new File("../../capacitor.config.json");
        if (!f.exists()) f = new File("../../../capacitor.config.json");
        String json = new String(Files.readAllBytes(f.toPath()), StandardCharsets.UTF_8);
        String url = group(json, "\"url\"\\s*:\\s*\"([^\"]+)\"");
        String start = group(json, "\"appStartPath\"\\s*:\\s*\"([^\"]*)\"");
        // MainActivity 先规范化 appStartPath，再交给 Capacitor 拼接
        assertEquals(EXPECTED, StartUrl.capacitorConcat(url, StartUrl.normalizePath(start)));
        // 配置本身也应已带前导 "/"（iOS / 未规范化路径也正确）
        assertEquals(EXPECTED, StartUrl.capacitorConcat(url, start));
    }

    private static String group(String s, String re) {
        Matcher m = Pattern.compile(re).matcher(s);
        if (!m.find()) throw new AssertionError("missing " + re);
        return m.group(1);
    }
}
