package xyz.mio.app.containers;

import android.app.Activity;
import android.app.AlertDialog;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.text.InputFilter;
import android.text.InputType;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import java.util.List;

/**
 * 设置页「容器管理」：增删改名、选颜色、删除二次确认（清数据）、站点默认容器规则。
 * 浏览器设置里调用 {@link #addSettingsButton(Activity, LinearLayout)}。
 */
public final class ContainerUi {
    private ContainerUi() {}

    /** 「打开此容器」：内置浏览器设置的回调（在该容器里开新标签）；null = 不显示按钮 */
    public interface Opener { void open(String containerId); }
    public static Opener opener;

    /** 浏览器设置页里的入口按钮 */
    public static void addSettingsButton(Activity a, LinearLayout box) {
        Button b = new Button(a);
        b.setText(buttonText(a));
        b.setOnClickListener(v -> show(a, () -> b.setText(buttonText(a))));
        box.addView(b);
    }

    private static String buttonText(Activity a) {
        if (!ContainerManager.isSupported()) return "容器（登录隔离）…";
        return "容器（登录隔离，" + ContainerManager.get(a).list().size() + " 个）…";
    }

    private static int dp(Activity a, int v) {
        return Math.round(TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, a.getResources().getDisplayMetrics()));
    }

    private static View dot(Activity a, String color, int sizeDp) {
        View v = new View(a);
        GradientDrawable g = new GradientDrawable();
        g.setShape(GradientDrawable.OVAL);
        g.setColor(ContainerState.argb(color));
        v.setBackground(g);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(dp(a, sizeDp), dp(a, sizeDp));
        lp.setMarginEnd(dp(a, 12));
        lp.gravity = Gravity.CENTER_VERTICAL;
        v.setLayoutParams(lp);
        return v;
    }

    /** 容器列表对话框 */
    public static void show(Activity a, Runnable onClose) {
        ContainerManager cm = ContainerManager.get(a);
        boolean supported = ContainerManager.isSupported();
        ScrollView scroll = new ScrollView(a);
        LinearLayout box = new LinearLayout(a);
        box.setOrientation(LinearLayout.VERTICAL);
        box.setPadding(dp(a, 20), dp(a, 8), dp(a, 20), dp(a, 8));
        scroll.addView(box);
        AlertDialog[] holder = new AlertDialog[1];
        Runnable reopen = () -> {
            if (holder[0] != null) holder[0].dismiss();
            show(a, onClose);
        };

        TextView intro = new TextView(a);
        intro.setText(supported
                ? "每个容器有独立的 Cookie、LocalStorage、IndexedDB 和缓存，同一网站可以在不同容器里登录不同账号。「默认」就是原来的浏览数据。点容器可改名、换颜色或删除。"
                : "当前系统的 Android System WebView 版本过旧，不支持多配置文件（MULTI_PROFILE），只能使用默认容器。\n请在 Google Play 更新「Android System WebView」（或 Chrome）后重试。");
        box.addView(intro);

        for (ContainerState.Container c : cm.list()) {
            LinearLayout row = new LinearLayout(a);
            row.setOrientation(LinearLayout.HORIZONTAL);
            row.setGravity(Gravity.CENTER_VERTICAL);
            row.setPadding(0, dp(a, 12), 0, dp(a, 12));
            row.addView(dot(a, c.color, 14));
            TextView t = new TextView(a);
            int tabs = c.isDefault() ? 0 : cm.state().tabsIn(c.id).size();
            t.setText(c.name + (c.isDefault() ? "  ·  原来的浏览数据" : "  ·  " + ContainerState.colorName(c.color) + (tabs > 0 ? " · " + tabs + " 个标签" : "")));
            t.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16);
            row.addView(t, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1));
            if (opener != null && (supported || c.isDefault())) {
                Button open = new Button(a);
                open.setText("打开");
                open.setAllCaps(false);
                open.setContentDescription("打开容器 " + c.name);
                final String cid = c.id;
                open.setOnClickListener(v -> {
                    if (holder[0] != null) holder[0].dismiss();
                    Opener o = opener;
                    if (o != null) o.open(cid);
                });
                row.addView(open, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT));
            }
            if (!c.isDefault()) {
                row.setClickable(true);
                row.setOnClickListener(v -> editContainer(a, c, reopen));
            }
            box.addView(row);
        }

        Button add = new Button(a);
        add.setText("新建容器…");
        add.setEnabled(supported && cm.state().canCreate());
        add.setOnClickListener(v -> askName(a, "新建容器", "", name -> {
            cm.create(name, null);
            reopen.run();
        }));
        box.addView(add);

        if (supported && cm.list().size() > 1) {
            TextView rt = new TextView(a);
            rt.setText("\n站点默认容器（含子域名；锁定标签里打开的链接仍留在原容器）");
            rt.setTypeface(Typeface.DEFAULT_BOLD);
            box.addView(rt);
            for (ContainerState.SiteRule r : cm.state().siteRules()) {
                ContainerState.Container c = cm.container(r.containerId);
                TextView t = new TextView(a);
                t.setText(r.host + "  →  " + (c != null ? c.name : "?") + "（点击移除）");
                t.setPadding(0, dp(a, 8), 0, dp(a, 8));
                t.setOnClickListener(v -> new AlertDialog.Builder(a)
                        .setMessage("移除 " + r.host + " 的站点规则？")
                        .setNegativeButton("取消", null)
                        .setPositiveButton("移除", (d, w) -> { cm.removeSiteRule(r.host); reopen.run(); })
                        .show());
                box.addView(t);
            }
            Button addRule = new Button(a);
            addRule.setText("添加站点规则…");
            addRule.setOnClickListener(v -> addRule(a, reopen));
            box.addView(addRule);
        }

        holder[0] = new AlertDialog.Builder(a)
                .setTitle("容器")
                .setView(scroll)
                .setPositiveButton("完成", null)
                .create();
        holder[0].setOnDismissListener(d -> { if (onClose != null) onClose.run(); });
        holder[0].show();
    }

    private interface NameAction { void apply(String name); }

    private static void askName(Activity a, String title, String initial, NameAction action) {
        EditText input = new EditText(a);
        input.setSingleLine(true);
        input.setInputType(InputType.TYPE_CLASS_TEXT);
        input.setFilters(new InputFilter[]{new InputFilter.LengthFilter(ContainerState.MAX_NAME)});
        input.setHint("例如：工作、小号 2");
        input.setText(initial);
        new AlertDialog.Builder(a)
                .setTitle(title)
                .setView(input)
                .setNegativeButton("取消", null)
                .setPositiveButton("好", (d, w) -> {
                    try {
                        action.apply(input.getText().toString());
                    } catch (RuntimeException e) {
                        Toast.makeText(a, e.getMessage(), Toast.LENGTH_LONG).show();
                    }
                })
                .show();
    }

    private static void editContainer(Activity a, ContainerState.Container c, Runnable reopen) {
        ContainerManager cm = ContainerManager.get(a);
        new AlertDialog.Builder(a)
                .setTitle(c.name)
                .setItems(new CharSequence[]{"重命名", "更改颜色", "删除容器…"}, (d, which) -> {
                    if (which == 0) {
                        askName(a, "重命名容器", c.name, name -> { cm.update(c.id, name, null); reopen.run(); });
                    } else if (which == 1) {
                        pickColor(a, c.color, color -> { cm.update(c.id, null, color); reopen.run(); });
                    } else {
                        confirmDelete(a, c, reopen);
                    }
                })
                .setNegativeButton("取消", null)
                .show();
    }

    private interface ColorAction { void apply(String color); }

    private static void pickColor(Activity a, String current, ColorAction action) {
        List<String> colors = ContainerState.COLORS;
        LinearLayout list = new LinearLayout(a);
        list.setOrientation(LinearLayout.VERTICAL);
        list.setPadding(dp(a, 24), dp(a, 8), dp(a, 24), dp(a, 8));
        AlertDialog d = new AlertDialog.Builder(a).setTitle("容器颜色").setView(list).setNegativeButton("取消", null).create();
        for (String col : colors) {
            LinearLayout row = new LinearLayout(a);
            row.setOrientation(LinearLayout.HORIZONTAL);
            row.setGravity(Gravity.CENTER_VERTICAL);
            row.setPadding(0, dp(a, 10), 0, dp(a, 10));
            row.addView(dot(a, col, 18));
            TextView t = new TextView(a);
            t.setText(ContainerState.colorName(col) + (col.equals(current) ? "  ✓" : ""));
            t.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16);
            row.addView(t);
            row.setClickable(true);
            row.setOnClickListener(v -> {
                d.dismiss();
                action.apply(col);
            });
            list.addView(row);
        }
        d.show();
    }

    private static void confirmDelete(Activity a, ContainerState.Container c, Runnable reopen) {
        new AlertDialog.Builder(a)
                .setTitle("删除容器「" + c.name + "」？")
                .setMessage("会关闭它的标签，并清除其中的 Cookie、登录状态、网站存储和缓存，无法恢复。")
                .setNegativeButton("取消", null)
                .setPositiveButton("删除", (d, w) -> {
                    ContainerManager.get(a).remove(c.id);
                    reopen.run();
                })
                .show();
    }

    private static void addRule(Activity a, Runnable reopen) {
        ContainerManager cm = ContainerManager.get(a);
        EditText input = new EditText(a);
        input.setSingleLine(true);
        input.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI);
        input.setHint("例如 github.com");
        new AlertDialog.Builder(a)
                .setTitle("站点默认容器")
                .setView(input)
                .setNegativeButton("取消", null)
                .setPositiveButton("下一步", (d, w) -> {
                    String host = ContainerState.normalizeHost(input.getText().toString());
                    if (host == null) {
                        Toast.makeText(a, "无效的域名", Toast.LENGTH_LONG).show();
                        return;
                    }
                    List<ContainerState.Container> all = cm.list();
                    all.remove(0); // 默认容器不能作为站点规则
                    CharSequence[] names = new CharSequence[all.size()];
                    for (int i = 0; i < all.size(); i++) names[i] = all.get(i).name;
                    new AlertDialog.Builder(a)
                            .setTitle(host + " 在哪个容器打开？")
                            .setItems(names, (d2, which) -> {
                                cm.setSiteRule(host, all.get(which).id);
                                reopen.run();
                            })
                            .setNegativeButton("取消", null)
                            .show();
                })
                .show();
    }
}
