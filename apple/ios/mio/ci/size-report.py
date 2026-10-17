#!/usr/bin/env python3
# Mio (v0.4.1): size report for the iOS ipa / .app, and a before/after comparison.
#
#   size-report.py measure <Mio.ipa | Mio.app> <out.json>       # one build (assetutil needs macOS + Xcode)
#   size-report.py compare <before.json> <after.json> <out.md>  # markdown table (also printed)
#
# Sizes are bytes of file content (not disk blocks). The ipa size is the zip as shipped.
import json, os, re, subprocess, sys, tempfile, zipfile, collections


def tree_size(path):
    if os.path.isfile(path):
        return os.path.getsize(path)
    total = 0
    for dp, _, fn in os.walk(path):
        for f in fn:
            fp = os.path.join(dp, f)
            if not os.path.islink(fp):
                total += os.path.getsize(fp)
    return total


def assetutil(car):
    """Per-asset totals from `xcrun assetutil --info` (SizeOnDisk of every rendition)."""
    try:
        out = subprocess.run(["xcrun", "--sdk", "iphoneos", "assetutil", "--info", car],
                             capture_output=True, text=True, timeout=300).stdout
        items = json.loads(out)
    except Exception as e:  # noqa: BLE001 (report keeps going without it)
        return {"error": str(e)}
    by_name = collections.Counter()
    by_type = collections.Counter()
    renditions = 0
    for it in items:
        if "SizeOnDisk" not in it:
            continue
        renditions += 1
        name = it.get("Name") or it.get("RenditionName") or "?"
        by_name[name] += it["SizeOnDisk"]
        by_type[it.get("AssetType", "?")] += it["SizeOnDisk"]
    return {"renditions": renditions,
            "assets": len(by_name),
            "renditionBytes": sum(by_name.values()),
            "byType": dict(by_type.most_common()),
            "top": by_name.most_common(25)}


def measure(src, out):
    tmp = None
    ipa_size = None
    if src.endswith(".ipa"):
        ipa_size = os.path.getsize(src)
        tmp = tempfile.mkdtemp()
        with zipfile.ZipFile(src) as z:
            z.extractall(tmp)
        payload = os.path.join(tmp, "Payload")
        app = os.path.join(payload, [d for d in os.listdir(payload) if d.endswith(".app")][0])
        # zipfile drops the executable bit; sizes are what matter here
    else:
        app = src
    r = {"ipa": ipa_size, "app": tree_size(app), "items": {}}
    items = r["items"]
    exe = None
    try:
        exe = subprocess.run(["/usr/libexec/PlistBuddy", "-c", "Print :CFBundleExecutable",
                              os.path.join(app, "Info.plist")], capture_output=True, text=True).stdout.strip()
    except Exception:  # noqa: BLE001
        pass
    exe = exe or "Client"
    items["main binary (%s)" % exe] = tree_size(os.path.join(app, exe))
    items["Assets.car"] = tree_size(os.path.join(app, "Assets.car"))
    fw_dir = os.path.join(app, "Frameworks")
    if os.path.isdir(fw_dir):
        for fw in sorted(os.listdir(fw_dir)):
            p = os.path.join(fw_dir, fw)
            name = re.sub(r"_-?[0-9A-F]{6,}_PackageProduct", "", fw)
            name = re.sub(r"_PackageProduct", "", name)
            items["Frameworks/" + name] = tree_size(p)
    for b in sorted(os.listdir(app)):
        if b.endswith(".bundle"):
            items[b] = tree_size(os.path.join(app, b))
    lproj = 0
    lproj_dirs = set()
    other_nonruntime = 0
    for dp, dn, fn in os.walk(app):
        for d in list(dn):
            if d.endswith(".lproj"):
                lproj += tree_size(os.path.join(dp, d))
                lproj_dirs.add(d)
                dn.remove(d)
        for f in fn:
            if re.search(r"\.(xctestplan|xcconfig|ya?ml|xcfilelist|swiftmodule|swiftdoc|abi\.json|swiftsourceinfo|swiftinterface)$", f):
                other_nonruntime += os.path.getsize(os.path.join(dp, f))
    items["*.lproj (all)"] = lproj
    r["lprojLanguages"] = sorted(lproj_dirs)
    items["non-runtime files (testplans, yaml, swiftmodule, …)"] = other_nonruntime
    for f in ["kitHeroGif.gif", "BrowserKit_OnboardingKit.bundle/IntroVideo.mp4"]:
        items[f] = tree_size(os.path.join(app, f)) if os.path.exists(os.path.join(app, f)) else 0
    car = os.path.join(app, "Assets.car")
    if os.path.exists(car):
        r["assetutil"] = assetutil(car)
    ob = os.path.join(app, "BrowserKit_OnboardingKit.bundle", "Assets.car")
    if os.path.exists(ob):
        r["assetutilOnboarding"] = assetutil(ob)
    with open(out, "w") as fh:
        json.dump(r, fh, indent=1)
    print(json.dumps({k: v for k, v in r.items() if k not in ("assetutil", "assetutilOnboarding")}, indent=1))


def mb(n):
    return "—" if n is None else "%.1f MB" % (n / 1e6)


def compare(a_path, b_path, out):
    a = json.load(open(a_path))
    b = json.load(open(b_path))
    rows = [("**Mio.ipa (shipped zip)**", a.get("ipa"), b.get("ipa")),
            ("**Mio.app (unzipped)**", a.get("app"), b.get("app"))]
    keys = list(dict.fromkeys(list(a["items"]) + list(b["items"])))
    keys.sort(key=lambda k: -max(a["items"].get(k, 0), b["items"].get(k, 0)))
    for k in keys:
        x, y = a["items"].get(k), b["items"].get(k)
        if max(x or 0, y or 0) < 200_000:
            continue
        rows.append((k, x, y))
    lines = ["| item | v0.4.0 | this build | Δ |", "| --- | ---: | ---: | ---: |"]
    for k, x, y in rows:
        d = "" if x is None or y is None else ("%+.1f MB" % ((y - x) / 1e6))
        if x is not None and y is None:
            d = "removed"
        lines.append("| %s | %s | %s | %s |" % (k, mb(x), mb(y if y is not None else None) if y is not None else "removed", d))
    for label, key in [("Assets.car", "assetutil"), ("OnboardingKit Assets.car", "assetutilOnboarding")]:
        ua, ub = a.get(key) or {}, b.get(key) or {}
        if ua or ub:
            lines.append("")
            lines.append("**%s (assetutil)**: %s renditions / %s assets / %s → %s renditions / %s assets / %s" % (
                label, ua.get("renditions", "—"), ua.get("assets", "—"), mb(ua.get("renditionBytes")),
                ub.get("renditions", "—"), ub.get("assets", "—"), mb(ub.get("renditionBytes"))))
            for side, u in [("v0.4.0", ua), ("this build", ub)]:
                if u.get("top"):
                    lines.append("- %s top: %s" % (side, ", ".join("%s %.2f MB" % (n, s / 1e6) for n, s in u["top"][:12])))
    lines.append("")
    lines.append("Languages: %d → %d (%s)" % (len(a.get("lprojLanguages", [])), len(b.get("lprojLanguages", [])),
                                             ", ".join(b.get("lprojLanguages", []))))
    text = "\n".join(lines) + "\n"
    open(out, "w").write(text)
    print(text)


if __name__ == "__main__":
    if sys.argv[1] == "measure":
        measure(sys.argv[2], sys.argv[3])
    elif sys.argv[1] == "compare":
        compare(sys.argv[2], sys.argv[3], sys.argv[4])
    else:
        sys.exit("usage: size-report.py measure|compare …")
