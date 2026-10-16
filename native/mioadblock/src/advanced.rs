//! AdGuard「高级规则」索引：adblock-rust 不支持的 AdGuard 语法
//! - `#%#//scriptlet(...)`  AdGuard Scriptlets
//! - `#%#<js>`              JS 注入
//! - `#$#selector { style }` CSS 注入
//! - `#?#` / `#$?#`          ExtendedCss（以及 `##` 里带扩展伪类的规则）
//! 以及它们的例外（`#@%#` `#@$#` `#@?#` `#@$?#`）。
//! 按域名建索引；查询时匹配主机名及其各级父域名、`example.*` 通配 TLD、排除域名 `~example.com`。

use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq, Hash)]
pub enum Kind {
    Scriptlet { name: String, args: Vec<String> },
    Js(String),
    Css(String),
    ExtCss(String),
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct Rule {
    kind: Kind,
    include: Vec<String>,
    exclude: Vec<String>,
}

#[derive(Default, Serialize, Deserialize)]
pub struct AdvancedIndex {
    rules: Vec<Rule>,
    /// 索引键：域名（`m.youtube.com`）或通配 TLD 的前缀（`youtube.*`）
    by_domain: HashMap<String, Vec<u32>>,
    generic: Vec<u32>,
    /// 例外：同样按域名索引（值为 kind）
    exceptions: Vec<Rule>,
    exc_by_domain: HashMap<String, Vec<u32>>,
    exc_generic: Vec<u32>,
}

#[derive(Default, Debug, Clone)]
pub struct Lookup {
    pub scriptlets: Vec<(String, Vec<String>)>,
    pub js: Vec<String>,
    pub css: Vec<String>,
    pub ext_css: Vec<String>,
}

/// 是否是交给本索引处理（而不是 adblock-rust）的行
pub fn is_advanced_line(line: &str) -> bool {
    split_marker(line).is_some()
}

const MARKERS: &[(&str, bool, u8)] = &[
    // (marker, exception, type) type: 0 = %, 1 = $ css, 2 = ? extcss, 3 = $? extcss inject, 4 = ## with extended pseudo
    ("#@$?#", true, 3),
    ("#$?#", false, 3),
    ("#@%#", true, 0),
    ("#%#", false, 0),
    ("#@$#", true, 1),
    ("#$#", false, 1),
    ("#@?#", true, 2),
    ("#?#", false, 2),
];

/// ExtendedCss 才认识的伪类：这些 `##` 规则交给 ExtendedCss（adblock-rust 会当成 procedural 规则，这里不用）
const EXT_PSEUDO: &[&str] = &[
    ":-abp-has(", ":-abp-contains(", ":has-text(", ":contains(", ":matches-css(", ":matches-css-before(",
    ":matches-css-after(", ":matches-attr(", ":matches-property(", ":xpath(", ":nth-ancestor(", ":upward(",
    ":remove()", ":is(", ":if-not(", ":-abp-properties(",
];

fn split_marker(line: &str) -> Option<(&str, &'static str, bool, u8, &str)> {
    if line.starts_with('!') || line.starts_with("[$") || line.starts_with('[') {
        return None;
    }
    for (m, exc, t) in MARKERS {
        if let Some(i) = line.find(m) {
            // 域名部分不能含空格 / 斜杠（排除网络规则里的 #）
            let domains = &line[..i];
            if domains.contains('/') || domains.contains(' ') || domains.contains('$') && !domains.is_empty() {
                return None;
            }
            return Some((domains, m, *exc, *t, &line[i + m.len()..]));
        }
    }
    // `##` / `#@#` 带扩展伪类
    for (m, exc) in [("#@#", true), ("##", false)] {
        if let Some(i) = line.find(m) {
            let domains = &line[..i];
            if domains.contains('/') || domains.contains(' ') || domains.contains('$') {
                return None;
            }
            let content = &line[i + m.len()..];
            if content.starts_with('+') || content.starts_with('^') {
                return None; // uBO scriptlet / HTML filtering：不支持
            }
            if EXT_PSEUDO.iter().any(|p| content.contains(p)) {
                return Some((domains, m, exc, 4, content));
            }
            return None;
        }
    }
    None
}

/// 解析 `//scriptlet('name', 'a', "b")`
pub fn parse_scriptlet(content: &str) -> Option<(String, Vec<String>)> {
    let s = content.trim();
    let s = s.strip_prefix("//scriptlet(")?;
    let s = s.strip_suffix(')')?;
    let mut out: Vec<String> = Vec::new();
    let chars: Vec<char> = s.chars().collect();
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        if c == ' ' || c == ',' || c == '\t' {
            i += 1;
            continue;
        }
        if c != '\'' && c != '"' {
            return None;
        }
        let quote = c;
        i += 1;
        let mut cur = String::new();
        let mut closed = false;
        while i < chars.len() {
            let ch = chars[i];
            if ch == '\\' && i + 1 < chars.len() {
                let next = chars[i + 1];
                if next == quote {
                    cur.push(next);
                } else {
                    cur.push('\\');
                    cur.push(next);
                }
                i += 2;
                continue;
            }
            if ch == quote {
                closed = true;
                i += 1;
                break;
            }
            cur.push(ch);
            i += 1;
        }
        if !closed {
            return None;
        }
        out.push(cur);
    }
    if out.is_empty() || out[0].is_empty() {
        return None;
    }
    let name = out.remove(0);
    Some((name, out))
}

fn ensure_hide(content: &str) -> String {
    let t = content.trim();
    if t.ends_with('}') { t.to_string() } else { format!("{} {{ display: none !important; }}", t) }
}

impl AdvancedIndex {
    pub fn add_line(&mut self, line: &str) -> bool {
        let line = line.trim();
        let Some((domains, _m, exc, t, content)) = split_marker(line) else { return false };
        let content = content.trim();
        if content.is_empty() {
            return false;
        }
        let kind = match t {
            0 => {
                if content.starts_with("//scriptlet(") {
                    match parse_scriptlet(content) {
                        Some((name, args)) => Kind::Scriptlet { name, args },
                        None => return false,
                    }
                } else {
                    Kind::Js(content.to_string())
                }
            }
            1 => {
                if !content.ends_with('}') { return false; }
                Kind::Css(content.to_string())
            }
            2 | 4 => Kind::ExtCss(ensure_hide(content)),
            3 => {
                if !content.ends_with('}') { return false; }
                Kind::ExtCss(content.to_string())
            }
            _ => return false,
        };
        let mut include = Vec::new();
        let mut exclude = Vec::new();
        for d in domains.split(',') {
            let d = d.trim().to_ascii_lowercase();
            if d.is_empty() { continue; }
            if let Some(x) = d.strip_prefix('~') {
                exclude.push(x.to_string());
            } else {
                include.push(d);
            }
        }
        let rule = Rule { kind, include, exclude };
        if exc {
            let idx = self.exceptions.len() as u32;
            if rule.include.is_empty() {
                self.exc_generic.push(idx);
            } else {
                for d in &rule.include {
                    self.exc_by_domain.entry(d.clone()).or_default().push(idx);
                }
            }
            self.exceptions.push(rule);
        } else {
            let idx = self.rules.len() as u32;
            if rule.include.is_empty() {
                self.generic.push(idx);
            } else {
                for d in &rule.include {
                    self.by_domain.entry(d.clone()).or_default().push(idx);
                }
            }
            self.rules.push(rule);
        }
        true
    }

    pub fn len(&self) -> usize {
        self.rules.len()
    }

    pub fn exceptions_len(&self) -> usize {
        self.exceptions.len()
    }

    /// host 及其父域名、通配 TLD 前缀（`a.b.example.co.uk` → `example.*`、`example.co.*` ...）
    fn keys(host: &str) -> Vec<String> {
        let labels: Vec<&str> = host.split('.').collect();
        let mut keys = Vec::new();
        for i in 0..labels.len() {
            let suffix = labels[i..].join(".");
            keys.push(suffix.clone());
            let rest = &labels[i..];
            for strip in 1..=2usize {
                if rest.len() > strip {
                    keys.push(format!("{}.*", rest[..rest.len() - strip].join(".")));
                }
            }
        }
        keys
    }

    fn domain_matches(pattern: &str, host: &str) -> bool {
        if let Some(stem) = pattern.strip_suffix(".*") {
            // example.* 匹配 example.com / example.co.uk / sub.example.com
            let labels: Vec<&str> = host.split('.').collect();
            for i in 0..labels.len() {
                let rest = labels[i..].join(".");
                if let Some(tail) = rest.strip_prefix(stem) {
                    if let Some(tld) = tail.strip_prefix('.') {
                        if !tld.is_empty() && tld.split('.').count() <= 2 {
                            return true;
                        }
                    }
                }
            }
            return false;
        }
        host == pattern || host.ends_with(&format!(".{}", pattern))
    }

    fn rule_applies(rule: &Rule, host: &str) -> bool {
        if rule.exclude.iter().any(|d| Self::domain_matches(d, host)) {
            return false;
        }
        rule.include.is_empty() || rule.include.iter().any(|d| Self::domain_matches(d, host))
    }

    pub fn lookup(&self, host: &str) -> Lookup {
        let host = host.trim_end_matches('.').to_ascii_lowercase();
        let keys = Self::keys(&host);
        let mut candidates: Vec<u32> = self.generic.clone();
        let mut exc_candidates: Vec<u32> = self.exc_generic.clone();
        for k in &keys {
            if let Some(v) = self.by_domain.get(k) { candidates.extend_from_slice(v); }
            if let Some(v) = self.exc_by_domain.get(k) { exc_candidates.extend_from_slice(v); }
        }
        let mut excepted: HashSet<&Kind> = HashSet::new();
        exc_candidates.sort_unstable();
        exc_candidates.dedup();
        for i in exc_candidates {
            let r = &self.exceptions[i as usize];
            if Self::rule_applies(r, &host) { excepted.insert(&r.kind); }
        }
        candidates.sort_unstable();
        candidates.dedup();
        let mut out = Lookup::default();
        let mut seen: HashSet<&Kind> = HashSet::new();
        for i in candidates {
            let r = &self.rules[i as usize];
            if excepted.contains(&r.kind) || !seen.insert(&r.kind) || !Self::rule_applies(r, &host) {
                continue;
            }
            match &r.kind {
                Kind::Scriptlet { name, args } => out.scriptlets.push((name.clone(), args.clone())),
                Kind::Js(s) => out.js.push(s.clone()),
                Kind::Css(s) => out.css.push(s.clone()),
                Kind::ExtCss(s) => out.ext_css.push(s.clone()),
            }
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_scriptlets() {
        assert_eq!(
            parse_scriptlet("//scriptlet('set-constant', 'ytInitialPlayerResponse.adPlacements', 'undefined')"),
            Some(("set-constant".into(), vec!["ytInitialPlayerResponse.adPlacements".into(), "undefined".into()]))
        );
        assert_eq!(
            parse_scriptlet(r#"//scriptlet("json-prune", "a b", "")"#),
            Some(("json-prune".into(), vec!["a b".into(), "".into()]))
        );
        assert_eq!(parse_scriptlet(r"//scriptlet('x', 'it\'s')"), Some(("x".into(), vec!["it's".into()])));
        assert_eq!(parse_scriptlet("//scriptlet(bad)"), None);
    }

    #[test]
    fn indexes_and_matches() {
        let mut idx = AdvancedIndex::default();
        assert!(idx.add_line("youtube.com#%#//scriptlet('set-constant', 'a', 'undefined')"));
        assert!(idx.add_line("example.*,~sub.example.com#$#.ad { height: 0 !important; }"));
        assert!(idx.add_line("m.youtube.com#?#div:has-text(Ad)"));
        assert!(idx.add_line("youtube.com##ytm-x:upward(2)"));
        assert!(idx.add_line("#%#window.foo=1;"));
        assert!(idx.add_line("m.youtube.com#@%#window.foo=1;"));
        assert!(!idx.add_line("||example.com^$domain=a.com"));
        assert!(!idx.add_line("example.com##.plain"));
        let l = idx.lookup("m.youtube.com");
        assert_eq!(l.scriptlets.len(), 1);
        assert_eq!(l.ext_css.len(), 2);
        assert!(l.js.is_empty(), "generic js excepted on m.youtube.com");
        assert_eq!(idx.lookup("www.youtube.com").js.len(), 1);
        assert_eq!(idx.lookup("example.co.uk").css.len(), 1);
        assert_eq!(idx.lookup("a.example.com").css.len(), 1);
        assert_eq!(idx.lookup("sub.example.com").css.len(), 0);
        assert_eq!(idx.lookup("notexample.com").css.len(), 0);
    }
}
