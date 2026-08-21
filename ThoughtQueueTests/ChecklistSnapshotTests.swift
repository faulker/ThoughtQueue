import XCTest
import AppKit
@testable import ThoughtQueue

/// Not an assertion suite: renders the checklist to a PNG so its layout and drawing can be eyeballed.
/// Skipped unless TQ_SNAPSHOT_DIR is set.
final class ChecklistSnapshotTests: XCTestCase {
    func testRenderChecklistToPNG() throws {
        guard let outDir = ProcessInfo.processInfo.environment["TQ_SNAPSHOT_DIR"] else {
            throw XCTSkip("set TQ_SNAPSHOT_DIR to capture")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tq-snap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NoteStore.shared.rootURL = root
        defer { NoteStore.shared.rootURL = nil; try? FileManager.default.removeItem(at: root) }

        let body = "# Groceries\n\n- [ ] Milk\n- [x] Eggs\n- [ ] Bread and a much longer item name\n\n## Hardware\n- [ ] Screws\n"
        let note = try XCTUnwrap(NoteStore.shared.createNote(title: "Groceries", body: body, category: nil))
        let vc = NoteEditorViewController(note: note)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = vc
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        window.layoutIfNeeded()

        XCTAssertEqual(vc.contentMode, .checklist)

        let view = try XCTUnwrap(window.contentView)
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let url = URL(fileURLWithPath: outDir).appendingPathComponent("checklist.png")
        try png.write(to: url)
        window.close()
    }
}
