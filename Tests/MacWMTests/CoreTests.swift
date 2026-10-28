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
