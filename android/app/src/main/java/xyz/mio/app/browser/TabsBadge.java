package xyz.mio.app.browser;

import android.app.Activity;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.FrameLayout;
import android.widget.TextView;

import org.json.JSONObject;

import java.io.File;
import java.io.FileInputStream;
import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;

/**
 * Mio 主界面（MainActivity，主进程）右下角的「N 个标签」角标：内置浏览器收起（或 App 重启后有上次的标签）时显示，点一下回到浏览器。
 * 标签数从浏览器进程写的 files/browser-tabs.json 读（同一个 App 数据目录）。MainActivity.onResume 调用 {@link #refresh}。
 */
public final class TabsBadge {
    private TabsBadge() {}

    private static final int TAG_KEY = 0x4d696f54; // "MioT"

    static int savedCount(Activity a) {
        File f = new File(a.getFilesDir(), "browser-tabs.json");
        if (!f.exists()) return 0;
        try (FileInputStream in = new FileInputStream(f)) {
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
            JSONObject o = new JSONObject(new String(out.toByteArray(), StandardCharsets.UTF_8));
            return o.optJSONArray("tabs") != null ? o.optJSONArray("tabs").length() : 0;
        } catch (Exception e) {
            return 0;
        }
    }

    public static void refresh(Activity a) {
        View content = a.findViewById(android.R.id.content);
        if (!(content instanceof ViewGroup)) return;
        ViewGroup root = (ViewGroup) content;
        TextView badge = root.findViewWithTag(TAG_KEY);
        int count = savedCount(a);
        if (count <= 0) {
            if (badge != null) badge.setVisibility(View.GONE);
            return;
        }
        if (badge == null) {
            badge = new TextView(a);
            badge.setTag(TAG_KEY);
            float d = a.getResources().getDisplayMetrics().density;
            GradientDrawable bg = new GradientDrawable();
            bg.setColor(0xEE111111);
            bg.setCornerRadius(20 * d);
            badge.setBackground(bg);
            badge.setTextColor(Color.WHITE);
            badge.setTypeface(Typeface.DEFAULT_BOLD);
            badge.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14);
            badge.setGravity(Gravity.CENTER);
            badge.setPadding((int) (14 * d), 0, (int) (14 * d), 0);
            badge.setElevation(8 * d);
            badge.setOnClickListener(v -> a.startActivity(BrowserActivity.intent(a, null, false)));
            FrameLayout.LayoutParams lp = new FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, (int) (40 * d), Gravity.BOTTOM | Gravity.END);
            lp.setMargins(0, 0, (int) (14 * d), (int) (96 * d));
            root.addView(badge, lp);
        }
        badge.setText("⧉ " + (count > 99 ? "99+" : String.valueOf(count)));
        badge.setContentDescription(count + " 个标签，回到浏览器");
        badge.setVisibility(View.VISIBLE);
        badge.bringToFront();
    }
}
