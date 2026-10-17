package xyz.mio.app.update;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

import java.io.ByteArrayInputStream;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.Collections;
import java.util.Map;
import java.util.Random;

import org.junit.Test;

public class UpdateLogicTest {
    static final String H = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"; // sha256("abc")

    @Test
    public void compareVersions() {
        assertEquals(Integer.valueOf(1), UpdateLogic.compareVersions("0.3.3", "0.3.2"));
        assertEquals(Integer.valueOf(0), UpdateLogic.compareVersions("v0.3.2", "0.3.2"));
        assertEquals(Integer.valueOf(0), UpdateLogic.compareVersions("0.3", "0.3.0"));
        assertEquals(Integer.valueOf(1), UpdateLogic.compareVersions("0.10.0", "0.9.9"));
        assertEquals(Integer.valueOf(1), UpdateLogic.compareVersions("1.0.0", "1.0.0-beta.2"));
        assertEquals(Integer.valueOf(-1), UpdateLogic.compareVersions("1.0.0-beta.2", "1.0.0-beta.10"));
        assertEquals(Integer.valueOf(-1), UpdateLogic.compareVersions("1.0.0-alpha", "1.0.0-alpha.1"));
        assertEquals(Integer.valueOf(1), UpdateLogic.compareVersions("1.0.0-alpha.beta", "1.0.0-alpha.1"));
        assertEquals(Integer.valueOf(0), UpdateLogic.compareVersions("1.0.0+build.5", "1.0.0"));
        assertNull(UpdateLogic.compareVersions("latest", "1.0.0"));
        assertNull(UpdateLogic.compareVersions(null, "1.0.0"));
        assertTrue(UpdateLogic.isNewer("v0.3.3", "0.3.2"));
        assertFalse(UpdateLogic.isNewer("v0.3.2", "0.3.2"));
        assertFalse(UpdateLogic.isNewer("x", "0.3.2"));
    }

    static final String RELEASE = "{\"tag_name\":\"v0.3.3\",\"name\":\"Mio v0.3.3\",\"body\":\"## 新功能\\n- **更新**\","
            + "\"html_url\":\"https://github.com/mio-co/MioApp/releases/tag/v0.3.3\",\"draft\":false,\"prerelease\":false,"
            + "\"assets\":[{\"name\":\"Mio.apk\",\"browser_download_url\":\"https://github.com/mio-co/MioApp/releases/download/v0.3.3/Mio.apk\",\"size\":123,\"digest\":\"sha256:" + H + "\"},"
            + "{\"name\":\"Mio.apk.sha256\",\"browser_download_url\":\"https://github.com/x/Mio.apk.sha256\",\"size\":74,\"digest\":null},"
            + "{\"name\":\"evil\",\"browser_download_url\":\"http://insecure/evil\",\"size\":1}]}";

    @Test
    public void parseRelease() throws Exception {
        UpdateLogic.Release r = UpdateLogic.parseRelease(RELEASE);
        assertNotNull(r);
        assertEquals("0.3.3", r.version);
        assertEquals("v0.3.3", r.tag);
        assertEquals(2, r.assets.size());
        assertEquals(123, r.asset("Mio.apk").size);
        assertEquals("sha256:" + H, r.asset("Mio.apk").digest);
        assertNull(r.asset("Mio.apk.sha256").digest);
        assertNull(r.asset("evil"));
        assertNull(UpdateLogic.parseRelease(RELEASE.replace("\"prerelease\":false", "\"prerelease\":true")));
        assertNull(UpdateLogic.parseRelease(RELEASE.replace("\"draft\":false", "\"draft\":true")));
        assertNull(UpdateLogic.parseRelease(RELEASE.replace("v0.3.3\",\"name", "nightly\",\"name")));
        assertEquals(UpdateLogic.RELEASES_PAGE, UpdateLogic.parseRelease(RELEASE.replace("https://github.com/mio-co/MioApp/releases/tag/v0.3.3", "https://evil/")).url);
    }

    @Test
    public void sha256SumsAndExpected() throws Exception {
        Map<String, String> sums = UpdateLogic.parseSha256Sums("# x\r\n" + H.toUpperCase() + " *Mio.apk\nSHA256 (Mio-0.3.3-mac.zip) = " + H + "\n");
        assertEquals(H, sums.get("Mio.apk"));
        assertEquals(H, sums.get("Mio-0.3.3-mac.zip"));
        assertEquals(H, UpdateLogic.parseSha256Sums(H + "\n").get(""));

        UpdateLogic.Release r = UpdateLogic.parseRelease(RELEASE);
        UpdateLogic.Asset apk = r.asset("Mio.apk");
        assertEquals(H, UpdateLogic.expectedSha256(apk, sums));
        assertEquals(H, UpdateLogic.expectedSha256(apk, null)); // 只有 GitHub digest
        assertEquals(H, UpdateLogic.expectedSha256(r.asset("Mio.apk.sha256"), UpdateLogic.parseSha256Sums(H))); // 只有哈希一行
        try {
            UpdateLogic.expectedSha256(apk, UpdateLogic.parseSha256Sums(repeat('0', 64) + "  Mio.apk"));
            fail("mismatch must throw");
        } catch (IllegalStateException expected) { /* ok */ }
        try {
            UpdateLogic.expectedSha256(r.asset("Mio.apk.sha256"), null);
            fail("missing must throw");
        } catch (IllegalStateException expected) { /* ok */ }
    }

    @Test
    public void sha256Streaming() throws Exception {
        assertEquals(H, UpdateLogic.sha256Hex(new ByteArrayInputStream("abc".getBytes(StandardCharsets.UTF_8))));
        assertEquals("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", UpdateLogic.sha256Hex(new ByteArrayInputStream(new byte[0])));
        byte[] big = new byte[3 * 64 * 1024 + 17];
        new Random(1).nextBytes(big);
        String a = UpdateLogic.sha256Hex(new ByteArrayInputStream(big));
        java.security.MessageDigest md = java.security.MessageDigest.getInstance("SHA-256");
        assertEquals(UpdateLogic.hex(md.digest(big)), a);
        assertTrue(UpdateLogic.sha256Matches(a, a.toUpperCase() + " "));
        assertFalse(UpdateLogic.sha256Matches(a, H));
        assertFalse(UpdateLogic.sha256Matches(null, H));
    }

    @Test
    public void signersMatch() {
        assertTrue(UpdateLogic.signersMatch(Arrays.asList("AA", "bb"), Collections.singletonList("aa")));
        assertTrue(UpdateLogic.signersMatch(Arrays.asList("aa", "bb"), Arrays.asList("bb", "aa")));
        assertFalse(UpdateLogic.signersMatch(Collections.singletonList("aa"), Collections.singletonList("cc")));
        assertFalse(UpdateLogic.signersMatch(Collections.singletonList("aa"), Arrays.asList("aa", "cc")));
        assertFalse(UpdateLogic.signersMatch(Collections.<String>emptyList(), Collections.singletonList("aa")));
        assertFalse(UpdateLogic.signersMatch(Collections.singletonList("aa"), Collections.<String>emptyList()));
    }

    @Test
    public void shouldAutoCheck() {
        long h = 3600_000L, now = 100 * 24 * h;
        assertTrue(UpdateLogic.shouldAutoCheck(true, 0, 0, now));
        assertFalse(UpdateLogic.shouldAutoCheck(false, 0, 0, now));
        assertFalse(UpdateLogic.shouldAutoCheck(true, now - 23 * h, now - 23 * h, now));
        assertTrue(UpdateLogic.shouldAutoCheck(true, now - 25 * h, now - 2 * h, now));
        assertFalse(UpdateLogic.shouldAutoCheck(true, now - 25 * h, now - h / 2, now));
        assertTrue(UpdateLogic.shouldAutoCheck(true, now + 5 * h, now + 5 * h, now));
    }

    @Test
    public void plainNotes() {
        assertEquals("新功能\n- 更新 x", UpdateLogic.plainNotes("## 新功能\n- **更新** `x`", 100));
        assertEquals(5, UpdateLogic.plainNotes("yyyyyyyyyy", 5).length());
    }

    static String repeat(char c, int n) {
        char[] a = new char[n];
        Arrays.fill(a, c);
        return new String(a);
    }
}
