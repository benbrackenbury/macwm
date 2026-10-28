import AppKit
import ApplicationServices
import CoreGraphics
import Darwin

// Tiles the windows already on each display's current macOS Space.
// SkyLight is called in-process. SIP stays on, and Spaces stay Apple's.
// Frames go through Accessibility. Batching them with SLSDisableUpdate deadlocks that call.

private let debug = ProcessInfo.processInfo.environment["MACWM_DEBUG"] == "1"

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

private func boolAttr(_ element: AXUIElement, _ name: String) -> Bool {
    if let value = copyAttr(element, name) as? Bool { return value }
    return (copyAttr(element, name) as? NSNumber)?.boolValue ?? false
}

private func windowID(_ element: AXUIElement) -> UInt32? {
    var id: UInt32 = 0
    return axWindowID(element, &id) == 0 ? id : nil
}

private func axFrame(_ element: AXUIElement) -> CGRect? {
    guard let pos = copyAttr(element, kAXPositionAttribute),
          let size = copyAttr(element, kAXSizeAttribute)
    else { return nil }
    var origin = CGPoint.zero
    var extent = CGSize.zero
    guard AXValueGetValue(pos as! AXValue, .cgPoint, &origin),
          AXValueGetValue(size as! AXValue, .cgSize, &extent)
    else { return nil }
    return CGRect(origin: origin, size: extent)
}

private func setFrame(_ element: AXUIElement, _ rect: CGRect) {
    var origin = rect.origin
    var extent = rect.size
    guard let pos = AXValueCreate(.cgPoint, &origin), let size = AXValueCreate(.cgSize, &extent) else { return }
    AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, size)
    AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, pos)
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

private struct LiveWindow {
    var id: UInt32
    var element: AXUIElement
    var display: String
    var space: UInt64
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
    private var configItem: DispatchWorkItem?
    private var layouts: [TileKey: Layout] = [:]
    private var workRects: [TileKey: CGRect] = [:]
    private var focusHistory: [TileKey: UInt32] = [:]
    private var windowKey: [UInt32: TileKey] = [:]
    private var elements: [UInt32: AXUIElement] = [:]
    private var pids: [UInt32: pid_t] = [:]
    private var bundles: [UInt32: String] = [:]
    private var overrides: [UInt32: Bool] = [:]
    private var misses: [UInt32: (target: CGRect, count: Int)] = [:]
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
            App.shared.scheduleRefresh()
        }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.scheduleRefresh()
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
                self?.scheduleRefresh()
            })
        }
        tokens.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleRefresh()
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
        guard let observer = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    func scheduleRefresh() {
        guard started, enabled, AXIsProcessTrusted() else { return }
        refreshItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.refresh() }
        refreshItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: item)
    }

    private func refresh() {
        guard enabled, AXIsProcessTrusted() else { return }
        if NSEvent.pressedMouseButtons != 0 { return }
        if displayAnimating(), animSkips < 10 {
            animSkips += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.refresh() }
            return
        }
        animSkips = 0

        let focused = focusedWindow()
        let windows = scan()
        let known = Sky.allSpaceIDs()
        if !known.isEmpty {
            layouts = layouts.filter { known.contains($0.key.space) }
        }

        var nextKeys: [UInt32: TileKey] = [:]
        var moves: [(AXUIElement, CGRect)] = []
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
                if let current = axFrame(window.element), near(current, target) {
                    misses[window.id] = nil
                    continue
                }
                let previous = misses[window.id]
                let count = previous?.target == target ? previous?.count ?? 0 : 0
                // ponytail: stop after 3 rejects so a window that will not move cannot flash forever.
                if count >= 3 { continue }
                misses[window.id] = (target, count + 1)
                moves.append((window.element, target))
            }
        }
        windowKey = nextKeys
        guard !moves.isEmpty else { return }
        log("moving \(moves.count) windows")
        for (element, rect) in moves { setFrame(element, rect) }
    }

    private func displayAnimating() -> Bool {
        NSScreen.screens.contains { screen in
            guard let uuid = Sky.displayUUID(screen) else { return false }
            return Sky.isAnimating(uuid)
        }
    }

    private func scan() -> [LiveWindow] {
        let listed = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let onScreen = Set(listed.compactMap { row -> UInt32? in
            let layer = row[kCGWindowLayer as String]
            let layerNumber = (layer as? Int) ?? (layer as? NSNumber)?.intValue
            guard layerNumber == 0 else { return nil }
            if let id = row[kCGWindowNumber as String] as? UInt32 { return id }
            if let id = row[kCGWindowNumber as String] as? Int { return UInt32(id) }
            return (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        })

        var managed: [LiveWindow] = []
        var nextElements: [UInt32: AXUIElement] = [:]
        var nextPids: [UInt32: pid_t] = [:]
        var nextBundles: [UInt32: String] = [:]
        var alive = Set<UInt32>()
        var currentByDisplay: [String: UInt64] = [:]

        for app in NSWorkspace.shared.runningApplications where app.activationPolicy != .prohibited {
            let pid = app.processIdentifier
            let ax = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(ax, 0.25)
            guard let raw = copyAttr(ax, kAXWindowsAttribute) else { continue }
            for element in axElements(raw) {
                guard stringAttr(element, kAXRoleAttribute) == "AXWindow" else { continue }
                if let sub = stringAttr(element, kAXSubroleAttribute), blockedSubroles.contains(sub) { continue }
                guard let id = windowID(element), id != 0 else { continue }
                alive.insert(id)
                guard onScreen.contains(id), !boolAttr(element, kAXMinimizedAttribute), !boolAttr(element, "AXFullScreen") else { continue }
                nextElements[id] = element
                nextPids[id] = pid
                if let bundle = app.bundleIdentifier { nextBundles[id] = bundle }
                if floating(id, bundle: app.bundleIdentifier) { continue }
                guard let display = Sky.display(for: id) else { continue }
                let spaces = Sky.spaces(for: id)
                guard spaces.count == 1, let space = spaces.first, Sky.spaceType(space) == 0 else { continue }
                let current = currentByDisplay[display] ?? Sky.currentSpace(display)
                currentByDisplay[display] = current
                guard space == current else { continue }
                managed.append(LiveWindow(id: id, element: element, display: display, space: space))
            }
        }

        elements = nextElements
        pids = nextPids
        bundles = nextBundles
        overrides = overrides.filter { alive.contains($0.key) }
        misses = misses.filter { nextElements[$0.key] != nil }
        return managed
    }

    private func floating(_ id: UInt32, bundle: String?) -> Bool {
        if let override = overrides[id] { return override }
        if let bundle, config.floats.contains(bundle) { return true }
        return false
    }

    private func focusedWindow() -> UInt32? {
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        let app = AXUIElementCreateApplication(front.processIdentifier)
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
            scheduleRefresh()
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
            scheduleRefresh()
        } else {
            focus(next)
        }
    }

    private func resize(_ dir: Direction) {
        guard let id = focusedWindow(), let key = windowKey[id], var layout = layouts[key] else { return }
        layout.resize(id, toward: dir)
        layouts[key] = layout
        scheduleRefresh()
    }

    private func focus(_ id: UInt32) {
        guard let element = elements[id], let pid = pids[id] else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, kAXFocusedWindowAttribute as CFString, element)
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        NSRunningApplication(processIdentifier: pid)?.activate()
        if let key = windowKey[id] { focusHistory[key] = id }
    }

    private func toggleFloat() {
        guard let id = focusedWindow(), elements[id] != nil else { return }
        overrides[id] = !floating(id, bundle: bundles[id])
        scheduleRefresh()
    }

    private func closeFocused() {
        guard let id = focusedWindow(), let element = elements[id] ?? focusedElement() else { return }
        guard let button = copyAttr(element, kAXCloseButtonAttribute),
              CFGetTypeID(button) == AXUIElementGetTypeID()
        else { return }
        AXUIElementPerformAction(unsafeBitCast(button, to: AXUIElement.self), kAXPressAction as CFString)
        scheduleRefresh()
    }

    private func focusedElement() -> AXUIElement? {
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        let app = AXUIElementCreateApplication(front.processIdentifier)
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
        if enabled { scheduleRefresh() }
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
    DispatchQueue.main.async { App.shared?.scheduleRefresh() }
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
