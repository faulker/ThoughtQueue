import XCTest
@testable import ThoughtQueue

final class SyncErrorMessageTests: XCTestCase {
    /// A -1009 carrying the "Local network prohibited" path description maps to the friendly message.
    func testLocalNetworkProhibitedIsMapped() {
        let err = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet, userInfo: [
            "_NSURLErrorNWPathKey": "unsatisfied (Local network prohibited), interface: en0"
        ])
        XCTAssertEqual(SyncErrorMessage.describe(err), SyncErrorMessage.localNetworkBlocked)
    }

    /// The marker is also found on a nested underlying error.
    func testUnderlyingErrorIsInspected() {
        let inner = NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "Local network prohibited"])
        let err = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet, userInfo: [NSUnderlyingErrorKey: inner])
        XCTAssertTrue(SyncErrorMessage.isLocalNetworkProhibited(err))
    }

    /// A plain offline error keeps its own description.
    func testOtherErrorsPassThrough() {
        let err = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet, userInfo: [NSLocalizedDescriptionKey: "offline"])
        XCTAssertEqual(SyncErrorMessage.describe(err), "offline")
    }
}
