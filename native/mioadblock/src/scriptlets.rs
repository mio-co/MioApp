//! AdGuard Scriptlets（`scriptlets.corelibs.json`）代码生成，与 iOS 的 MioScriptlets 相同：
//! `(function(){ var __mioS0 = function X(source,args){...}; try{ __mioS0({name,args,engine,version,verbose,uniqueId}, [args]) }catch(e){} })();`

use serde::Deserialize;
use std::collections::HashMap;

#[derive(Deserialize)]
struct CoreLibs {
    version: String,
    scriptlets: Vec<CoreLibsItem>,
}

#[derive(Deserialize)]
struct CoreLibsItem {
    names: Vec<String>,
    scriptlet: String,
}

pub struct Scriptlets {
    pub version: String,
    functions: HashMap<String, usize>,
    bodies: Vec<String>,
}

impl Scriptlets {
    pub fn parse(json: &str) -> Result<Self, String> {
        let c: CoreLibs = serde_json::from_str(json).map_err(|e| e.to_string())?;
        let mut functions = HashMap::new();
        let mut bodies = Vec::new();
        for item in c.scriptlets {
            if !item.scriptlet.starts_with("function") {
                continue;
            }
            let idx = bodies.len();
            bodies.push(item.scriptlet);
            for n in item.names {
                functions.insert(n, idx);
            }
        }
        if !functions.contains_key("json-prune") || !functions.contains_key("set-constant") || bodies.len() < 50 {
            return Err(format!("incomplete scriptlets bundle ({})", bodies.len()));
        }
        Ok(Scriptlets { version: c.version, functions, bodies })
    }

    pub fn count(&self) -> usize {
        self.bodies.len()
    }

    /// 一组 scriptlet 调用 → 一段 JS（同一函数只定义一次）
    pub fn code(&self, calls: &[(String, Vec<String>)]) -> Option<String> {
        let mut defs: Vec<String> = Vec::new();
        let mut var_of: HashMap<usize, String> = HashMap::new();
        let mut out: Vec<String> = Vec::new();
        let mut seen = std::collections::HashSet::new();
        for (name, args) in calls {
            let Some(&idx) = self.functions.get(name) else { continue };
            if !seen.insert((name.clone(), args.clone())) {
                continue;
            }
            let v = var_of.entry(idx).or_insert_with(|| {
                let v = format!("__mioS{}", defs.len());
                defs.push(format!("var {}={};", v, self.bodies[idx]));
                v
            });
            let source = serde_json::json!({
                "name": name,
                "args": args,
                "engine": "safari-extension",
                "version": self.version,
                "verbose": false,
                "uniqueId": "mio",
            });
            out.push(format!(
                "try{{{}({},{});}}catch(e){{}}",
                v,
                source,
                serde_json::Value::from(args.clone())
            ));
        }
        if out.is_empty() {
            return None;
        }
        Some(format!("(function(){{\n{}\n{}\n}})();", defs.join("\n"), out.join("\n")))
    }
}
