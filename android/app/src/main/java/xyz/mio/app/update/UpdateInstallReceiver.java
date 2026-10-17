package xyz.mio.app.update;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageInstaller;
import android.os.Build;
import android.util.Log;
import android.widget.Toast;

/** PackageInstaller 会话结果：需要用户确认时弹系统安装确认页；失败时提示原因 */
public class UpdateInstallReceiver extends BroadcastReceiver {
    static final String TAG = "MioUpdate";

    @Override
    @SuppressWarnings("deprecation")
    public void onReceive(Context context, Intent intent) {
        if (!UpdateManager.ACTION_INSTALL_STATUS.equals(intent.getAction())) return;
        int status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE);
        String msg = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE);
        Log.i(TAG, "install status " + status + " " + msg);
        switch (status) {
            case PackageInstaller.STATUS_PENDING_USER_ACTION: {
                Intent confirm = Build.VERSION.SDK_INT >= 33
                        ? intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent.class)
                        : intent.getParcelableExtra(Intent.EXTRA_INTENT);
                if (confirm != null) {
                    confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                    try {
                        context.startActivity(confirm);
                    } catch (Exception e) {
                        Log.w(TAG, "cannot show install confirmation", e);
                        Toast.makeText(context, "无法打开安装确认页：" + e.getMessage(), Toast.LENGTH_LONG).show();
                    }
                }
                break;
            }
            case PackageInstaller.STATUS_SUCCESS:
                Toast.makeText(context, "Mio 已更新", Toast.LENGTH_SHORT).show();
                break;
            case PackageInstaller.STATUS_FAILURE_ABORTED:
                Toast.makeText(context, "已取消更新", Toast.LENGTH_SHORT).show();
                break;
            case PackageInstaller.STATUS_FAILURE_CONFLICT:
            case PackageInstaller.STATUS_FAILURE_INCOMPATIBLE:
                Toast.makeText(context, "安装失败：与已安装的版本冲突（签名不同？）" + (msg != null ? "\n" + msg : ""), Toast.LENGTH_LONG).show();
                break;
            case PackageInstaller.STATUS_FAILURE_STORAGE:
                Toast.makeText(context, "安装失败：存储空间不足", Toast.LENGTH_LONG).show();
                break;
            default:
                Toast.makeText(context, "安装失败" + (msg != null ? "：" + msg : ""), Toast.LENGTH_LONG).show();
        }
    }
}
