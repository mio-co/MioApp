//! 用 iOS 的 AdblockBundle（scripts/fetch-adblock-assets.mjs 生成）里的真实列表测试
use mioadblock::MioEngine;
use std::path::PathBuf;
use std::time::Instant;

fn bundle() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../ios/App/App/AdblockBundle")
}

#[test]
fn real_lists() {
    let dir = bundle();
    if !dir.join("filter-2.txt").exists() {
        eprintln!("skip: no bundled lists at {:?}", dir);
        return;
    }
    let mut lists = Vec::new();
    for id in [2, 11, 3, 101, 118, 224, 0] {
        lists.push(std::fs::read_to_string(dir.join(format!("filter-{}.txt", id))).unwrap());
    }
    let t = Instant::now();
    let (mut e, stats) = MioEngine::build(&lists);
    eprintln!("build {:?}: {} normal lines, {} advanced, {} exceptions", t.elapsed(), stats.network_and_cosmetic_lines, stats.advanced_rules, stats.advanced_exceptions);
    let corelibs = std::fs::read_to_string(dir.join("scriptlets.corelibs.json")).unwrap();
    let ext = std::fs::read_to_string(dir.join("extended-css.min.js")).unwrap();
    let v = e.set_resources(&corelibs, &ext).unwrap();
    eprintln!("scriptlets {}", v);

    // 网络
    assert!(e.should_block("https://googleads.g.doubleclick.net/pagead/id", "https://m.youtube.com/watch?v=1", "xmlhttprequest"));
    assert!(e.should_block("https://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js", "https://example.com/", "script"));
    assert!(e.should_block("https://www.google-analytics.com/analytics.js", "https://example.com/", "script"));
    assert!(e.should_block("https://www.youtube.com/api/stats/ads?x=1", "https://www.youtube.com/watch?v=1", "xmlhttprequest"));
    assert!(!e.should_block("https://www.youtube.com/youtubei/v1/player?key=1", "https://www.youtube.com/watch?v=1", "xmlhttprequest"));
    assert!(!e.should_block("https://i.ytimg.com/vi/x/hqdefault.jpg", "https://m.youtube.com/", "image"));
    assert!(!e.should_block("https://mio.300031.xyz/api/navigation", "https://mio.300031.xyz/mio/nav", "xmlhttprequest"));

    // YouTube 页面脚本
    let t = Instant::now();
    let s = e.page_script("https://m.youtube.com/watch?v=dQw4w9WgXcQ").unwrap();
    eprintln!("page script m.youtube.com: {} bytes in {:?}", s.len(), t.elapsed());
    assert!(s.contains("ytInitialPlayerResponse.adPlacements"));
    assert!(s.contains("\"name\":\"json-prune\""));
    assert!(s.contains("data-mio-adblock"));
    assert!(s.contains("ad-slot-renderer"));

    let g = e.generic_css("https://example.com/", vec!["ad-banner".into(), "adsbygoogle".into(), "content".into()], vec!["ad_box".into()]);
    eprintln!("generic css: {}", g);
    // 通用 class/id 规则按页面上出现的 class / id 查（iOS 优化版列表里的通用规则较少）
    assert!(g.contains("display:none"));

    // 序列化往返
    let t = Instant::now();
    let bytes = e.serialize();
    let mut e2 = MioEngine::deserialize(&bytes).unwrap();
    e2.set_resources(&corelibs, &ext).unwrap();
    eprintln!("serialize {} bytes, round trip {:?}", bytes.len(), t.elapsed());
    assert!(e2.should_block("https://googleads.g.doubleclick.net/pagead/id", "https://m.youtube.com/", "xmlhttprequest"));
    assert_eq!(e2.page_script("https://m.youtube.com/watch?v=dQw4w9WgXcQ").unwrap().len(), s.len());
}
