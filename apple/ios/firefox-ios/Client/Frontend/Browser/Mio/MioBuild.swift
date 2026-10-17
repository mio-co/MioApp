// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

// Mio fork of firefox-ios: central switches for the things Mio changes.
// Keep Mio-specific logic in this folder and only add small hooks in upstream files
// (search the codebase for "Mio:" to find every hook).

import Common
import Foundation
import Shared

enum MioBuild {
    // MARK: - mio://home

    /// Internal address shown for the Mio home page. The address bar shows "Mio" for it.
    static let homeScheme = "mio"
    static let homeDisplayURL = URL(string: "mio://home")!
    /// MioCore site behind mio://home (default home / new tab URL; mio:// pages themselves are served by MioKit's
    /// MioSchemeHandler, which redirects mio://home to the configured MioCore home path).
    /// MioCore home page (same as MioKit's mio.core.homePath default). When MioCore is behind Cloudflare Access the first
    /// load lands on the Access login page; after signing in Access redirects back here (redirect_url=/mio/nav).
    static let homeContentURL = URL(string: "https://mio.300031.xyz/mio/nav")!
    /// Home URL written by defaults version 1 (MioCore root); migrated to homeContentURL.
    private static let legacyHomeContentURL = "https://mio.300031.xyz/"

    private static let homePaths: Set<String> = ["", "/", "/mio/nav", "/mio/nav/"]

    /// True for mio://… URLs (served by MioKit's scheme handler, see MioKitHost).
    static func isMioScheme(_ url: URL?) -> Bool {
        return url?.scheme?.lowercased() == homeScheme
    }

    /// True when `url` is the page behind mio://home (MioCore origin root).
    static func isMioHome(_ url: URL?) -> Bool {
        guard let url else { return false }
        if isMioScheme(url) { return true }
        guard url.scheme == homeContentURL.scheme,
              url.host?.lowercased() == homeContentURL.host,
              url.port == nil || url.port == 443
        else { return false }
        // MioCore root, or its nav page (MioKit's default home path is /mio/nav)
        let path = url.path
        return homePaths.contains(path) && (url.query ?? "").isEmpty
    }


    /// URL to display in the address bar for `url`.
    static func displayURL(for url: URL?) -> URL? {
        return isMioHome(url) ? homeDisplayURL : url
    }

    /// Text the (non-editing) address bar shows for a mio:// URL.
    static let homeDisplayTitle = "Mio"

    // MARK: - Disabled Mozilla services

    /// Mozilla telemetry (Glean upload, daily usage ping), Sentry crash reports, Nimbus experiments
    /// and rollouts, Mozilla accounts / Sync, Pocket / sponsored content and Firefox Suggest are off in Mio.
    /// The code is still compiled (see apple/ios/MIO.md for what remains); these flags keep it inert.
    static let telemetryEnabled = false
    static let crashReportingEnabled = false
    static let experimentsEnabled = false
    static let mozillaAccountsEnabled = false
    static let remoteSettingsSyncEnabled = false
    /// The upstream "Synced tabs" pane of the tab overview needs a Mozilla account; Mio has no Sync, so the tab
    /// overview only has normal + private tabs (v0.4.1).
    static let syncedTabsPanelEnabled = false

    /// Tab overview panel Mio can show: requests for the synced-tabs pane open the normal tabs instead.
    static func tabTrayPanel(_ panel: TabTrayPanelType) -> TabTrayPanelType {
        return (!syncedTabsPanelEnabled && panel == .syncedTabs) ? .tabs : panel
    }

    /// Tab overview panes in display order (upstream order without "Synced tabs" when it is off).
    static func tabTrayPanels(_ panels: [TabTrayPanelType]) -> [TabTrayPanelType] {
        return syncedTabsPanelEnabled ? panels : panels.filter { $0 != .syncedTabs }
    }

    /// Settings → App icon: Mio ships a single app icon (v0.4.1 removed the upstream alternate icons, ~45 MB of
    /// compiled icon renditions), so the picker is hidden.
    static let alternateAppIconsEnabled = false

    /// Firefox onboarding (intro cards, video, "what's new" update cards): Mio never shows it, and its media
    /// (OnboardingKit video / GIF / images) is not shipped since v0.4.1.
    static let firefoxOnboardingEnabled = false

    // MARK: - Defaults

    private static let defaultsVersionKey = "mio.defaults.version"
    private static let defaultsVersion = 2

    /// Applied on every launch before telemetry / Nimbus / FxA would start.
    /// - Privacy prefs are forced off every launch (their toggles are removed from Settings).
    /// - Home / new tab defaults and first-run skips are applied once, so the user can change them later.
    static func applyDefaults(prefs: Prefs) {
        prefs.setBool(false, forKey: AppConstants.prefSendUsageData)
        prefs.setBool(false, forKey: AppConstants.prefSendCrashReports)
        prefs.setBool(false, forKey: AppConstants.prefSendDailyUsagePing)
        prefs.setBool(false, forKey: AppConstants.prefStudiesToggle)
        prefs.setBool(false, forKey: AppConstants.prefRolloutsToggle)
        // Sentry reads this before the profile exists (AppLaunchUtil): keep the raw defaults in sync too.
        NSUserDefaultsPrefs(prefix: "profile").setBool(false, forKey: AppConstants.prefSendCrashReports)

        // Sponsored / Pocket / Suggest content stays off.
        prefs.setBool(false, forKey: PrefsKeys.FeatureFlags.SponsoredShortcuts)
        prefs.setBool(false, forKey: PrefsKeys.UserFeatureFlagPrefs.ASPocketStories)
        prefs.setBool(false, forKey: PrefsKeys.FeatureFlags.FirefoxSuggest)
        prefs.setBool(false, forKey: PrefsKeys.SearchSettings.showFirefoxSponsoredSuggestions)
        prefs.setBool(false, forKey: PrefsKeys.SearchSettings.showFirefoxNonSponsoredSuggestions)

        let appliedVersion = prefs.intForKey(defaultsVersionKey) ?? 0
        guard appliedVersion < Int32(defaultsVersion) else { return }

        // Version 1 → 2: home / new tab pointed at the MioCore root; MioCore's home page is /mio/nav.
        // Only rewritten if the user did not pick another page.
        if appliedVersion == 1 {
            for key in [PrefsKeys.NewTabCustomUrlPrefKey, PrefsKeys.HomeButtonHomePageURL]
            where prefs.stringForKey(key) == legacyHomeContentURL {
                prefs.setString(homeContentURL.absoluteString, forKey: key)
            }
            prefs.setInt(Int32(defaultsVersion), forKey: defaultsVersionKey)
            return
        }

        // Home page and new tab: mio://home (rendered from MioCore).
        prefs.setString(NewTabPage.homePage.rawValue, forKey: PrefsKeys.KeyNewTab)
        prefs.setString(homeContentURL.absoluteString, forKey: PrefsKeys.NewTabCustomUrlPrefKey)
        prefs.setString(NewTabPage.homePage.rawValue, forKey: PrefsKeys.HomePageTab)
        prefs.setString(homeContentURL.absoluteString, forKey: PrefsKeys.HomeButtonHomePageURL)

        // No Firefox onboarding / Mozilla terms of use / default-browser card.
        prefs.setInt(1, forKey: PrefsKeys.IntroSeen)
        prefs.setBool(true, forKey: PrefsKeys.TermsOfUseAccepted)
        prefs.setBool(true, forKey: PrefsKeys.KeyDidShowDefaultBrowserOnboarding)

        prefs.setInt(Int32(defaultsVersion), forKey: defaultsVersionKey)
    }
}
