package xyz.mio.app;

import android.os.Bundle;

import com.getcapacitor.BridgeActivity;

import xyz.mio.app.adblock.AdblockUpdateWorker;
import xyz.mio.app.browser.MioBrowserPlugin;

public class MainActivity extends BridgeActivity {
    @Override
    public void onCreate(Bundle savedInstanceState) {
        // 应用内插件要在 super.onCreate（创建 Bridge）之前注册
        registerPlugin(MioBrowserPlugin.class);
        super.onCreate(savedInstanceState);
        // 内置浏览器的拦截规则：每天检查一次；距上次超过 24 小时则马上检查
        AdblockUpdateWorker.schedule(this);
    }
}
