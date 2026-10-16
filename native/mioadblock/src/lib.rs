//! Mio App（Android）广告拦截原生库。
//!
//! - 网络请求 + 基础元素隐藏（`##` / `#@#`、通用 class/id 选择器）：Brave [adblock-rust](https://github.com/brave/adblock-rust)（MPL-2.0）
//! - AdGuard 高级规则（`#%#//scriptlet` / `#%#` JS / `#$#` CSS / `#?#` ExtendedCss）：本 crate 的 `advanced` 索引，
//!   代码由 [AdGuard Scriptlets](https://github.com/AdguardTeam/Scriptlets)（GPL-3.0）的 corelibs 包生成，与 iOS 相同
//! - JNI：`xyz.mio.app.adblock.AdblockNative`

pub mod advanced;
pub mod scriptlets;

use adblock::lists::{FilterSet, ParseOptions};
use adblock::request::Request;
use adblock::Engine;
use advanced::AdvancedIndex;
use scriptlets::Scriptlets;

pub struct MioEngine {
    engine: Engine,
    adv: AdvancedIndex,
    scriptlets: Option<Scriptlets>,
    ext_css_lib: Option<String>,
    network_rules: usize,
}

pub struct BuildStats {
    pub network_and_cosmetic_lines: usize,
    pub advanced_rules: usize,
    pub advanced_exceptions: usize,
}

fn css_rule(s: &str) -> String {
    let t = s.trim();
    if t.ends_with('}') { t.to_string() } else { format!("{} {{display:none!important;}}", t) }
}

fn js_string(s: &str) -> String {
    serde_json::Value::from(s).to_string()
}

pub fn host_of(url: &str) -> Option<String> {
    let rest = url.split_once("://")?.1;
    let end = rest.find(['/', '?', '#']).unwrap_or(rest.len());
    let auth = &rest[..end];
    let auth = auth.rsplit_once('@').map(|x| x.1).unwrap_or(auth);
    let host = if auth.starts_with('[') {
        auth.split_once(']').map(|x| &x.0[1..]).unwrap_or(auth)
    } else {
        auth.split(':').next().unwrap_or(auth)
    };
    if host.is_empty() { None } else { Some(host.to_ascii_lowercase()) }
}

impl MioEngine {
    pub fn build(lists: &[String]) -> (MioEngine, BuildStats) {
        let mut set = FilterSet::new(false);
        let mut adv = AdvancedIndex::default();
        let mut normal_lines = 0usize;
        for text in lists {
            let mut normal = String::with_capacity(text.len());
            for line in text.lines() {
                let l = line.trim();
                if l.is_empty() {
                    continue;
                }
                if !l.starts_with('!') && advanced::is_advanced_line(l) {
                    adv.add_line(l);
                    continue;
                }
                normal.push_str(l);
                normal.push('\n');
                normal_lines += 1;
            }
            set.add_filter_list(normal, ParseOptions::default());
        }
        let engine = Engine::new_with_filter_set(set);
        let stats = BuildStats {
            network_and_cosmetic_lines: normal_lines,
            advanced_rules: adv.len(),
            advanced_exceptions: adv.exceptions_len(),
        };
        (MioEngine { engine, adv, scriptlets: None, ext_css_lib: None, network_rules: normal_lines }, stats)
    }

    /// 序列化：`[u32 LE adv json 长度][adv json][u32 LE 行数][adblock-rust engine]`
    pub fn serialize(&self) -> Vec<u8> {
        let adv = serde_json::to_vec(&self.adv).unwrap_or_default();
        let eng = self.engine.serialize();
        let mut out = Vec::with_capacity(adv.len() + eng.len() + 8);
        out.extend_from_slice(&(adv.len() as u32).to_le_bytes());
        out.extend_from_slice(&adv);
        out.extend_from_slice(&(self.network_rules as u32).to_le_bytes());
        out.extend_from_slice(&eng);
        out
    }

    pub fn deserialize(bytes: &[u8]) -> Result<MioEngine, String> {
        if bytes.len() < 8 {
            return Err("too short".into());
        }
        let n = u32::from_le_bytes(bytes[0..4].try_into().unwrap()) as usize;
        if bytes.len() < 8 + n {
            return Err("truncated".into());
        }
        let adv: AdvancedIndex = serde_json::from_slice(&bytes[4..4 + n]).map_err(|e| e.to_string())?;
        let rules = u32::from_le_bytes(bytes[4 + n..8 + n].try_into().unwrap()) as usize;
        let mut engine = Engine::default();
        engine.deserialize(&bytes[8 + n..]).map_err(|e| format!("{:?}", e))?;
        Ok(MioEngine { engine, adv, scriptlets: None, ext_css_lib: None, network_rules: rules })
    }

    pub fn set_resources(&mut self, scriptlets_json: &str, ext_css_lib: &str) -> Result<String, String> {
        let s = Scriptlets::parse(scriptlets_json)?;
        let v = s.version.clone();
        self.scriptlets = Some(s);
        if !ext_css_lib.is_empty() {
            self.ext_css_lib = Some(ext_css_lib.to_string());
        }
        Ok(v)
    }

    pub fn scriptlets_version(&self) -> Option<&str> {
        self.scriptlets.as_ref().map(|s| s.version.as_str())
    }

    pub fn advanced_count(&self) -> usize {
        self.adv.len()
    }

    pub fn network_rules(&self) -> usize {
        self.network_rules
    }

    /// 网络请求是否拦截。request_type：document / subdocument / script / stylesheet / image / font / media / xmlhttprequest / other ...
    pub fn should_block(&self, url: &str, source_url: &str, request_type: &str) -> bool {
        match Request::new(url, source_url, request_type, "GET") {
            Ok(req) => self.engine.check_network_request(&req).should_block(),
            Err(_) => false,
        }
    }

    /// 页面（frame）在 document-start 要执行的 JS：scriptlets → CSS（adblock-rust 主机名相关的隐藏 + AdGuard CSS 注入）→ JS 规则 → ExtendedCss
    pub fn page_script(&self, url: &str) -> Option<String> {
        let host = host_of(url)?;
        let cosmetic = self.engine.url_cosmetic_resources(url);
        let adv = self.adv.lookup(&host);
        let mut parts: Vec<String> = Vec::new();
        if let Some(s) = &self.scriptlets {
            if let Some(code) = s.code(&adv.scriptlets) {
                parts.push(code);
            }
        }
        let mut css: Vec<String> = cosmetic.hide_selectors.iter().map(|s| css_rule(s)).collect();
        css.sort();
        css.extend(adv.css.iter().map(|s| css_rule(s)));
        if !css.is_empty() {
            parts.push(format!(
                "(function(){{var css={};function add(){{try{{var s=document.createElement('style');s.setAttribute('data-mio-adblock','');s.textContent=css;(document.head||document.documentElement).appendChild(s);}}catch(e){{}}}}if(document.documentElement){{add();}}else{{document.addEventListener('readystatechange',add,{{once:true}});}}}})();",
                js_string(&css.join("\n"))
            ));
        }
        for js in &adv.js {
            parts.push(format!("try{{{}\n}}catch(e){{}}", js));
        }
        if !adv.ext_css.is_empty() {
            if let Some(lib) = &self.ext_css_lib {
                let rules = serde_json::Value::from(adv.ext_css.clone()).to_string();
                parts.push(format!(
                    "(function(){{{}\n;var rules={};function go(){{try{{new ExtendedCss({{cssRules:rules}}).apply();}}catch(e){{}}}}if(document.readyState==='loading'){{document.addEventListener('DOMContentLoaded',go,{{once:true}});}}else{{go();}}}})();",
                    lib, rules
                ));
            }
        }
        // 通用 class / id 选择器（EasyList 的 ##.ad-banner 之类）：页面把出现过的 class / id 交给原生查询
        if !cosmetic.generichide {
            parts.push(GENERIC_SCANNER.to_string());
        }
        if parts.is_empty() { None } else { Some(parts.join("\n")) }
    }

    /// 通用 class / id 选择器（`hidden_class_id_selectors`）→ CSS 文本
    pub fn generic_css(&self, url: &str, classes: Vec<String>, ids: Vec<String>) -> String {
        let cosmetic = self.engine.url_cosmetic_resources(url);
        if cosmetic.generichide {
            return String::new();
        }
        let exceptions = cosmetic.exceptions;
        let sel = self.engine.hidden_class_id_selectors(&classes, &ids, &exceptions);
        sel.iter().map(|s| css_rule(s)).collect::<Vec<_>>().join("\n")
    }
}

/// 页面里收集 class / id，调用 `MioAdblockBridge.generic(url, json)`（Android JavascriptInterface，同步）拿到 CSS 并插入
const GENERIC_SCANNER: &str = r#"(function(){if(window.__mioGeneric)return;window.__mioGeneric=1;var B=window.MioAdblockBridge;if(!B||!B.generic)return;var seenC={},seenI={},style=null,timer=0;
function collect(root){var c=[],i=[];var els=(root&&root.querySelectorAll)?root.querySelectorAll('[id],[class]'):[];for(var k=0;k<els.length&&k<4000;k++){var e=els[k];if(e.id&&!seenI[e.id]){seenI[e.id]=1;i.push(e.id);}var cl=e.classList;if(cl){for(var j=0;j<cl.length;j++){var n=cl[j];if(!seenC[n]){seenC[n]=1;c.push(n);}}}}
if(!c.length&&!i.length)return;try{var css=B.generic(location.href,JSON.stringify({c:c,i:i}));if(css){if(!style){style=document.createElement('style');style.setAttribute('data-mio-adblock-generic','');(document.head||document.documentElement).appendChild(style);}style.textContent+=css+'\n';}}catch(e){}}
function run(){timer=0;collect(document);}
function schedule(){if(!timer)timer=setTimeout(run,800);}
if(document.readyState==='loading'){document.addEventListener('DOMContentLoaded',run,{once:true});}else{run();}
try{new MutationObserver(schedule).observe(document.documentElement,{childList:true,subtree:true,attributes:true,attributeFilter:['class','id']});}catch(e){}})();"#;

// MARK: - JNI

mod ffi {
    use super::*;
    use jni::objects::{JByteArray, JClass, JObjectArray, JString};
    use jni::sys::{jboolean, jlong, jstring, JNI_FALSE, JNI_TRUE};
    use jni::JNIEnv;
    use std::panic::{catch_unwind, AssertUnwindSafe};

    fn get_string(env: &mut JNIEnv, s: &JString) -> String {
        if s.is_null() {
            return String::new();
        }
        env.get_string(s).map(|v| v.into()).unwrap_or_default()
    }

    /// 只读访问（多线程并发调用）；Kotlin 侧用读写锁保证释放 / setResources 时没有并发读
    fn engine<'a>(handle: jlong) -> Option<&'a MioEngine> {
        if handle == 0 { None } else { unsafe { (handle as *const MioEngine).as_ref() } }
    }

    fn engine_mut<'a>(handle: jlong) -> Option<&'a mut MioEngine> {
        if handle == 0 { None } else { unsafe { (handle as *mut MioEngine).as_mut() } }
    }

    fn new_string(env: &mut JNIEnv, s: &str) -> jstring {
        env.new_string(s).map(|v| v.into_raw()).unwrap_or(std::ptr::null_mut())
    }

    #[no_mangle]
    pub extern "system" fn Java_xyz_mio_app_adblock_AdblockNative_build<'l>(mut env: JNIEnv<'l>, _c: JClass<'l>, lists: JObjectArray<'l>) -> jlong {
        let mut texts = Vec::new();
        let n = env.get_array_length(&lists).unwrap_or(0);
        for i in 0..n {
            if let Ok(o) = env.get_object_array_element(&lists, i) {
                let s = JString::from(o);
                texts.push(get_string(&mut env, &s));
            }
        }
        match catch_unwind(AssertUnwindSafe(|| MioEngine::build(&texts).0)) {
            Ok(e) => Box::into_raw(Box::new(e)) as jlong,
            Err(_) => 0,
        }
    }

    #[no_mangle]
    pub extern "system" fn Java_xyz_mio_app_adblock_AdblockNative_load<'l>(env: JNIEnv<'l>, _c: JClass<'l>, bytes: JByteArray<'l>) -> jlong {
        let Ok(data) = env.convert_byte_array(&bytes) else { return 0 };
        match catch_unwind(AssertUnwindSafe(|| MioEngine::deserialize(&data))) {
            Ok(Ok(e)) => Box::into_raw(Box::new(e)) as jlong,
            _ => 0,
        }
    }

    #[no_mangle]
    pub extern "system" fn Java_xyz_mio_app_adblock_AdblockNative_serialize<'l>(env: JNIEnv<'l>, _c: JClass<'l>, handle: jlong) -> jni::sys::jbyteArray {
        let Some(e) = engine(handle) else { return std::ptr::null_mut() };
        let data = match catch_unwind(AssertUnwindSafe(|| e.serialize())) { Ok(d) => d, Err(_) => return std::ptr::null_mut() };
        env.byte_array_from_slice(&data).map(|a| a.into_raw()).unwrap_or(std::ptr::null_mut())
    }

    #[no_mangle]
    pub extern "system" fn Java_xyz_mio_app_adblock_AdblockNative_setResources<'l>(mut env: JNIEnv<'l>, _c: JClass<'l>, handle: jlong, scriptlets: JString<'l>, ext_css: JString<'l>) -> jstring {
        let Some(e) = engine_mut(handle) else { return std::ptr::null_mut() };
        let s = get_string(&mut env, &scriptlets);
        let x = get_string(&mut env, &ext_css);
        match catch_unwind(AssertUnwindSafe(|| e.set_resources(&s, &x))) {
            Ok(Ok(v)) => new_string(&mut env, &v),
            _ => std::ptr::null_mut(),
        }
    }

    #[no_mangle]
    pub extern "system" fn Java_xyz_mio_app_adblock_AdblockNative_shouldBlock<'l>(mut env: JNIEnv<'l>, _c: JClass<'l>, handle: jlong, url: JString<'l>, source: JString<'l>, kind: JString<'l>) -> jboolean {
        let Some(e) = engine(handle) else { return JNI_FALSE };
        let u = get_string(&mut env, &url);
        let s = get_string(&mut env, &source);
        let k = get_string(&mut env, &kind);
        match catch_unwind(AssertUnwindSafe(|| e.should_block(&u, &s, &k))) {
            Ok(true) => JNI_TRUE,
            _ => JNI_FALSE,
        }
    }

    #[no_mangle]
    pub extern "system" fn Java_xyz_mio_app_adblock_AdblockNative_pageScript<'l>(mut env: JNIEnv<'l>, _c: JClass<'l>, handle: jlong, url: JString<'l>) -> jstring {
        let Some(e) = engine(handle) else { return std::ptr::null_mut() };
        let u = get_string(&mut env, &url);
        match catch_unwind(AssertUnwindSafe(|| e.page_script(&u))) {
            Ok(Some(s)) => new_string(&mut env, &s),
            _ => std::ptr::null_mut(),
        }
    }

    #[no_mangle]
    pub extern "system" fn Java_xyz_mio_app_adblock_AdblockNative_genericCss<'l>(mut env: JNIEnv<'l>, _c: JClass<'l>, handle: jlong, url: JString<'l>, json: JString<'l>) -> jstring {
        let Some(e) = engine(handle) else { return std::ptr::null_mut() };
        let u = get_string(&mut env, &url);
        let j = get_string(&mut env, &json);
        let r = catch_unwind(AssertUnwindSafe(|| {
            let v: serde_json::Value = serde_json::from_str(&j).unwrap_or_default();
            let list = |k: &str| -> Vec<String> {
                v.get(k).and_then(|x| x.as_array()).map(|a| a.iter().filter_map(|s| s.as_str().map(String::from)).take(5000).collect()).unwrap_or_default()
            };
            e.generic_css(&u, list("c"), list("i"))
        }));
        match r {
            Ok(s) => new_string(&mut env, &s),
            Err(_) => std::ptr::null_mut(),
        }
    }

    #[no_mangle]
    pub extern "system" fn Java_xyz_mio_app_adblock_AdblockNative_stats<'l>(mut env: JNIEnv<'l>, _c: JClass<'l>, handle: jlong) -> jstring {
        let Some(e) = engine(handle) else { return std::ptr::null_mut() };
        let s = serde_json::json!({
            "networkAndCosmeticLines": e.network_rules(),
            "advancedRules": e.advanced_count(),
            "scriptlets": e.scriptlets_version(),
        })
        .to_string();
        new_string(&mut env, &s)
    }

    #[no_mangle]
    pub extern "system" fn Java_xyz_mio_app_adblock_AdblockNative_free<'l>(_env: JNIEnv<'l>, _c: JClass<'l>, handle: jlong) {
        if handle != 0 {
            unsafe { drop(Box::from_raw(handle as *mut MioEngine)) };
        }
    }
}

// 编译期确认可以跨线程共享
#[allow(dead_code)]
fn assert_sync() {
    fn is_sync<T: Sync + Send>() {}
    is_sync::<MioEngine>();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn host_parsing() {
        assert_eq!(host_of("https://m.youtube.com/watch?v=1").as_deref(), Some("m.youtube.com"));
        assert_eq!(host_of("http://u:p@Example.com:8080/x").as_deref(), Some("example.com"));
        assert_eq!(host_of("about:blank"), None);
    }
}
