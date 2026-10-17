package xyz.mio.app.browser;

import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

public class CloseAfterExternalTest {
    @Test
    public void closesWhenEnabledLaunchedAndCovered() {
        CloseAfterExternal c = new CloseAfterExternal();
        assertTrue(c.onLaunchResult(true, true));
        assertTrue(c.onStop(false));
        assertFalse("一次性", c.onStop(false));
    }

    @Test
    public void disabledNeverCloses() {
        CloseAfterExternal c = new CloseAfterExternal();
        assertFalse(c.onLaunchResult(false, true));
        assertFalse(c.onStop(false));
    }

    @Test
    public void launchFailureDoesNotClose() {
        CloseAfterExternal c = new CloseAfterExternal();
        assertFalse(c.onLaunchResult(true, false));
        assertFalse(c.onStop(false));
    }

    @Test
    public void chooserCancelledDoesNotClose() {
        CloseAfterExternal c = new CloseAfterExternal();
        c.onLaunchResult(true, true);
        c.onResume();
        assertFalse(c.onStop(false));
    }

    @Test
    public void rotationDoesNotCloseButKeepsPending() {
        CloseAfterExternal c = new CloseAfterExternal();
        c.onLaunchResult(true, true);
        assertFalse(c.onStop(true));
        assertTrue(c.isPending());
    }

    @Test
    public void plainStopWithoutLaunchDoesNotClose() {
        assertFalse(new CloseAfterExternal().onStop(false));
    }
}
