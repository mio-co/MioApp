# AdGuard 高级规则运行库（GPL-3.0，见仓库 NOTICE）

由 `apple/MioKit/scripts/update-adguard-assets.sh` 从 npm 包原样复制（版本与仓库根 package-lock.json 一致）：

| 文件 | 来源 |
|---|---|
| scriptlets.corelibs.json | @adguard/scriptlets 2.5.1 `dist/scriptlets.corelibs.json` |
| extended-css.min.js | @adguard/extended-css 2.3.0 `dist/extended-css.min.js` |

MioAdvancedRules 用它们把 FilterEngine 查到的 scriptlet / 扩展 CSS 规则变成注入页面的 JS（与 v0.3.x MioAdblockCore 同样的做法）。
