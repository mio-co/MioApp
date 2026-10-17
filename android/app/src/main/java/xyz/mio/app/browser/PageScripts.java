package xyz.mio.app.browser;

import android.content.Context;

import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;

/** www/mio-browser/*.js（cap sync 拷到 assets/public/mio-browser/）与包装代码；与 iOS / 桌面共用同一份脚本 */
final class PageScripts {
    private PageScripts() {}

    static String asset(Context c, String name) {
        try (InputStream in = c.getAssets().open("public/mio-browser/" + name + ".js")) {
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            byte[] buf = new byte[16384];
            int n;
            while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
            return new String(out.toByteArray(), StandardCharsets.UTF_8);
        } catch (Exception e) {
            return null;
        }
    }

    static String darkInstall(String src, JSONObject cfg) {
        return src + "\n;try{MioDark.install(document,window," + cfg + ");}catch(e){}\n";
    }

    static String readerable(String src) {
        return "(function(){if(typeof window.MioReader==='undefined'){\n" + src + "\n}return MioReader.isProbablyReaderable(document);})()";
    }

    /** 提取正文 + 选中文字 + 阅读视图 HTML（evaluateJavascript 返回 JSON） */
    static String extract(String src, JSONObject prefs, boolean force) {
        return "(function(){if(typeof window.MioReader==='undefined'){\n" + src + "\n}\n"
                + "var sel='';try{sel=String(window.getSelection?window.getSelection():'').trim();}catch(e){}\n"
                + "var a=null;try{a=MioReader.extract(document,{url:location.href,force:" + force + "});}catch(e){a=null;}\n"
                + "var out={url:location.href,title:document.title||'',selection:sel.slice(0,20000)};\n"
                + "if(a){out.article={title:a.title,byline:a.byline,siteName:a.siteName,excerpt:a.excerpt,markdown:a.markdown,textLength:a.textLength,url:a.url};"
                + "out.page=MioReader.buildPage(a," + prefs + ");}\n"
                + "return out;})()";
    }

    /** MioCore 同源的空白页里执行，结果交给 MioSaveBridge.done(json) */
    static String save(String src, String kind, JSONObject payload, JSONObject opts) {
        return "(function(){if(typeof window.MioSave==='undefined'){\n" + src + "\n}\n"
                + "MioSave.run(" + JSONObject.quote(kind) + "," + payload + "," + opts + ")"
                + ".then(function(r){MioSaveBridge.done(JSON.stringify(r));},function(e){MioSaveBridge.done(JSON.stringify({ok:false,code:'network',message:String(e)}));});"
                + "return true;})()";
    }

    static String applyPrefs(JSONObject p) {
        return "(function(d){d.setAttribute('data-theme'," + JSONObject.quote(p.optString("theme", "light")) + ");"
                + "d.setAttribute('data-font'," + JSONObject.quote(p.optString("font", "sans")) + ");"
                + "d.style.setProperty('--fs','" + p.optInt("fontSize", 18) + "px');return true;})(document.documentElement)";
    }

    static String saveMessage(JSONObject r) {
        if (r == null) return "保存失败：没有返回结果";
        if (r.optBoolean("ok")) {
            String cat = r.optString("category", "");
            String c = cat.isEmpty() ? "" : "「" + cat + "」";
            switch (r.optString("kind")) {
                case "bookmark": return r.optBoolean("duplicate") ? "导航里已有这个网页" + c : "已存到导航" + c;
                case "note": return "已新建笔记";
                case "clip": return "已推到云剪贴板，可在另一台设备继续";
                default: return "已保存";
            }
        }
        return r.optString("message", "未知错误");
    }
}
