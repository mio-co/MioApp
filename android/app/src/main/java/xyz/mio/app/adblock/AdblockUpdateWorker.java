package xyz.mio.app.adblock;

import android.content.Context;
import android.util.Log;

import androidx.annotation.NonNull;
import androidx.work.Constraints;
import androidx.work.ExistingPeriodicWorkPolicy;
import androidx.work.ExistingWorkPolicy;
import androidx.work.NetworkType;
import androidx.work.OneTimeWorkRequest;
import androidx.work.PeriodicWorkRequest;
import androidx.work.WorkManager;
import androidx.work.Worker;
import androidx.work.WorkerParameters;

import java.util.concurrent.TimeUnit;

/** 每天（WorkManager）+ App 启动时（超过 24h）下载规则更新；浏览器进程下次打开时发现 state.json 变了就重建引擎 */
public class AdblockUpdateWorker extends Worker {
    public AdblockUpdateWorker(@NonNull Context context, @NonNull WorkerParameters params) {
        super(context, params);
    }

    @NonNull
    @Override
    public Result doWork() {
        String msg = AdblockStore.get(getApplicationContext()).update(false);
        Log.i("MioAdblock", "update worker: " + msg);
        return Result.success();
    }

    public static void schedule(Context context) {
        Constraints c = new Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build();
        PeriodicWorkRequest periodic = new PeriodicWorkRequest.Builder(AdblockUpdateWorker.class, 24, TimeUnit.HOURS)
                .setConstraints(c).build();
        WorkManager wm = WorkManager.getInstance(context);
        wm.enqueueUniquePeriodicWork("mio-adblock-update", ExistingPeriodicWorkPolicy.KEEP, periodic);
        if (AdblockStore.get(context).needsUpdate()) {
            wm.enqueueUniqueWork("mio-adblock-update-now", ExistingWorkPolicy.KEEP,
                    new OneTimeWorkRequest.Builder(AdblockUpdateWorker.class).setConstraints(c).build());
        }
    }
}
