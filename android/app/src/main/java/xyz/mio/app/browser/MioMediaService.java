package xyz.mio.app.browser;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.graphics.drawable.Icon;
import android.media.session.MediaSession;
import android.media.session.PlaybackState;
import android.os.Build;
import android.os.IBinder;
import android.util.Log;

/**
 * 内置浏览器后台播放的前台服务（:browser 进程）：播放中保持进程存活，显示媒体通知 + MediaSession（锁屏 / 耳机按键：播放、暂停、下一个），
 * 按键经 {@link MioMedia#command} 转给页面的 window.__mioMedia.command。暂停后退出前台状态（通知保留，可再点播放），浏览器关闭时停止。
 */
public class MioMediaService extends Service {
    private static final String CHANNEL = "mio-media";
    private static final int ID = 0x4D10;
    private static final String EXTRA_PLAYING = "playing", EXTRA_TITLE = "title", EXTRA_ARTIST = "artist", EXTRA_CMD = "cmd";

    private MediaSession session;

    static void update(Context c, boolean playing, String title, String artist) {
        Intent i = new Intent(c, MioMediaService.class)
                .putExtra(EXTRA_PLAYING, playing).putExtra(EXTRA_TITLE, title).putExtra(EXTRA_ARTIST, artist);
        try {
            if (playing && Build.VERSION.SDK_INT >= 26) c.startForegroundService(i); else c.startService(i);
        } catch (Exception e) {
            // Android 12+ 不允许从后台启动前台服务（例如在后台自动播放下一个且服务没在运行）：不影响播放本身
            Log.w(MioMedia.TAG, "media service start", e);
        }
    }

    static void stop(Context c) {
        try { c.stopService(new Intent(c, MioMediaService.class)); } catch (Exception ignored) {}
    }

    @Override
    public IBinder onBind(Intent intent) { return null; }

    @Override
    public void onCreate() {
        super.onCreate();
        NotificationManager nm = getSystemService(NotificationManager.class);
        if (Build.VERSION.SDK_INT >= 26 && nm != null) {
            NotificationChannel ch = new NotificationChannel(CHANNEL, "后台播放", NotificationManager.IMPORTANCE_LOW);
            ch.setShowBadge(false);
            nm.createNotificationChannel(ch);
        }
        session = new MediaSession(this, "MioBrowser");
        session.setCallback(new MediaSession.Callback() {
            @Override public void onPlay() { send("play"); }
            @Override public void onPause() { send("pause"); }
            @Override public void onSkipToNext() { send("next"); }
            @Override public void onSkipToPrevious() { send("previous"); }
            @Override public void onStop() { send("pause"); }
        });
        session.setActive(true);
    }

    private static void send(String cmd) {
        MioMedia m = MioMedia.current();
        if (m != null) m.command(cmd);
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent == null) { stopSelf(); return START_NOT_STICKY; }
        String cmd = intent.getStringExtra(EXTRA_CMD);
        if (cmd != null) {
            send(cmd);
            return START_NOT_STICKY;
        }
        boolean playing = intent.getBooleanExtra(EXTRA_PLAYING, false);
        String title = intent.getStringExtra(EXTRA_TITLE);
        String artist = intent.getStringExtra(EXTRA_ARTIST);
        android.media.MediaMetadata md = new android.media.MediaMetadata.Builder()
                .putString(android.media.MediaMetadata.METADATA_KEY_TITLE, title == null ? "" : title)
                .putString(android.media.MediaMetadata.METADATA_KEY_ARTIST, artist == null ? "" : artist)
                .build();
        session.setMetadata(md);
        session.setPlaybackState(new PlaybackState.Builder()
                .setActions(PlaybackState.ACTION_PLAY | PlaybackState.ACTION_PAUSE | PlaybackState.ACTION_PLAY_PAUSE
                        | PlaybackState.ACTION_SKIP_TO_NEXT | PlaybackState.ACTION_SKIP_TO_PREVIOUS)
                .setState(playing ? PlaybackState.STATE_PLAYING : PlaybackState.STATE_PAUSED, PlaybackState.PLAYBACK_POSITION_UNKNOWN, playing ? 1f : 0f)
                .build());
        Notification n = build(playing, title, artist);
        try {
            if (playing) {
                if (Build.VERSION.SDK_INT >= 29) startForeground(ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK);
                else startForeground(ID, n);
            } else {
                stopForeground(STOP_FOREGROUND_DETACH);
                NotificationManager nm = getSystemService(NotificationManager.class);
                if (nm != null) nm.notify(ID, n);
            }
        } catch (Exception e) {
            Log.w(MioMedia.TAG, "startForeground", e);
        }
        return START_NOT_STICKY;
    }

    private PendingIntent action(String cmd, int req) {
        Intent i = new Intent(this, MioMediaService.class).putExtra(EXTRA_CMD, cmd);
        return PendingIntent.getService(this, req, i, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
    }

    private Notification build(boolean playing, String title, String artist) {
        Notification.Builder b = Build.VERSION.SDK_INT >= 26 ? new Notification.Builder(this, CHANNEL) : new Notification.Builder(this);
        Intent open = new Intent(this, BrowserActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP);
        b.setSmallIcon(playing ? android.R.drawable.ic_media_play : android.R.drawable.ic_media_pause)
                .setContentTitle(title == null || title.isEmpty() ? "正在播放" : title)
                .setContentText(artist == null ? "" : artist)
                .setContentIntent(PendingIntent.getActivity(this, 1, open, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE))
                .setDeleteIntent(action("pause", 5))
                .setOngoing(playing)
                .setShowWhen(false)
                .setVisibility(Notification.VISIBILITY_PUBLIC)
                .addAction(new Notification.Action.Builder(Icon.createWithResource(this, android.R.drawable.ic_media_previous), "上一个", action("previous", 2)).build())
                .addAction(new Notification.Action.Builder(Icon.createWithResource(this, playing ? android.R.drawable.ic_media_pause : android.R.drawable.ic_media_play), playing ? "暂停" : "播放", action(playing ? "pause" : "play", 3)).build())
                .addAction(new Notification.Action.Builder(Icon.createWithResource(this, android.R.drawable.ic_media_next), "下一个", action("next", 4)).build())
                .setStyle(new Notification.MediaStyle().setMediaSession(session.getSessionToken()).setShowActionsInCompactView(0, 1, 2));
        return b.build();
    }

    @Override
    public void onDestroy() {
        if (session != null) { session.setActive(false); session.release(); }
        NotificationManager nm = getSystemService(NotificationManager.class);
        if (nm != null) nm.cancel(ID);
        super.onDestroy();
    }
}
