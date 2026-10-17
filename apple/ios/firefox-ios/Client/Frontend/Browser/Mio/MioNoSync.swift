// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

// Mio (v0.4.1): Mozilla Sync is not part of the Mio app. The Client target no longer links / embeds
// Sync.framework and builds with MIO_NO_SYNC (Firefox.xcconfig). This file provides:
//   * MioNoSyncManager: a no-op SyncManager used by BrowserProfile instead of RustSyncManager;
//   * RustSyncManagerAPI.TogglableEngine: the only Sync.framework type the Client still names
//     (SyncContentSettingsViewController, which is unreachable in Mio because Firefox account
//     sign-in is hidden, but still compiled).
// Bookmarks, history, tabs and logins stay local (places / tabs / logins stores are opened by the
// profile as before); only the network sync engines are gone.

#if MIO_NO_SYNC

import Foundation
import Shared

import enum MozillaAppServices.SyncReason
import struct MozillaAppServices.SyncResult

/// Stand-in for Sync.framework's `RustSyncManagerAPI`, carrying only the engine names.
public enum RustSyncManagerAPI {
    // Names of collections that can be enabled/disabled locally (same raw values as upstream).
    public enum TogglableEngine: String, CaseIterable, Sendable {
        case tabs
        case passwords
        case bookmarks
        case history
        case creditcards
        case addresses
    }
}

/// Mozilla Sync is disabled in Mio: every sync request fails fast with this error.
public struct MioSyncDisabledError: MaybeErrorType {
    public let description = "Mozilla Sync is not available in Mio."
}

/// No-op `SyncManager`. Never syncs, never schedules timers, never touches the network.
public final class MioNoSyncManager: SyncManager, @unchecked Sendable {
    public init() {}

    public var isSyncing: Bool { false }
    public var lastSyncFinishTime: Timestamp? {
        get { nil }
        set { _ = newValue }
    }
    public var syncDisplayState: SyncDisplayState? { nil }

    public func syncTabs() -> Deferred<Maybe<SyncResult>> {
        return deferMaybe(MioSyncDisabledError())
    }

    public func syncHistory() -> Deferred<Maybe<SyncResult>> {
        return deferMaybe(MioSyncDisabledError())
    }

    public func syncNamedCollections(why: SyncReason, names: [String]) -> Deferred<Maybe<SyncResult>> {
        return deferMaybe(MioSyncDisabledError())
    }

    public func syncPostSyncSettingsChange(why: SyncReason, names: [String]) {}

    public func reportOpenSyncSettingsMenuTelemetry() {}

    @discardableResult
    public func syncEverything(why: SyncReason) -> Success {
        return succeed()
    }

    public func endTimedSyncs() {}
    public func applicationDidBecomeActive() {}
    public func applicationDidEnterBackground() {}

    public func checkCreditCardEngineEnablement() -> Bool {
        return false
    }

    @discardableResult
    public func onRemovedAccount() -> Success {
        return succeed()
    }

    @discardableResult
    public func onAddedAccount() -> Success {
        return succeed()
    }
}

#endif
