#!/usr/bin/env python3
"""Mio rebrand for the firefox-ios fork (apple/ios). Idempotent; run from repo root:

    python3 apple/ios/mio/scripts/rebrand.py

What it does (and nothing else):
  1. AppName.shortName "Firefox" -> "Mio" (BrowserKit/Sources/Shared/AppName.swift)
  2. "Firefox" -> "Mio" in the *value* side of every .strings file and in the
     `value: "..."` defaults of Shared/Strings.swift (keys are left alone so lookups keep working).
  3. Replaces Firefox logo / app icon artwork with the Mio icon (apple/ios/mio/brand):
     every AppIcon*.appiconset, appIconAlternate_* imagesets, Liquid Glass .icon bundles,
     and the in-app Firefox logo / fox illustration imagesets.
Mozilla / MPL license headers and LICENSE are untouched.
"""
import json, os, re, shutil
from PIL import Image

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))  # apple/ios
FF = os.path.join(ROOT, "firefox-ios")
BRAND = os.path.join(ROOT, "mio", "brand")
ICON = Image.open(os.path.join(BRAND, "mio-appicon-1024.png")).convert("RGB")
LOGO = Image.open(os.path.join(BRAND, "mio-logo-480.png")).convert("RGBA")
changed = []

def w(path, text):
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)
    changed.append(os.path.relpath(path, ROOT))

# 1. AppName
p = os.path.join(ROOT, "BrowserKit/Sources/Shared/AppName.swift")
t = open(p, encoding="utf-8").read()
if 'case shortName = "Firefox"' in t:
    w(p, t.replace('case shortName = "Firefox"', 'case shortName = "Mio"'))

# 2. strings (values only)
STR_LINE = re.compile(r'^(\s*"(?:[^"\\]|\\.)*"\s*=\s*")((?:[^"\\]|\\.)*)("\s*;.*)$')
def fix_value(v):
    return v.replace("Firefox", "Mio")
for base in (FF, os.path.join(ROOT, "BrowserKit")):
    for dp, dn, fn in os.walk(base):
        if "firefox-ios-tests" in dp or "/Tests" in dp:
            continue
        for f in fn:
            if not f.endswith(".strings"):
                continue
            p = os.path.join(dp, f)
            raw = open(p, "rb").read()
            enc = "utf-16" if raw[:2] in (b"\xff\xfe", b"\xfe\xff") else "utf-8"
            t = raw.decode(enc)
            if "Firefox" not in t:
                continue
            out = []
            for line in t.split("\n"):
                m = STR_LINE.match(line)
                if m and "Firefox" in m.group(2):
                    line = m.group(1) + fix_value(m.group(2)) + m.group(3)
                out.append(line)
            n = "\n".join(out)
            if n != t:
                w(p, n)

p = os.path.join(FF, "Shared/Strings.swift")
t = open(p, encoding="utf-8").read()
VAL = re.compile(r'(value:\s*")((?:[^"\\]|\\.)*)(")')
n = VAL.sub(lambda m: m.group(1) + fix_value(m.group(2)) + m.group(3), t)
if n != t:
    w(p, n)

# 3. artwork
def save_png(img, path, size=None, opaque=True):
    im = img.copy()
    if size:
        im = im.resize((size, size), Image.LANCZOS)
    if opaque:
        im = im.convert("RGB")
    im.save(path, "PNG", optimize=True)

def replace_appiconset(d):
    cj = os.path.join(d, "Contents.json")
    j = json.load(open(cj))
    for f in os.listdir(d):
        if f != "Contents.json":
            os.remove(os.path.join(d, f))
    images = []
    for img in j.get("images", []):
        size = img.get("size", "1024x1024")
        scale = img.get("scale", "1x")
        px = int(round(float(size.split("x")[0]) * float(scale.rstrip("x"))))
        appearance = "".join(a["value"] for a in img.get("appearances", []))
        name = f"mio-{px}{('-' + appearance) if appearance else ''}.png"
        save_png(ICON, os.path.join(d, name), px)
        img = dict(img); img["filename"] = name
        images.append(img)
    j["images"] = images
    open(cj, "w").write(json.dumps(j, indent=2) + "\n")
    changed.append(os.path.relpath(d, ROOT))

def replace_imageset(d, art, opaque):
    cj = os.path.join(d, "Contents.json")
    j = json.load(open(cj))
    for f in os.listdir(d):
        if f != "Contents.json":
            os.remove(os.path.join(d, f))
    save_png(art, os.path.join(d, "mio.png"), None, opaque)
    props = j.get("properties", {})
    props.pop("preserves-vector-representation", None)
    nj = {"images": [{"idiom": "universal", "filename": "mio.png"}],
          "info": j.get("info", {"author": "xcode", "version": 1})}
    if props:
        nj["properties"] = props
    open(cj, "w").write(json.dumps(nj, indent=2) + "\n")
    changed.append(os.path.relpath(d, ROOT))

def replace_icon_bundle(d):
    shutil.rmtree(os.path.join(d, "Assets"), ignore_errors=True)
    os.makedirs(os.path.join(d, "Assets"))
    save_png(LOGO, os.path.join(d, "Assets", "mio.png"), None, opaque=False)
    j = {
        "fill": {"solid": "srgb:1.00000,1.00000,1.00000,1.00000"},
        "groups": [{"layers": [{"image-name": "mio.png", "name": "mio"}],
                    "position": {"scale": 1.6, "translation-in-points": [0, 0]},
                    "shadow": {"kind": "neutral", "opacity": 0.2},
                    "translucency": {"enabled": False, "value": 0.5}}],
        "supported-platforms": {"circles": ["watchOS"], "squares": "shared"},
    }
    open(os.path.join(d, "icon.json"), "w").write(json.dumps(j, indent=2) + "\n")
    changed.append(os.path.relpath(d, ROOT))

LOGO_SETS = {"logoFirefoxLarge", "fxHomeHeaderLogoBall", "fxHomeHeaderLogoText", "faviconFox",
             "foxWithStars", "foxDefaultBrowser", "foxConfirmation", "onboardingFoxyWindow", "logo-glyph"}
for dp, dn, fn in os.walk(FF):
    if "firefox-ios-tests" in dp:
        continue
    stem, ext = os.path.splitext(os.path.basename(dp))
    if ext == ".appiconset":
        replace_appiconset(dp)
    elif ext == ".icon" and "LiquidGlassAppIcons" in dp:
        replace_icon_bundle(dp)
    elif ext == ".imageset" and stem.startswith("appIconAlternate_"):
        replace_imageset(dp, ICON, opaque=True)
    elif ext == ".imageset" and stem in LOGO_SETS:
        replace_imageset(dp, LOGO, opaque=False)

print(f"{len(changed)} paths changed")
