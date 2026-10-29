import CoreGraphics
import XCTest
@testable import MacWMCore

final class CoreTests: XCTestCase {
    func testStartupSpiral() {
        var layout = Layout(splitRatio: 0.5)
        let work = CGRect(x: 0, y: 0, width: 160, height: 90)
        layout.reconcile(visible: [3, 1, 2], anchor: nil, work: work, gap: 0)
        let frames = layout.frames(in: work, gap: 0)
        XCTAssertEqual(frames[1]!.minX, 0, accuracy: 0.01)
        XCTAssertEqual(frames[1]!.width, 80, accuracy: 0.01)
        XCTAssertEqual(frames[1]!.height, 90, accuracy: 0.01)
        XCTAssertEqual(frames[2]!.minX, 80, accuracy: 0.01)
        XCTAssertEqual(frames[2]!.minY, 0, accuracy: 0.01)
        XCTAssertEqual(frames[2]!.height, 45, accuracy: 0.01)
        XCTAssertEqual(frames[3]!.minX, 80, accuracy: 0.01)
        XCTAssertEqual(frames[3]!.minY, 45, accuracy: 0.01)
        XCTAssertEqual(frames[3]!.height, 45, accuracy: 0.01)
    }

    func testNewWindowSplitsTheFocusedPane() {
        var layout = Layout(splitRatio: 0.5)
        let work = CGRect(x: 0, y: 0, width: 200, height: 100)
        layout.reconcile(visible: [1], anchor: nil, work: work, gap: 0)
        layout.reconcile(visible: [1, 2], anchor: 1, work: work, gap: 0)
        let frames = layout.frames(in: work, gap: 0)
        XCTAssertEqual(frames[1]!.width, 100, accuracy: 0.01)
        XCTAssertEqual(frames[2]!.minX, 100, accuracy: 0.01)
        XCTAssertEqual(frames[2]!.width, 100, accuracy: 0.01)
    }

    func testTallPaneStacks() {
        var layout = Layout(splitRatio: 0.5)
        let work = CGRect(x: 0, y: 0, width: 80, height: 200)
        layout.reconcile(visible: [1, 2], anchor: nil, work: work, gap: 0)
        let frames = layout.frames(in: work, gap: 0)
        XCTAssertEqual(frames[1]!.height, 100, accuracy: 0.01)
        XCTAssertEqual(frames[1]!.width, 80, accuracy: 0.01)
        XCTAssertEqual(frames[2]!.minY, 100, accuracy: 0.01)
    }

    func testInnerGap() {
        var layout = Layout(splitRatio: 0.5)
        let work = CGRect(x: 0, y: 0, width: 100, height: 100)
        layout.reconcile(visible: [1, 2], anchor: nil, work: work, gap: 10)
        let frames = layout.frames(in: work, gap: 10)
        XCTAssertEqual(frames[1]!.width, 45, accuracy: 0.01)
        XCTAssertEqual(frames[2]!.minX, 55, accuracy: 0.01)
        XCTAssertEqual(frames[2]!.width, 45, accuracy: 0.01)
    }

    func testRemoveCollapses() {
        var layout = Layout(splitRatio: 0.5)
        let work = CGRect(x: 0, y: 0, width: 160, height: 90)
        layout.reconcile(visible: [1, 2, 3], anchor: nil, work: work, gap: 0)
        layout.reconcile(visible: [1, 3], anchor: nil, work: work, gap: 0)
        let frames = layout.frames(in: work, gap: 0)
        XCTAssertNil(frames[2])
        XCTAssertEqual(frames[1]!.width, 80, accuracy: 0.01)
        XCTAssertEqual(frames[3]!.minX, 80, accuracy: 0.01)
        XCTAssertEqual(frames[3]!.width, 80, accuracy: 0.01)
        XCTAssertEqual(frames[3]!.height, 90, accuracy: 0.01)
    }

    func testResizePushesTheNearestEdge() {
        var layout = Layout(splitRatio: 0.5)
        let work = CGRect(x: 0, y: 0, width: 100, height: 100)
        layout.reconcile(visible: [1, 2], anchor: nil, work: work, gap: 0)
        layout.resize(1, toward: .right)
        var frames = layout.frames(in: work, gap: 0)
        XCTAssertEqual(frames[1]!.width, 55, accuracy: 0.01)
        layout.resize(2, toward: .left)
        frames = layout.frames(in: work, gap: 0)
        XCTAssertEqual(frames[2]!.width, 50, accuracy: 0.01)
        layout.resize(2, toward: .right)
        frames = layout.frames(in: work, gap: 0)
        XCTAssertEqual(frames[2]!.width, 50, accuracy: 0.01)
    }

    func testEaseOutIsFrontLoaded() {
        let from = CGRect(x: 0, y: 0, width: 100, height: 80)
        let to = CGRect(x: 100, y: 40, width: 40, height: 120)
        let start = eased(from, to, 0)
        XCTAssertEqual(start.minX, 0, accuracy: 0.01)
        XCTAssertEqual(start.width, 100, accuracy: 0.01)
        let mid = eased(from, to, 0.5)
        XCTAssertEqual(mid.minX, 87.5, accuracy: 0.01)
        XCTAssertEqual(mid.minY, 35, accuracy: 0.01)
        XCTAssertEqual(mid.width, 47.5, accuracy: 0.01)
        let end = eased(from, to, 1)
        XCTAssertEqual(end, to)
        XCTAssertEqual(eased(from, to, 2), to)
    }

    func testNeighborAndSwap() {
        var layout = Layout(splitRatio: 0.5)
        let work = CGRect(x: 0, y: 0, width: 200, height: 100)
        layout.reconcile(visible: [1, 2], anchor: nil, work: work, gap: 0)
        let frames = layout.frames(in: work, gap: 0)
        XCTAssertEqual(Layout.neighbor(of: 1, toward: .right, in: frames), 2)
        XCTAssertNil(Layout.neighbor(of: 2, toward: .right, in: frames))
        layout.swap(1, 2)
        XCTAssertEqual(layout.leaves(), [2, 1])
    }

    func testListedWindowsReadsCoreGraphicsNumbers() {
        let rows: [[String: Any]] = [
            [
                kCGWindowNumber as String: NSNumber(value: 42),
                kCGWindowOwnerPID as String: NSNumber(value: 7),
                kCGWindowLayer as String: NSNumber(value: 0),
                kCGWindowIsOnscreen as String: NSNumber(value: true),
                kCGWindowBounds as String: [
                    "X": NSNumber(value: 10),
                    "Y": NSNumber(value: 20),
                    "Width": NSNumber(value: 30),
                    "Height": NSNumber(value: 40),
                ],
            ],
            [
                kCGWindowNumber as String: 9,
                kCGWindowOwnerPID as String: 3,
                kCGWindowLayer as String: 3,
                kCGWindowIsOnscreen as String: false,
                kCGWindowBounds as String: ["X": 0, "Y": 0, "Width": 1, "Height": 1],
            ],
        ]
        let windows = listedWindows(rows)
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0], ListedWindow(id: 42, pid: 7, bounds: CGRect(x: 10, y: 20, width: 30, height: 40), layer: 0, onScreen: true))
        XCTAssertEqual(windows[1].layer, 3)
        XCTAssertFalse(windows[1].onScreen)
    }

    func testConfigReplacesListsAndKeepsDefaults() {
        let (parsed, warnings) = Config.parse(Config.defaultText)
        XCTAssertEqual(warnings, [])
        XCTAssertEqual(parsed.main, Mods.globe)
        XCTAssertEqual(parsed.gapsInner, 8)
        XCTAssertEqual(parsed.binds.count, 15)
        XCTAssertTrue(parsed.binds.contains { $0.action == .close && $0.keyCode == KeyCode.code(for: "w") })

        let (custom, customWarnings) = Config.parse("""
        modifier = option
        gaps_outer = 12
        float = com.example.keep
        bind = left, focus left
        bind = nope, dance
        """)
        XCTAssertEqual(customWarnings.count, 1)
        XCTAssertEqual(custom.main, Mods(option: true))
        XCTAssertEqual(custom.gapsOuter, 12)
        XCTAssertEqual(custom.gapsInner, 8)
        XCTAssertEqual(custom.floats, ["com.example.keep"])
        XCTAssertEqual(custom.binds.count, 1)
        XCTAssertEqual(custom.binds[0].keyCode, KeyCode.left)
        XCTAssertEqual(custom.binds[0].action, .focus(.left))
    }
}
