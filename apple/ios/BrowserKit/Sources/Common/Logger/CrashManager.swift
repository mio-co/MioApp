// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation

// Mio (v0.4.1): Sentry (sentry-cocoa) is no longer linked. Upstream's DefaultCrashManager only ever started Sentry
// for Mozilla's own bundle ids (org.mozilla.ios.Firefox / FirefoxBeta) with a Sentry DSN in Info.plist and crash
// reports switched on; Mio has none of these, so it never sent anything. The manager is now a no-op with the same
// interface (protocol + init), which drops Sentry.framework (~2.7 MB) from the app.

// MARK: - CrashManager
public protocol CrashManager: Sendable {
    var crashedLastLaunch: Bool { get }
    func captureError(error: Error)
    func setup(sendCrashReports: Bool)
    func send(message: String,
              category: LoggerCategory,
              level: LoggerLevel,
              extraEvents: [String: String]?)
}

/**
 * Crash report for rust errors
 *
 * We implement this on exception classes that correspond to Rust errors to
 * customize how the crash reports look.
 *
 * CrashReporting implementers should test if exceptions implement this
 * interface.  If so, they should try to customize their crash reports to match.
 */
public protocol CustomCrashReport {
    var typeName: String { get }
    var message: String { get }
}

/// No-op crash manager (Mio has no crash reporting service).
public final class DefaultCrashManager: CrashManager {
    // MARK: - Init

    /// Same parameters as upstream minus the Sentry wrapper; all values are ignored.
    public init(appInfo: BrowserKitInformation = BrowserKitInformation.shared,
                isSimulator: Bool = DeviceInfo.isSimulator(),
                skipReleaseNameCheck: Bool = false,
                bundleIdentifier: @escaping @Sendable () -> String = { AppInfo.bundleIdentifier },
                appVersion: @escaping @Sendable () -> String = { AppInfo.appVersion }) {}

    // MARK: - CrashManager protocol

    /// Upstream read Sentry's "last run crashed" flag, which was never set in Mio (Sentry was never started).
    public var crashedLastLaunch: Bool { false }

    public func setup(sendCrashReports: Bool) {}

    public func send(message: String,
                     category: LoggerCategory,
                     level: LoggerLevel,
                     extraEvents: [String: String]?) {}

    public func captureError(error: Error) {}
}
