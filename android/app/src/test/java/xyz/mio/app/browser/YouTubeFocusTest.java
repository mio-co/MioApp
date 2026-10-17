package xyz.mio.app.browser;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;

import org.junit.Test;

/** 共享脚本 shared/scripts/youtube-focus.js（APK 里 assets/scripts/youtube-focus.js）+ 占位符替换，与 iOS MioWebCompat.youtubeFocusScript 一致 */
public class YouTubeFocusTest {
    private static String shared() throws Exception {
        File f = new File("../../shared/scripts/youtube-focus.js");
        if (!f.exists()) f = new File("../shared/scripts/youtube-focus.js");
        return new String(Files.readAllBytes(f.toPath()), StandardCharsets.UTF_8);
    }

    @Test
    public void rendersPlaceholdersAndClampsInterval() throws Exception {
        String tpl = shared();
        assertTrue(tpl.contains("__MIO_YT_INTERVAL_MS__"));
        assertTrue(tpl.contains("__MIO_YT_PLAYABLES__"));
        String js = YouTubeFocus.render(tpl, 60, true);
        assertTrue(js.contains("Number('60000')"));
        assertTrue(js.contains("'1' !== '0'"));
        assertFalse(js.contains("__MIO_YT_"));
        assertTrue(YouTubeFocus.render(tpl, 1, false).contains("Number('5000')"));
        assertTrue(YouTubeFocus.render(tpl, 1, false).contains("'0' !== '0'"));
        assertTrue(YouTubeFocus.render(tpl, 99999, true).contains("Number('3600000')"));
        assertFalse(tpl.contains("innerHTML"));
    }

    @Test
    public void youtubeHosts() {
        assertTrue(YouTubeFocus.isYouTubeHost("m.youtube.com"));
        assertTrue(YouTubeFocus.isYouTubeHost("www.YouTube.com"));
        assertTrue(YouTubeFocus.isYouTubeHost("youtube.com"));
        assertFalse(YouTubeFocus.isYouTubeHost("notyoutube.com"));
        assertFalse(YouTubeFocus.isYouTubeHost("youtube.com.evil.example"));
        assertFalse(YouTubeFocus.isYouTubeHost(null));
        assertEquals("1 分钟", YouTubeFocus.intervalText(60));
        assertEquals("30 秒", YouTubeFocus.intervalText(30));
    }
}
