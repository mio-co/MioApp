package xyz.mio.app.update;

import android.app.Activity;
import android.app.AlertDialog;
import android.app.Application;
import android.content.Context;
import android.content.Intent;
import android.graphics.Typeface;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.util.TypedValue;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.ScrollView;
import android.widget.Switch;
import android.widget.TextView;
import android.widget.Toast;

import java.io.File;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * 更新相关的对话框和设置区块。
 * - MainActivity.onCreate → attach(activity)：之后每次回到前台自动检查（开关打开且距上次 ≥ 24h），以及从「安装未知应用」设置页回来后继续安装
 * - 浏览器设置页 → addSettingsSection(activity, box)：「自动检查更新」开关 +「立即检查」
 */
public final class UpdateUi {
    private UpdateUi() {}

    static final String TAG = "MioUpdate";
    private static final ExecutorService EXEC = Executors.newSingleThreadExecutor();
    private static final Handler MAIN = new Handler(Looper.getMainLooper());
    private static final AtomicBoolean BUSY = new AtomicBoolean(false);
    /** 等待「安装未知应用」授权后继续安装的 APK（已校验） */
    private static File pendingApk;

    private static boolean callbacksRegistered;
    private static Class<?> autoCheckActivity;

    /**
     * 在 MainActivity.onCreate 里调用：注册生命周期回调，之后它每次回到前台都走 onResume（自动检查）；
     * 本进程的其它 Activity 回到前台时只处理「授权后继续安装」。
     */
    public static void attach(Activity main) {
        autoCheckActivity = main.getClass();
        ensureCallbacks(main.getApplication());
    }

    private static synchronized void ensureCallbacks(Application app) {
        if (callbacksRegistered || app == null) return;
        callbacksRegistered = true;
        app.registerActivityLifecycleCallbacks(new Application.ActivityLifecycleCallbacks() {
            @Override public void onActivityResumed(Activity a) {
                if (autoCheckActivity != null && autoCheckActivity.isInstance(a)) onResume(a);
                else resumePending(a);
            }
            @Override public void onActivityCreated(Activity a, Bundle b) {}
            @Override public void onActivityStarted(Activity a) {}
            @Override public void onActivityPaused(Activity a) {}
            @Override public void onActivityStopped(Activity a) {}
            @Override public void onActivitySaveInstanceState(Activity a, Bundle b) {}
            @Override public void onActivityDestroyed(Activity a) {}
        });
    }

    public static void onResume(Activity a) {
        if (resumePending(a)) return;
        if (!autoCheckDue(a)) return;
        // 冷启动时晚几秒再查，不和首屏加载抢网络
        MAIN.postDelayed(() -> {
            if (alive(a) && autoCheckDue(a)) check(a, false);
        }, 5000);
    }

    /** 从「安装未知应用」设置页回来：已授权就继续安装之前下载好的 APK（浏览器设置页所在的 :browser 进程也调用） */
    public static boolean resumePending(Activity a) {
        if (pendingApk == null || !UpdateManager.canInstall(a)) return false;
        File apk = pendingApk;
        pendingApk = null;
        install(a, apk);
        return true;
    }

    private static boolean autoCheckDue(Context c) {
        return UpdateLogic.shouldAutoCheck(UpdatePrefs.autoCheck(c), UpdatePrefs.lastCheck(c), UpdatePrefs.lastAttempt(c), System.currentTimeMillis());
    }

    public static void checkNow(Activity a) { check(a, true); }

    private static boolean alive(Activity a) { return a != null && !a.isFinishing() && !a.isDestroyed(); }

    private static void check(Activity a, boolean manual) {
        if (!alive(a)) return;
        if (!BUSY.compareAndSet(false, true)) {
            if (manual) Toast.makeText(a, "正在检查更新…", Toast.LENGTH_SHORT).show();
            return;
        }
        Context c = a.getApplicationContext();
        if (manual) Toast.makeText(a, "正在检查更新…", Toast.LENGTH_SHORT).show();
        EXEC.execute(() -> {
            UpdatePrefs.setLastAttempt(c, System.currentTimeMillis());
            UpdateLogic.Release r = null;
            String error = null;
            try {
                r = UpdateManager.fetchLatest(c);
            } catch (Exception e) {
                Log.w(TAG, "check failed", e);
                error = String.valueOf(e.getMessage());
            }
            final UpdateLogic.Release release = r;
            final String err = error;
            String current = UpdateManager.currentVersion(c);
            boolean newer = release != null && UpdateLogic.isNewer(release.version, current);
            boolean hasApk = release != null && release.asset(UpdateLogic.APK_ASSET) != null;
            // 新版本的签名包还没上传时不算检查完成（1 小时后再试）
            if (err == null && (!newer || hasApk)) UpdatePrefs.setLastCheck(c, System.currentTimeMillis());
            MAIN.post(() -> {
                BUSY.set(false);
                if (!alive(a)) return;
                if (err != null) {
                    if (manual) message(a, "检查更新失败", err, null);
                    return;
                }
                if (!newer) {
                    if (manual) message(a, "已是最新版本", "当前版本 " + current + (release != null ? "，最新发布 " + release.version : "") + "。", null);
                    return;
                }
                if (!hasApk) {
                    if (manual) message(a, "发现新版本 " + release.version, "签名安装包 Mio.apk 还没上传到 Release，请稍后再试，或打开下载页查看。", release.url);
                    return;
                }
                if (!manual && release.version.equals(UpdatePrefs.skipVersion(c))) return;
                showUpdate(a, release, manual);
            });
        });
    }

    private static void showUpdate(Activity a, UpdateLogic.Release r, boolean manual) {
        String notes = UpdateLogic.plainNotes(r.notes, 3000);
        UpdateLogic.Asset apk = r.asset(UpdateLogic.APK_ASSET);
        String size = apk != null && apk.size > 0 ? String.format(Locale.ROOT, "安装包 %.1f MB\n\n", apk.size / 1048576.0) : "";
        TextView body = new TextView(a);
        body.setText(size + (notes.isEmpty() ? "（无更新说明）" : notes));
        body.setTextIsSelectable(true);
        body.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14);
        int pad = (int) (20 * a.getResources().getDisplayMetrics().density);
        body.setPadding(pad, pad / 2, pad, 0);
        ScrollView scroll = new ScrollView(a);
        scroll.addView(body);
        AlertDialog.Builder b = new AlertDialog.Builder(a)
                .setTitle("发现新版本 " + r.version + "（当前 " + UpdateManager.currentVersion(a) + "）")
                .setView(scroll)
                .setPositiveButton("更新", (d, w) -> download(a, r))
                .setNegativeButton("稍后", null);
        if (!manual) b.setNeutralButton("跳过此版本", (d, w) -> UpdatePrefs.setSkipVersion(a, r.version));
        else b.setNeutralButton("下载页", (d, w) -> openUrl(a, r.url));
        b.show();
    }

    private static void download(Activity a, UpdateLogic.Release r) {
        if (!alive(a)) return;
        int pad = (int) (20 * a.getResources().getDisplayMetrics().density);
        LinearLayout box = new LinearLayout(a);
        box.setOrientation(LinearLayout.VERTICAL);
        box.setPadding(pad, pad / 2, pad, 0);
        ProgressBar bar = new ProgressBar(a, null, android.R.attr.progressBarStyleHorizontal);
        bar.setMax(1000);
        bar.setIndeterminate(true);
        TextView label = new TextView(a);
        label.setText("正在下载…");
        box.addView(bar);
        box.addView(label);
        AtomicBoolean cancelled = new AtomicBoolean(false);
        AlertDialog dlg = new AlertDialog.Builder(a)
                .setTitle("下载 Mio " + r.version)
                .setView(box)
                .setCancelable(false)
                .setNegativeButton("取消", (d, w) -> cancelled.set(true))
                .show();
        Context c = a.getApplicationContext();
        EXEC.execute(() -> {
            File apk = null;
            Exception error = null;
            try {
                apk = UpdateManager.download(c, r, new UpdateManager.Progress() {
                    long lastPost;
                    @Override public void onProgress(long done, long total) {
                        long now = System.currentTimeMillis();
                        if (now - lastPost < 150 && done < total) return;
                        lastPost = now;
                        MAIN.post(() -> {
                            if (total > 0) {
                                bar.setIndeterminate(false);
                                bar.setProgress((int) (done * 1000 / total));
                                label.setText(String.format(Locale.ROOT, "%.1f / %.1f MB", done / 1048576.0, total / 1048576.0));
                            } else {
                                label.setText(String.format(Locale.ROOT, "%.1f MB", done / 1048576.0));
                            }
                        });
                    }
                    @Override public boolean cancelled() { return cancelled.get(); }
                });
                MAIN.post(() -> label.setText("正在校验签名…"));
                UpdateManager.verifyApk(c, apk);
            } catch (Exception e) {
                Log.w(TAG, "download / verify failed", e);
                error = e;
            }
            final File file = apk;
            final Exception err = error;
            MAIN.post(() -> {
                try { dlg.dismiss(); } catch (Exception ignored) {}
                if (!alive(a)) return;
                if (cancelled.get()) return;
                if (err instanceof UpdateManager.SignatureMismatchException) {
                    message(a, "无法自动更新", err.getMessage() + "。请卸载当前版本后从下载页安装 Mio.apk（会清除 App 数据）。", r.url);
                    return;
                }
                if (err != null) {
                    message(a, "更新失败", String.valueOf(err.getMessage()), r.url);
                    return;
                }
                install(a, file);
            });
        });
    }

    private static void install(Activity a, File apk) {
        if (!alive(a)) return;
        if (!UpdateManager.canInstall(a)) {
            pendingApk = apk;
            ensureCallbacks(a.getApplication());
            new AlertDialog.Builder(a)
                    .setTitle("需要授权安装")
                    .setMessage("请在接下来的系统设置里允许 Mio「安装未知应用」，返回后会继续安装（安装包已下载并校验）。")
                    .setPositiveButton("去设置", (d, w) -> {
                        try { a.startActivity(UpdateManager.unknownSourcesSettings(a)); } catch (Exception e) { pendingApk = null; Toast.makeText(a, String.valueOf(e.getMessage()), Toast.LENGTH_LONG).show(); }
                    })
                    .setNegativeButton("取消", (d, w) -> pendingApk = null)
                    .show();
            return;
        }
        Context c = a.getApplicationContext();
        EXEC.execute(() -> {
            try {
                UpdateManager.install(c, apk);
            } catch (Exception e) {
                Log.w(TAG, "PackageInstaller failed, falling back to ACTION_INSTALL_PACKAGE", e);
                MAIN.post(() -> {
                    try {
                        a.startActivity(UpdateManager.viewIntent(a, apk));
                    } catch (Exception e2) {
                        message(a, "安装失败", String.valueOf(e2.getMessage()), UpdateLogic.RELEASES_PAGE);
                    }
                });
            }
        });
    }

    private static void message(Activity a, String title, String msg, String url) {
        if (!alive(a)) return;
        AlertDialog.Builder b = new AlertDialog.Builder(a).setTitle(title).setMessage(msg).setPositiveButton("好", null);
        if (url != null) b.setNeutralButton("打开下载页", (d, w) -> openUrl(a, url));
        b.show();
    }

    private static void openUrl(Activity a, String url) {
        try {
            a.startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
        } catch (Exception e) {
            Toast.makeText(a, String.valueOf(e.getMessage()), Toast.LENGTH_LONG).show();
        }
    }

    /** 浏览器设置页里的「软件更新」区块 */
    public static void addSettingsSection(Activity a, LinearLayout box) {
        TextView title = new TextView(a);
        title.setText("\n软件更新（GitHub Releases）");
        title.setTypeface(Typeface.DEFAULT_BOLD);
        box.addView(title);

        Switch auto = new Switch(a);
        auto.setText("自动检查更新（每 24 小时）");
        auto.setChecked(UpdatePrefs.autoCheck(a));
        auto.setOnCheckedChangeListener((v, on) -> UpdatePrefs.setAutoCheck(a, on));
        box.addView(auto);

        TextView status = new TextView(a);
        long last = UpdatePrefs.lastCheck(a);
        status.setText("当前版本 " + UpdateManager.currentVersion(a) + " · 上次检查 "
                + (last > 0 ? new SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.ROOT).format(new Date(last)) : "从未")
                + (UpdatePrefs.debuggable(a) ? "\n调试版与正式版 Mio.apk 签名不同，不能直接覆盖安装" : ""));
        status.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
        box.addView(status);

        Button check = new Button(a);
        check.setText("立即检查更新");
        check.setOnClickListener(v -> checkNow(a));
        box.addView(check);
    }
}
