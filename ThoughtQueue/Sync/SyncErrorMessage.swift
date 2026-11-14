import Foundation

/// Turns sync/network errors into user-facing text.
enum SyncErrorMessage {
    static let localNetworkBlocked = "Local network access is blocked. Allow ThoughtQueue in System Settings > Privacy & Security > Local Network."

    /// Returns a clear message for the macOS Local Network privacy failure
    /// (`.notConnectedToInternet` whose path info says "Local network prohibited"),
    /// otherwise the error's own localized description.
    static func describe(_ error: Error) -> String {
        isLocalNetworkProhibited(error) ? localNetworkBlocked : error.localizedDescription
    }

    /// True for a -1009 error whose userInfo (or underlying error) mentions "Local network prohibited".
    static func isLocalNetworkProhibited(_ error: Error) -> Bool {
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain, ns.code == NSURLErrorNotConnectedToInternet else { return false }
        return mentionsProhibited(ns, depth: 0)
    }

    /// Searches userInfo values (and nested underlying errors) for the marker text.
    private static func mentionsProhibited(_ ns: NSError, depth: Int) -> Bool {
        for value in ns.userInfo.values where "\(value)".localizedCaseInsensitiveContains("local network prohibited") {
            return true
        }
        if depth < 3, let under = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            return mentionsProhibited(under, depth: depth + 1)
        }
        return false
    }
}
