// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation
import WebKit

/// Placeholder for the MioCore native bridge (photo sync, device control, … — things a plain web page can't do).
///
/// The real implementation lives in the shared Swift package `apple/MioKit` (line C, branch `feat/mio-kit`);
/// its interface contract is `apple/MioKit/README.md`. Until MioKit is linked into this app the bridge is a
/// no-op, so mio://home renders MioCore as an ordinary web page.
///
/// Security rule (from the v0.4.0 plan): the bridge is only exposed to the MioCore origin
/// (`MioBuild.homeContentURL`) and mio:// pages — never to other sites.
@MainActor
protocol MioHostBridge: AnyObject {
    /// Called for every new tab web view; MioKit installs its script message handlers here.
    func install(on webView: WKWebView)
    /// Whether `url` may talk to the bridge.
    func isAllowed(origin url: URL?) -> Bool
}

@MainActor
final class MioNoopHostBridge: MioHostBridge {
    static let shared = MioNoopHostBridge()

    func install(on webView: WKWebView) {
        // TODO(MioKit): replace with MioKit's bridge (`MioCoreBridge`) once apple/MioKit is linked into Client.
    }

    func isAllowed(origin url: URL?) -> Bool {
        guard let url else { return false }
        if MioBuild.isMioScheme(url) { return true }
        return url.scheme == "https" && url.host?.lowercased() == MioBuild.homeContentURL.host
    }
}
