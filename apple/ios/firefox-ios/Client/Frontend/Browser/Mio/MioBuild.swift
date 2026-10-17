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
    /// MioCore site that renders mio://home (minimal implementation; the native bridge comes from MioKit).
    static let homeContentURL = URL(string: "https://mio.300031.xyz/")!

    /// True for mio://… URLs (handled in-app, never sent to WebKit as-is).
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
        let path = url.path
        return (path.isEmpty || path == "/") && (url.query ?? "").isEmpty
    }

    /// Where a mio:// URL actually loads. Only mio://home exists for now; anything else falls back to it.
    static func resolve(_ url: URL) -> URL {
        // TODO(MioKit): route other mio:// paths (mio://settings, mio://extensions, …) once MioKit's
        // scheme handler lands (apple/MioKit/README.md, line C).
        return homeContentURL
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

    // MARK: - Defaults

    private static let defaultsVersionKey = "mio.defaults.version"
    private static let defaultsVersion = 1

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

        guard (prefs.intForKey(defaultsVersionKey) ?? 0) < Int32(defaultsVersion) else { return }

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
