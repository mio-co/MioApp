package xyz.mio.app.browser;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.Arrays;
import java.util.Collections;
import org.junit.Test;

public class WebRtcGuardTest {
    @Test
    public void normalize() {
        assertEquals("meet.google.com", WebRtcGuard.normalize(" https://www.Meet.Google.com/abc?x#y "));
        assertEquals("zoom.us", WebRtcGuard.normalize("user@zoom.us:443"));
        assertEquals("discord.com", WebRtcGuard.normalize("*.discord.com."));
        assertEquals("", WebRtcGuard.normalize(null));
    }

    @Test
    public void entryFor() {
        java.util.List<String> list = Arrays.asList("meet.google.com", "zoom.us");
        assertEquals("meet.google.com", WebRtcGuard.entryFor("meet.google.com", list));
        assertEquals("meet.google.com", WebRtcGuard.entryFor("a.meet.google.com", list));
        assertNull(WebRtcGuard.entryFor("google.com", list));
        assertNull(WebRtcGuard.entryFor("evilmeet.google.com", list));
        assertNull(WebRtcGuard.entryFor(null, list));
    }

    @Test
    public void scriptFromAsset() throws Exception {
        // 单测工作目录 = android/app
        File asset = new File("src/main/assets/" + WebRtcGuard.ASSET);
        assertTrue("asset missing: " + asset.getAbsolutePath(), asset.exists());
        String tpl = new String(Files.readAllBytes(asset.toPath()), StandardCharsets.UTF_8);
        assertTrue(tpl.contains(WebRtcGuard.PLACEHOLDER));
        String js = WebRtcGuard.buildScript(tpl, Arrays.asList("meet.google.com", "a\"b"));
        assertFalse(js.contains(WebRtcGuard.PLACEHOLDER));
        assertTrue(js.contains("var CFG = {\"allow\":[\"meet.google.com\",\"a\\\"b\"]};"));
        assertEquals("{\"allow\":[]}", WebRtcGuard.configJson(Collections.emptyList()));
    }
}
