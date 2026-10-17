package xyz.mio.app.browser;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.Arrays;
import java.util.Collections;
import org.junit.Test;

public class MioMediaTest {
    private static final String PMID = "android.webkit.resource.PROTECTED_MEDIA_ID";

    @Test
    public void grantsOnlyProtectedMediaId() {
        assertArrayEquals(new String[]{PMID}, MioMedia.grantable(new String[]{PMID}));
        assertArrayEquals(new String[]{PMID}, MioMedia.grantable(new String[]{"android.webkit.resource.VIDEO_CAPTURE", PMID, "android.webkit.resource.AUDIO_CAPTURE"}));
        assertArrayEquals(new String[0], MioMedia.grantable(new String[]{"android.webkit.resource.VIDEO_CAPTURE", "android.webkit.resource.MIDI_SYSEX"}));
        assertArrayEquals(new String[0], MioMedia.grantable(null));
    }

    @Test
    public void configJsonMatchesSwiftShape() {
        assertEquals("{\"platform\":\"android\",\"background\":true,\"nowPlaying\":true,\"pip\":false,\"sponsorBlock\":true,\"categories\":[\"sponsor\",\"selfpromo\",\"interaction\"]}",
                MioMedia.configJson(true, Arrays.asList("interaction", "sponsor", "selfpromo", "bogus")));
        assertEquals("{\"platform\":\"android\",\"background\":true,\"nowPlaying\":true,\"pip\":false,\"sponsorBlock\":false,\"categories\":[]}",
                MioMedia.configJson(false, Collections.emptyList()));
    }

    @Test
    public void defaultsOnlySponsorSelfpromoInteraction() {
        assertEquals(5, MioMedia.CATEGORIES.length);
        assertEquals(MioMedia.CATEGORIES.length, MioMedia.CATEGORY_TITLES.length);
        assertTrue(MioMedia.CATEGORY_DEFAULTS[0] && MioMedia.CATEGORY_DEFAULTS[1] && MioMedia.CATEGORY_DEFAULTS[2]);
        assertFalse(MioMedia.CATEGORY_DEFAULTS[3] || MioMedia.CATEGORY_DEFAULTS[4]);
    }

    @Test
    public void bundledScriptHasPlaceholderAndBuilds() throws Exception {
        // 工作目录是 android/app
        File f = new File("src/main/assets/mio/youtube-media.js");
        String t = new String(Files.readAllBytes(f.toPath()), StandardCharsets.UTF_8);
        assertTrue(t.contains("__MIO_MEDIA_CONFIG__"));
        String js = MioMedia.buildScript(t, MioMedia.configJson(true, Arrays.asList("sponsor")));
        assertFalse(js.contains("__MIO_MEDIA_CONFIG__"));
        assertTrue(js.contains("var CFG = {\"platform\":\"android\""));
        assertFalse(js.contains("innerHTML"));
    }
}
