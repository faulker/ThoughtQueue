import XCTest
@testable import ThoughtQueue

/// Table-driven tests for the pure three-way planner.
final class SyncPlannerTests: XCTestCase {
    private typealias Entry = SyncState.Entry

    /// One row: the local hash, remote ETag, and base entry for key "a.md", and the expected action.
    private struct Row {
        let name: String
        let local: String?
        let remote: String?
        let base: Entry?
        let expected: SyncAction
    }

    private let base = Entry(localHash: "L0", remoteETag: "E0")

    /// Every row of the single-key decision table.
    func testDecisionTable() {
        let key = "a.md"
        let rows: [Row] = [
            Row(name: "first sync, both sides", local: "L1", remote: "E1", base: nil, expected: .conflict(key)),
            Row(name: "first sync, local only", local: "L1", remote: nil, base: nil, expected: .upload(key)),
            Row(name: "first sync, remote only", local: nil, remote: "E1", base: nil, expected: .download(key)),
            Row(name: "unchanged both", local: "L0", remote: "E0", base: base, expected: .noop(key)),
            Row(name: "local edit", local: "L1", remote: "E0", base: base, expected: .upload(key)),
            Row(name: "remote edit", local: "L0", remote: "E1", base: base, expected: .download(key)),
            Row(name: "both edited", local: "L1", remote: "E1", base: base, expected: .conflict(key)),
            Row(name: "local deleted, remote unchanged", local: nil, remote: "E0", base: base, expected: .deleteRemote(key)),
            Row(name: "remote deleted, local unchanged", local: "L0", remote: nil, base: base, expected: .deleteLocal(key)),
            Row(name: "local deleted, remote edited", local: nil, remote: "E1", base: base, expected: .conflict(key)),
            Row(name: "remote deleted, local edited", local: "L1", remote: nil, base: base, expected: .conflict(key)),
            Row(name: "deleted both", local: nil, remote: nil, base: base, expected: .forget(key)),
        ]
        for row in rows {
            let actions = SyncPlanner.plan(
                local: row.local.map { [key: $0] } ?? [:],
                remote: row.remote.map { [key: $0] } ?? [:],
                base: row.base.map { [key: $0] } ?? [:],
                openConflicts: [])
            XCTAssertEqual(actions, [row.expected], row.name)
        }
    }

    /// A key with an open conflict gets no action, whatever its state.
    func testOpenConflictIsSkipped() {
        let actions = SyncPlanner.plan(local: ["a.md": "L1", "b.md": "L1"],
                                       remote: ["a.md": "E1"],
                                       base: ["a.md": base],
                                       openConflicts: ["a.md"])
        XCTAssertEqual(actions, [.upload("b.md")])
    }

    /// Without a base entry, a file missing on one side is copied across, never deleted.
    func testNoBaseNeverDeletes() {
        let actions = SyncPlanner.plan(local: ["x.md": "L", "Work/y.md": "L"],
                                       remote: ["z.md": "E", "Ideas/w.md": "E"],
                                       base: [:],
                                       openConflicts: [])
        for action in actions {
            switch action {
            case .deleteLocal, .deleteRemote, .forget: XCTFail("No-base plan must not delete: \(action)")
            default: break
            }
        }
        XCTAssertEqual(actions, [.download("Ideas/w.md"), .upload("Work/y.md"), .upload("x.md"), .download("z.md")])
    }

    /// Actions come back sorted by key and cover the union of all three inputs.
    func testMixedPlanIsSortedAndComplete() {
        let actions = SyncPlanner.plan(local: ["b.md": "L0", "c.md": "L1"],
                                       remote: ["b.md": "E0", "c.md": "E0", "d.md": "E9"],
                                       base: ["b.md": base, "c.md": base, "e.md": base],
                                       openConflicts: [])
        XCTAssertEqual(actions, [.noop("b.md"), .upload("c.md"), .download("d.md"), .forget("e.md")])
    }
}
