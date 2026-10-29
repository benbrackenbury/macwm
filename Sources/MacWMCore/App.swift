import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import QuartzCore

// Tiles the windows already on each display's current macOS Space.
// SkyLight is queried in-process. SIP stays on, and Spaces stay Apple's.
// The window server ignores a frame write on another app's window, so frames
// stay on Accessibility. SLSDisableUpdate deadlocks that call.
// A real move eases with the display. A resize key, and Reduce Motion, snap.

private let debug = ProcessInfo.processInfo.environment["MACWM_DEBUG"] == "1"
private let slideSeconds: CFTimeInterval = 0.18
private let slideDistance: CGFloat = 28

private func log(_ message: String) {
    if debug { NSLog("macwm: %@", message) }
}

enum Sky {
    static let handle: UnsafeMutableRawPointer = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else {
            fatalError("macwm: cannot open SkyLight")
        }
        return handle
    }()

    static let connection: Int32 = {
        let fn: @convention(c) () -> Int32 = load("SLSMainConnectionID")
        return fn()
    }()

    private static let spacesForWindows: @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>? =
        load("SLSCopySpacesForWindows")
    private static let displayForWindow: @convention(c) (Int32, UInt32) -> Unmanaged<CFString>? =
        load("SLSCopyManagedDisplayForWindow")
    private static let currentSpaceFn: @convention(c) (Int32, CFString) -> UInt64 =
        load("SLSManagedDisplayGetCurrentSpace")
    private static let spaceTypeFn: @convention(c) (Int32, UInt64) -> Int32 =
        load("SLSSpaceGetType")
    private static let managedSpaces: @convention(c) (Int32) -> Unmanaged<CFArray>? =
        load("SLSCopyManagedDisplaySpaces")
    private static let animatingFn: @convention(c) (Int32, CFString) -> Bool =
        load("SLSManagedDisplayIsAnimating")
    private static let displayUUIDFn: @convention(c) (UInt32) -> Unmanaged<CFUUID>? = {
        let graphics = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY)
        guard let sym = dlsym(graphics, "CGDisplayCreateUUIDFromDisplayID") ?? dlsym(handle, "CGDisplayCreateUUIDFromDisplayID") else {
            fatalError("macwm: missing CGDisplayCreateUUIDFromDisplayID")
        }
        return unsafeBitCast(sym, to: (@convention(c) (UInt32) -> Unmanaged<CFUUID>?).self)
    }()

    static func spaces(for window: UInt32) -> [UInt64] {
        let list = [NSNumber(value: window)] as CFArray
        guard let raw = spacesForWindows(connection, 0x7, list)?.takeRetainedValue() else { return [] }
        return (raw as? [NSNumber] ?? []).map(\.uint64Value)
    }

    static func display(for window: UInt32) -> String? {
        displayForWindow(connection, window)?.takeRetainedValue() as String?
    }

    static func currentSpace(_ display: String) -> UInt64 {
        currentSpaceFn(connection, display as CFString)
    }

    static func spaceType(_ space: UInt64) -> Int32 {
        spaceTypeFn(connection, space)
    }

    static func isAnimating(_ display: String) -> Bool {
        animatingFn(connection, display as CFString)
    }

    static func displayUUID(_ screen: NSScreen) -> String? {
        guard let number = displayNumber(screen),
              let uuid = displayUUIDFn(number)?.takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    static func allSpaceIDs() -> Set<UInt64> {
        guard let raw = managedSpaces(connection)?.takeRetainedValue() as? [NSDictionary] else { return [] }
        var ids = Set<UInt64>()
        for display in raw {
            for space in display["Spaces"] as? [NSDictionary] ?? [] {
                if let id = space["id64"] as? NSNumber { ids.insert(id.uint64Value) }
            }
        }
        return ids
    }

    private static func load<T>(_ name: String) -> T {
        guard let sym = dlsym(handle, name) else { fatalError("macwm: SkyLight is missing \(name)") }
        return unsafeBitCast(sym, to: T.self)
    }
}

private func displayNumber(_ screen: NSScreen) -> UInt32? {
    let raw = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
    if let number = raw as? UInt32 { return number }
    return (raw as? NSNumber)?.uint32Value
}

private let axWindowID: @convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> Int32 = {
    let services = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY)
    guard let sym = dlsym(services, "_AXUIElementGetWindow") else {
        fatalError("macwm: missing _AXUIElementGetWindow")
    }
    return unsafeBitCast(sym, to: (@convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> Int32).self)
}()

private let blockedSubroles: Set<String> = [
    "AXDialog", "AXSystemDialog", "AXFloatingWindow", "AXUnknown",
    "AXSheet", "AXDrawer", "AXToolbar", "AXPopover", "AXMenuBar",
]

private func copyAttr(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

private func stringAttr(_ element: AXUIElement, _ name: String) -> String? {
    copyAttr(element, name) as? String
}

private func cgFloat(_ value: Any?) -> CGFloat? {
    switch value {
    case let number as CGFloat:
        return number
    case let number as Int:
        return CGFloat(number)
    case let number as NSNumber:
        return CGFloat(number.doubleValue)
    default:
        return nil
    }
}

private func intNumber(_ value: Any?) -> Int? {
    switch value {
    case let number as Int:
        return number
    case let number as NSNumber:
        return number.intValue
    default:
        return nil
    }
}

private func wholeNumber(_ value: Any?) -> UInt32? {
    switch value {
    case let number as UInt32:
        return number
    case let number as Int:
        return UInt32(number)
    case let number as NSNumber:
        return number.uint32Value
    default:
        return nil
    }
}

private func cgRect(_ value: Any?) -> CGRect? {
    let raw: [String: Any]
    if let typed = value as? [String: Any] {
        raw = typed
    } else if let typed = value as? NSDictionary {
        raw = typed as? [String: Any] ?? [:]
    } else {
        return nil
    }
    guard let x = cgFloat(raw["X"]),
          let y = cgFloat(raw["Y"]),
          let width = cgFloat(raw["Width"]),
          let height = cgFloat(raw["Height"])
    else { return nil }
    return CGRect(x: x, y: y, width: width, height: height)
}

private func windowID(_ element: AXUIElement) -> UInt32? {
    var id: UInt32 = 0
    return axWindowID(element, &id) == 0 ? id : nil
}

/// Ease-out cubic. Most of the travel happens up front, then it settles.
func eased(_ from: CGRect, _ to: CGRect, _ t: CGFloat) -> CGRect {
    let u = 1 - min(max(t, 0), 1)
    let e = 1 - u * u * u
    return CGRect(
        x: from.minX + (to.minX - from.minX) * e,
        y: from.minY + (to.minY - from.minY) * e,
        width: from.width + (to.width - from.width) * e,
        height: from.height + (to.height - from.height) * e
    )
}

private func point(_ rect: CGRect) -> (CGPoint, CGSize) {
    (
        CGPoint(x: rect.minX.rounded(), y: rect.minY.rounded()),
        CGSize(width: rect.width.rounded(), height: rect.height.rounded())
    )
}

/// Size, then position, then size again when `settle` is set.
/// The window server clamps a size that would hang off the screen, and accepts it once the origin is in range.
private func setFrame(_ element: AXUIElement, _ rect: CGRect, from current: CGRect, settle: Bool) {
    var origin = point(rect).0
    var extent = point(rect).1
    let (haveOrigin, haveSize) = point(current)
    let sizeChanged = extent != haveSize
    let originChanged = origin != haveOrigin
    guard sizeChanged || originChanged else { return }
    if sizeChanged, let size = AXValueCreate(.cgSize, &extent) {
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, size)
    }
    if originChanged, let pos = AXValueCreate(.cgPoint, &origin) {
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, pos)
    }
    if settle, sizeChanged, let size = AXValueCreate(.cgSize, &extent) {
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, size)
    }
}

private func near(_ a: CGRect, _ b: CGRect) -> Bool {
    abs(a.minX - b.minX) < 2 && abs(a.minY - b.minY) < 2
        && abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2
}

private func quartz(_ rect: CGRect) -> CGRect {
    guard let primary = NSScreen.screens.first else { return rect }
    return CGRect(x: rect.minX, y: primary.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
}

private func inset(_ rect: CGRect, by gap: CGFloat) -> CGRect {
    CGRect(x: rect.minX + gap, y: rect.minY + gap, width: rect.width - gap * 2, height: rect.height - gap * 2)
}

private struct TileKey: Hashable {
    var display: String
    var space: UInt64
}

struct ListedWindow: Equatable {
    var id: UInt32
    var pid: pid_t
    var bounds: CGRect
    var layer: Int
    var onScreen: Bool
}

/// One pass over `CGWindowListCopyWindowInfo`. Layer 0 is a normal window.
func listedWindows(_ rows: [[String: Any]]) -> [ListedWindow] {
    rows.compactMap { row in
        guard let id = wholeNumber(row[kCGWindowNumber as String]), id != 0,
              let pid = intNumber(row[kCGWindowOwnerPID as String]), pid > 0,
              let bounds = cgRect(row[kCGWindowBounds as String])
        else { return nil }
        let onScreen = (row[kCGWindowIsOnscreen as String] as? Bool)
            ?? (row[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue
            ?? false
        return ListedWindow(
            id: id,
            pid: pid_t(pid),
            bounds: bounds,
            layer: intNumber(row[kCGWindowLayer as String]) ?? -1,
            onScreen: onScreen
        )
    }
}

private struct LiveWindow {
    var id: UInt32
    var pid: pid_t
    var element: AXUIElement
    var display: String
    var space: UInt64
    var bounds: CGRect
}

private struct Slide {
    var element: AXUIElement
    var from: CGRect
    var to: CGRect
    var began: CFTimeInterval
    var sent: CGRect
}

fileprivate final class Hotkeys {
    private let lock = NSLock()
    private var main = Mods.globe
    private var binds = Config.fallbackBinds

    func replace(main: Mods, binds: [Bind]) {
        lock.lock()
        self.main = main
        self.binds = binds
        lock.unlock()
    }

    func match(flags: CGEventFlags, code: UInt16) -> Action? {
        lock.lock()
        let currentMain = main
        let currentBinds = binds
        lock.unlock()
        let got = Mods(
            globe: flags.contains(.maskSecondaryFn),
            shift: flags.contains(.maskShift),
            control: flags.contains(.maskControl),
            option: flags.contains(.maskAlternate),
            command: flags.contains(.maskCommand)
        )
        return currentBinds.first { $0.keyCode == code && got == currentMain.union($0.extra) }?.action
    }
}

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static var shared: App!
    fileprivate let hotkeys = Hotkeys()

    private var status: NSStatusItem!
    private var config = Config()
    fileprivate var enabled = true
    private var started = false
    private var tap: CFMachPort?
    private var observers: [pid_t: AXObserver] = [:]
    private var tokens: [NSObjectProtocol] = []
    private var mouseMonitor: Any?
    private var watch: DispatchSourceFileSystemObject?
    private var refreshItem: DispatchWorkItem?
    private var refreshSoon = false
    private var configItem: DispatchWorkItem?
    private var slideLink: CADisplayLink?
    private var slides: [UInt32: Slide] = [:]
    private var direct = false
    private var layouts: [TileKey: Layout] = [:]
    private var workRects: [TileKey: CGRect] = [:]
    private var focusHistory: [TileKey: UInt32] = [:]
    private var windowKey: [UInt32: TileKey] = [:]
    private var elements: [UInt32: AXUIElement] = [:]
    private var pids: [UInt32: pid_t] = [:]
    private var bundles: [UInt32: String] = [:]
    private var overrides: [UInt32: Bool] = [:]
    private var misses: [UInt32: (target: CGRect, count: Int)] = [:]
    private var axApps: [pid_t: AXUIElement] = [:]
    private var quietUntil: [pid_t: TimeInterval] = [:]
    private var rejected: Set<UInt32> = []
    private var firstSeen: [UInt32: TimeInterval] = [:]
    private var spot: [UInt32: TileKey] = [:]
    private var skipped: Set<UInt32> = []
    private var spaceTypes: [UInt64: Int32] = [:]
    private var spotsStale = true
    private var animSkips = 0
    private var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/macwm/config")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        status.menu = menu
        loadConfig()
        updateIcon()
        promptTrust()
        if AXIsProcessTrusted() {
            start()
        } else {
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
                guard AXIsProcessTrusted() else { return }
                timer.invalidate()
                self?.start()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        slideLink?.invalidate()
        slideLink = nil
        slides.removeAll()
    }

    func keepTapAlive() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    private func start() {
        guard !started else { return }
        started = true
        installTap()
        watchApps()
        watchConfig()
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp]) { _ in
            App.shared.scheduleRefresh(fresh: true, soon: true)
        }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.scheduleRefresh(fresh: true)
        }
        updateIcon()
        scheduleRefresh()
    }

    private func promptTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    private func installTap() {
        let mask = CGEventMask((1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue))
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: tapCallback,
            userInfo: nil
        ) else {
            NSLog("macwm: could not install the key hook. Accessibility permission is required.")
            updateIcon()
            return
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func watchApps() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
        ]
        for name in names {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                if name == NSWorkspace.didTerminateApplicationNotification,
                   let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                    self?.unwatch(app.processIdentifier)
                }
                if name == NSWorkspace.didLaunchApplicationNotification,
                   let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                    self?.watch(app)
                }
                self?.scheduleRefresh(fresh: name == NSWorkspace.activeSpaceDidChangeNotification)
            })
        }
        tokens.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleRefresh(fresh: true)
        })
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy != .prohibited {
            watch(app)
        }
    }

    private func watch(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard observers[pid] == nil else { return }
        var observer: AXObserver?
        guard AXObserverCreate(pid, axNotify, &observer) == .success, let observer else { return }
        let element = AXUIElementCreateApplication(pid)
        for name in [
            kAXWindowCreatedNotification,
            kAXUIElementDestroyedNotification,
            kAXWindowMiniaturizedNotification,
            kAXWindowDeminiaturizedNotification,
            kAXFocusedWindowChangedNotification,
        ] {
            AXObserverAddNotification(observer, element, name as CFString, nil)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        observers[pid] = observer
    }

    private func unwatch(_ pid: pid_t) {
        axApps[pid] = nil
        quietUntil[pid] = nil
        guard let observer = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    /// `fresh` drops the cached display/space for each window. Drags, space changes, and the 1s timer need that. Focus changes do not.
    /// `soon` is a key or a mouse-up. Notifications stay debounced, and a soon pass is not pushed back by one.
    func scheduleRefresh(fresh: Bool = false, soon: Bool = false) {
        guard started, enabled, AXIsProcessTrusted() else { return }
        if fresh { spotsStale = true }
        if soon { refreshSoon = true }
        refreshItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.refreshSoon = false
            self?.refresh()
        }
        refreshItem = item
        let delay: TimeInterval = refreshSoon ? 0 : 0.02
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func noteFocus() {
        guard enabled, let id = focusedWindow(), let key = windowKey[id] else { return }
        focusHistory[key] = id
    }

    private func refresh() {
        guard enabled, AXIsProcessTrusted() else { return }
        if NSEvent.pressedMouseButtons != 0 {
            dropSlides()
            return
        }
        if displayAnimating(), animSkips < 10 {
            slideLink?.isPaused = true
            animSkips += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.refresh() }
            return
        }
        animSkips = 0
        let jump = direct
        direct = false
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if spotsStale {
            spot.removeAll(keepingCapacity: true)
            skipped.removeAll(keepingCapacity: true)
            spaceTypes.removeAll(keepingCapacity: true)
            spotsStale = false
        }

        let started = Date()
        let focused = focusedWindow()
        let windows = scan()
        let known = Sky.allSpaceIDs()
        if !known.isEmpty {
            layouts = layouts.filter { known.contains($0.key.space) }
        }

        var nextKeys: [UInt32: TileKey] = [:]
        var snaps: [(AXUIElement, CGRect, CGRect)] = []
        var easing: [(UInt32, AXUIElement, CGRect, CGRect)] = []
        keepSlides(Set(windows.map(\.id)))
        let grouped = Dictionary(grouping: windows, by: { TileKey(display: $0.display, space: $0.space) })
        for (key, group) in grouped {
            guard let screen = NSScreen.screens.first(where: { Sky.displayUUID($0) == key.display }) else { continue }
            let work = inset(quartz(screen.visibleFrame), by: config.gapsOuter)
            guard work.width > 40, work.height > 40 else { continue }
            var layout = layouts[key] ?? Layout(splitRatio: config.splitRatio)
            layout.splitRatio = config.splitRatio
            layout.reconcile(
                visible: group.map(\.id),
                anchor: focusHistory[key],
                work: work,
                gap: config.gapsInner
            )
            layouts[key] = layout
            workRects[key] = work
            if let focused, layout.contains(focused) { focusHistory[key] = focused }
            let targets = layout.frames(in: work, gap: config.gapsInner)
            for window in group {
                nextKeys[window.id] = key
                guard let target = targets[window.id] else { continue }
                if near(window.bounds, target) {
                    misses[window.id] = nil
                    dropSlide(window.id)
                    continue
                }
                if !jump && flying(window.id, to: target) { continue }
                let previous = misses[window.id]
                let count = previous?.target == target ? previous?.count ?? 0 : 0
                // ponytail: stop after 3 rejects so a window that will not move cannot flash forever.
                if count >= 3 {
                    dropSlide(window.id)
                    continue
                }
                misses[window.id] = (target, count + 1)
                let ease = !jump && !reduce && count == 0 && travel(window.bounds, target) > slideDistance
                if ease {
                    easing.append((window.id, window.element, window.bounds, target))
                } else {
                    dropSlide(window.id)
                    snaps.append((window.element, target, window.bounds))
                }
            }
        }
        windowKey = nextKeys
        if !steer(easing) {
            for (id, element, bounds, target) in easing {
                dropSlide(id)
                snaps.append((element, target, bounds))
            }
        }
        log(String(format: "refresh %.0fms windows %d ease %d snap %d", Date().timeIntervalSince(started) * 1000, windows.count, slides.count, snaps.count))
        for (element, rect, bounds) in snaps { setFrame(element, rect, from: bounds, settle: true) }
        if !slides.isEmpty { slideLink?.isPaused = false }
    }

    private func travel(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(abs(a.minX - b.minX), abs(a.minY - b.minY), abs(a.width - b.width), abs(a.height - b.height))
    }

    private func flying(_ id: UInt32, to target: CGRect) -> Bool {
        guard let slide = slides[id] else { return false }
        return near(slide.to, target)
    }

    private func ensureSlideLink() -> CADisplayLink? {
        if let slideLink { return slideLink }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return nil }
        let link = screen.displayLink(target: self, selector: #selector(stepSlide(_:)))
        link.add(to: .main, forMode: .common)
        link.isPaused = true
        slideLink = link
        return link
    }

    /// Returns false when the display link cannot run, so the caller snaps instead.
    private func steer(_ items: [(UInt32, AXUIElement, CGRect, CGRect)]) -> Bool {
        if items.isEmpty { return true }
        guard let link = ensureSlideLink() else { return false }
        let now = CACurrentMediaTime()
        for (id, element, bounds, target) in items {
            if var slide = slides[id], near(slide.to, target) {
                slide.element = element
                slides[id] = slide
                continue
            }
            let from = slides[id].map { eased($0.from, $0.to, slideProgress($0, now)) } ?? bounds
            let sent = slides[id]?.sent ?? bounds
            slides[id] = Slide(element: element, from: from, to: target, began: now, sent: sent)
        }
        link.isPaused = false
        return true
    }

    private func slideProgress(_ slide: Slide, _ now: CFTimeInterval) -> CGFloat {
        CGFloat(min(1, max(0, (now - slide.began) / slideSeconds)))
    }

    private func dropSlide(_ id: UInt32) {
        slides.removeValue(forKey: id)
        if slides.isEmpty { slideLink?.isPaused = true }
    }

    private func dropSlides() {
        slides.removeAll()
        slideLink?.isPaused = true
    }

    private func keepSlides(_ ids: Set<UInt32>) {
        guard !slides.isEmpty else { return }
        slides = slides.filter { ids.contains($0.key) }
        if slides.isEmpty { slideLink?.isPaused = true }
    }

    @objc private func stepSlide(_ link: CADisplayLink) {
        if NSEvent.pressedMouseButtons != 0 || displayAnimating() {
            link.isPaused = true
            return
        }
        let now = CACurrentMediaTime()
        var finished: [UInt32] = []
        for id in Array(slides.keys) {
            guard var slide = slides[id] else { continue }
            let t = slideProgress(slide, now)
            if t >= 1 {
                setFrame(slide.element, slide.to, from: slide.from, settle: true)
                finished.append(id)
            } else {
                let frame = eased(slide.from, slide.to, t)
                setFrame(slide.element, frame, from: slide.sent, settle: false)
                slide.sent = frame
                slides[id] = slide
            }
        }
        for id in finished { slides.removeValue(forKey: id) }
        guard slides.isEmpty else { return }
        link.isPaused = true
        if !finished.isEmpty { scheduleRefresh() }
    }

    private func displayAnimating() -> Bool {
        NSScreen.screens.contains { screen in
            guard let uuid = Sky.displayUUID(screen) else { return false }
            return Sky.isAnimating(uuid)
        }
    }

    // ponytail: AX is only for windows CGWindowList has not seen before. A wedged app gets 0.1s, then 2s of quiet.
    private func scan() -> [LiveWindow] {
        let rows = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let records = listedWindows(rows)
        let alive = Set(records.map(\.id))
        elements = elements.filter { alive.contains($0.key) }
        pids = pids.filter { alive.contains($0.key) }
        bundles = bundles.filter { alive.contains($0.key) }
        overrides = overrides.filter { alive.contains($0.key) }
        misses = misses.filter { alive.contains($0.key) }
        rejected = rejected.intersection(alive)
        firstSeen = firstSeen.filter { alive.contains($0.key) }
        spot = spot.filter { alive.contains($0.key) }
        skipped = skipped.intersection(alive)

        var wanted: [pid_t: Set<UInt32>] = [:]
        for window in records where window.onScreen && window.layer == 0 && elements[window.id] == nil && !rejected.contains(window.id) {
            wanted[window.pid, default: []].insert(window.id)
        }
        var retry = false
        for (pid, ids) in wanted where resolve(pid, wanted: ids) {
            retry = true
        }
        if retry {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.scheduleRefresh()
            }
        }

        var managed: [LiveWindow] = []
        var currentByDisplay: [String: UInt64] = [:]
        for window in records where window.onScreen && window.layer == 0 {
            guard let element = elements[window.id] else { continue }
            let bundle = bundles[window.id]
            if floating(window.id, bundle: bundle) { continue }
            guard let place = place(window.id) else { continue }
            let current = currentByDisplay[place.display] ?? Sky.currentSpace(place.display)
            currentByDisplay[place.display] = current
            guard place.space == current else { continue }
            managed.append(LiveWindow(
                id: window.id,
                pid: window.pid,
                element: element,
                display: place.display,
                space: place.space,
                bounds: window.bounds
            ))
        }
        return managed
    }

    private func resolve(_ pid: pid_t, wanted: Set<UInt32>) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if let until = quietUntil[pid], until > now { return false }
        let ax = applicationElement(pid)
        guard let raw = copyAttr(ax, kAXWindowsAttribute) else {
            quietUntil[pid] = now + 2
            return false
        }
        var found = Set<UInt32>()
        var retry = false
        for element in axElements(raw) {
            guard let id = windowID(element), wanted.contains(id) else { continue }
            found.insert(id)
            firstSeen[id] = nil
            if let sub = stringAttr(element, kAXSubroleAttribute), blockedSubroles.contains(sub) {
                rejected.insert(id)
                continue
            }
            elements[id] = element
            AXUIElementSetMessagingTimeout(element, 0.08)
            pids[id] = pid
            if bundles[id] == nil, let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier {
                bundles[id] = bundle
            }
        }
        // ponytail: a CG window that AX never lists is ignored after 1s. Brand new windows keep retrying until then.
        for id in wanted where !found.contains(id) {
            let seen = firstSeen[id] ?? now
            firstSeen[id] = seen
            if now - seen > 1 {
                rejected.insert(id)
            } else {
                retry = true
            }
        }
        return retry
    }

    private func applicationElement(_ pid: pid_t) -> AXUIElement {
        if let existing = axApps[pid] { return existing }
        let ax = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(ax, 0.1)
        axApps[pid] = ax
        return ax
    }

    /// Cached until a drag, a space change, or the 1s timer. SkyLight on every focus was the hitch.
    private func place(_ id: UInt32) -> TileKey? {
        if skipped.contains(id) { return nil }
        if let hit = spot[id] { return hit }
        guard let display = Sky.display(for: id) else { return nil }
        let spaces = Sky.spaces(for: id)
        guard spaces.count == 1, let space = spaces.first else {
            skipped.insert(id)
            return nil
        }
        let type = spaceTypes[space] ?? Sky.spaceType(space)
        spaceTypes[space] = type
        guard type == 0 else {
            skipped.insert(id)
            return nil
        }
        let key = TileKey(display: display, space: space)
        spot[id] = key
        return key
    }

    private func floating(_ id: UInt32, bundle: String?) -> Bool {
        if let override = overrides[id] { return override }
        if let bundle, config.floats.contains(bundle) { return true }
        return false
    }

    private func focusedWindow() -> UInt32? {
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        let app = applicationElement(front.processIdentifier)
        guard let raw = copyAttr(app, kAXFocusedWindowAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return windowID(unsafeBitCast(raw, to: AXUIElement.self))
    }

    func perform(_ action: Action) {
        switch action {
        case .focus(let dir):
            nudge(dir, swap: false)
        case .move(let dir):
            nudge(dir, swap: true)
        case .resize(let dir):
            resize(dir)
        case .toggleFloat:
            toggleFloat()
        case .close:
            closeFocused()
        case .reload:
            loadConfig()
            scheduleRefresh(soon: true)
        }
    }

    private func nudge(_ dir: Direction, swap: Bool) {
        guard let id = focusedWindow(), let key = windowKey[id], var layout = layouts[key] else { return }
        let placed = layout.frames(in: workRects[key] ?? .zero, gap: config.gapsInner)
        guard let next = Layout.neighbor(of: id, toward: dir, in: placed) else { return }
        if swap {
            layout.swap(id, next)
            layouts[key] = layout
            focusHistory[key] = id
            scheduleRefresh(soon: true)
        } else {
            focus(next)
        }
    }

    private func resize(_ dir: Direction) {
        guard let id = focusedWindow(), let key = windowKey[id], var layout = layouts[key] else { return }
        direct = true
        layout.resize(id, toward: dir)
        layouts[key] = layout
        scheduleRefresh(soon: true)
    }

    private func focus(_ id: UInt32) {
        guard let element = elements[id], let pid = pids[id] else { return }
        let app = applicationElement(pid)
        AXUIElementSetAttributeValue(app, kAXFocusedWindowAttribute as CFString, element)
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
            NSRunningApplication(processIdentifier: pid)?.activate()
        }
        if let key = windowKey[id] { focusHistory[key] = id }
    }

    private func toggleFloat() {
        guard let id = focusedWindow(), elements[id] != nil else { return }
        overrides[id] = !floating(id, bundle: bundles[id])
        scheduleRefresh(soon: true)
    }

    private func closeFocused() {
        guard let id = focusedWindow(), let element = elements[id] ?? focusedElement() else { return }
        guard let button = copyAttr(element, kAXCloseButtonAttribute),
              CFGetTypeID(button) == AXUIElementGetTypeID()
        else { return }
        AXUIElementPerformAction(unsafeBitCast(button, to: AXUIElement.self), kAXPressAction as CFString)
        scheduleRefresh(soon: true)
    }

    private func focusedElement() -> AXUIElement? {
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        let app = applicationElement(front.processIdentifier)
        guard let raw = copyAttr(app, kAXFocusedWindowAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(raw, to: AXUIElement.self)
    }

    private func loadConfig() {
        let url = configURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Config.defaultText.write(to: url, atomically: true, encoding: .utf8)
            NSLog("macwm: wrote %@", url.path)
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            NSLog("macwm: cannot read %@", url.path)
            return
        }
        let (parsed, warnings) = Config.parse(text)
        for warning in warnings { NSLog("macwm: %@", warning) }
        config = parsed
        hotkeys.replace(main: parsed.main, binds: parsed.binds)
        for key in Array(layouts.keys) {
            if var layout = layouts[key] {
                layout.splitRatio = parsed.splitRatio
                layouts[key] = layout
            }
        }
    }

    private func watchConfig() {
        watch?.cancel()
        let fd = open(configURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = source.data
            self.scheduleConfigReload()
            if flags.contains(.rename) || flags.contains(.delete) {
                source.cancel()
                self.watchConfig()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watch = source
    }

    private func scheduleConfigReload() {
        configItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.loadConfig()
            self?.scheduleRefresh()
        }
        configItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
    }

    private func updateIcon() {
        let symbol: String
        if started && (tap == nil || !AXIsProcessTrusted()) {
            symbol = "exclamationmark.triangle"
        } else if enabled {
            symbol = "rectangle.split.2x1"
        } else {
            symbol = "rectangle"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "macwm")
        image?.isTemplate = true
        status.button?.image = image
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        let title = NSMenuItem(title: "macwm", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        if AXIsProcessTrusted() {
            let tiling = NSMenuItem(title: "Tiling", action: #selector(toggleEnabled), keyEquivalent: "")
            tiling.state = enabled ? .on : .off
            tiling.target = self
            menu.addItem(tiling)
        } else {
            let grant = NSMenuItem(title: "Grant Accessibility...", action: #selector(grantAccess), keyEquivalent: "")
            grant.target = self
            menu.addItem(grant)
        }
        menu.addItem(.separator())
        let open = NSMenuItem(title: "Open Config", action: #selector(openConfig), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let reload = NSMenuItem(title: "Reload Config", action: #selector(reloadFromMenu), keyEquivalent: "")
        reload.target = self
        menu.addItem(reload)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func toggleEnabled() {
        enabled.toggle()
        updateIcon()
        if enabled { scheduleRefresh(fresh: true, soon: true) }
    }

    @objc private func grantAccess() {
        promptTrust()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openConfig() {
        loadConfig()
        NSWorkspace.shared.open(configURL)
    }

    @objc private func reloadFromMenu() {
        loadConfig()
        scheduleRefresh()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

private func axElements(_ value: CFTypeRef) -> [AXUIElement] {
    guard CFGetTypeID(value) == CFArrayGetTypeID() else { return [] }
    let array = unsafeBitCast(value, to: CFArray.self)
    return (0..<CFArrayGetCount(array)).map { index in
        unsafeBitCast(CFArrayGetValueAtIndex(array, index), to: AXUIElement.self)
    }
}

private func axNotify(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    let name = notification as String
    DispatchQueue.main.async {
        guard let app = App.shared else { return }
        if name == kAXFocusedWindowChangedNotification as String {
            app.noteFocus()
        } else {
            app.scheduleRefresh()
        }
    }
}

private func tapCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent, _ userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        App.shared?.keepTapAlive()
        return Unmanaged.passUnretained(event)
    }
    guard type == .keyDown || type == .keyUp else { return Unmanaged.passUnretained(event) }
    let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
    guard let app = App.shared, let action = app.hotkeys.match(flags: event.flags, code: code) else {
        return Unmanaged.passUnretained(event)
    }
    if !app.enabled, action != .reload {
        return Unmanaged.passUnretained(event)
    }
    if type == .keyDown, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 || action.repeats {
        DispatchQueue.main.async { App.shared?.perform(action) }
    }
    return nil
}

public enum MacWM {
    public static func launch() {
        let app = NSApplication.shared
        App.shared = App()
        app.delegate = App.shared
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
