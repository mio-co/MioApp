# Mio for iOS / iPadOS (firefox-ios fork)

`apple/ios/` is a fork of [firefox-ios](https://github.com/mozilla-mobile/firefox-ios) (Mozilla Public License 2.0).
The upstream `LICENSE` and every MPL header are kept; Mio's own changes are MPL-2.0 too.
Mio is not affiliated with Mozilla. "Firefox" and the Firefox logos are Mozilla trademarks and are not used by Mio.

- Upstream base: tag **`firefox-v158.1`** (imported as a source snapshot, without Mozilla's git history).
- Not imported: `focus-ios/`, `SampleBrowser/`, `SampleComponentLibraryApp/`, `test-fixtures/` (UI-test fixtures),
  `taskcluster/`, `bitrise.yml`, upstream `.github/`, `monorepo-migration/`, `firefox-ios/ThirdParty/sentry-cli`.
- Build: Xcode 26.5, `firefox-ios/Client.xcodeproj`, scheme **Firefox**, configuration **Firefox** (release channel).
  Product is still `Client.app` inside the build folder; display name **Mio**, bundle id **xyz.mio.app**,
  version **0.4.0 (10)**. CI: `.github/workflows/ios-firefox.yml`, scripts in `mio/ci/`.

## Where the Mio changes are

Every hook in upstream files is marked with a `// Mio:` comment (`grep -rn "Mio:" apple/ios`).
Mio-only code lives in `firefox-ios/Client/Frontend/Browser/Mio/` (an Xcode synchronized folder, new files there are
picked up automatically):

| File | What |
| --- | --- |
| `MioBuild.swift` | switches for disabled Mozilla services, mio://home URLs, first-run / privacy defaults |
| `MioKitHost.swift` | glue to the shared `apple/MioKit` package: one `MioKitContainer`, mio:// scheme handler, per-tab `MioWebViewModules` (module scripts, MioCore bridge, ad-block rule lists), `MioCoreBridgeDelegate` (device info, open tab, save to Mio, permission prompt) |
| `MioExtensionsSetting.swift` | Settings → "Mio 扩展" page generated from MioKit's `MioExtensionSettingsModel` (module switches + sub-settings) |

MioKit (`apple/MioKit`, interface in its README) is linked into the Client target as a local Swift package
(`Client.xcodeproj` file reference `../../MioKit`, product `MioKit`); its SafariConverterLib dependency is pinned in
the workspace `Package.resolved`. Hooks: `TabConfigurationProvider` (mio scheme handler), `Tab.createWebview` / `close` /
night & no-image mode re-injection (Firefox's `UserScriptManager` removes all user scripts, so MioKit keeps Firefox's
as host scripts and reinstalls), `decidePolicyFor` (main-frame `willNavigateMainFrame`, mio:// allowed),
`ContentBlocker.removeTrackingProtection` (Firefox clears every rule list; Mio's are added back).

Branding (strings + artwork) is produced by `mio/scripts/rebrand.py` (idempotent; re-run after an upstream merge).

## mio://home

- New tab and home page default to **mio://home**; it renders the MioCore site `https://mio.300031.xyz/`.
- The address bar shows **Mio** for it (editing shows `mio://home`). Typing / linking `mio://home`, or opening it
  from outside (`mio` is the app's public URL scheme), loads the same page.
- mio:// pages are served by MioKit's `MioSchemeHandler` (mio://home redirects to the MioCore home path,
  default `/mio/nav`; mio://offline, mio://about).
- The native bridge (`window.Mio.call`, API v1) is **only** for the MioCore origin and `mio://` pages; MioKit checks the
  calling frame's security origin. Interface contract: `apple/MioKit/README.md` (line C).

## Mozilla services

Removed or switched off (the Swift code mostly stays compiled but is never started):

| Service | Status in Mio |
| --- | --- |
| Mozilla accounts + Sync (FxA, send tab, push via Autopush) | account manager never created; Settings section and main-menu sign-in row removed; `aps` entitlement removed |
| Glean telemetry (events, metrics, daily usage ping, MetricKit upload) | Glean is never initialized → nothing is recorded or uploaded; toggles removed |
| Sentry crash reporting | forced off; DSN empty; `sentry-cli` not imported |
| Nimbus experiments / rollouts / messaging | `Experiments.shared` is `NimbusDisabled` (feature-manifest defaults only); no Nimbus server URL |
| Remote Settings periodic sync | disabled; bundled `RemoteSettingsData` dumps are used |
| Pocket / sponsored shortcuts / Firefox Suggest | prefs forced off, Suggest background ingestion not scheduled, Pocket API key empty |
| Ad attribution (Adjust SKAdNetwork ids, conversion events) | Info.plist keys removed, conversion tracking not started |
| Firefox onboarding, Mozilla terms of use, default-browser card, App Store review, Mozilla support / feedback / privacy notice / "your rights" links | skipped / removed from Settings |

Kept: bookmarks, history, reading list (Rust Places), reader mode, private browsing, Enhanced Tracking Protection,
tab overview, downloads, passwords / autofill (local only), settings.

### Mozilla code that is still linked

- **Rust application-services** (`MozillaRustComponents.xcframework`, downloaded from Mozilla's Taskcluster at build
  time): Places (bookmarks/history), Logins, Autofill, Tabs, Remote Settings client, Suggest, Nimbus, FxA client,
  Sync manager, Push, Merino, Relay, Ads client. Places and Logins are required; the rest are inert but linked
  because they ship in one binary.
- **Glean Swift SDK** (`glean-swift`) and the generated `GleanMetrics` (compiled, never initialized).
- **sentry-cocoa** (compiled, never started).
- Nimbus feature manifest code generation (`nimbus-fml`, build-time tool) and Glean `sdk_generator.sh` (build-time).
- Search engine list / icons come from Remote Settings dumps; first lookup may still hit Mozilla's Remote Settings
  server if a collection has no bundled dump (not verified yet).
- App extensions (Share, Widgets, Credential Provider, Notification Service, Sticker, Action) still build but are
  stripped from the ipa (a free Apple ID allows only a few App IDs per week).

## Sideloading

The ipa is unsigned (same as the 0.3.x SideStore flow). Without an app group the profile already falls back to
Documents and tab session data falls back to Application Support (Mio change in `TabFileManager`).
