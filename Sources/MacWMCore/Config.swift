import CoreGraphics
import Foundation

struct Mods: Equatable {
    var globe = false
    var shift = false
    var control = false
    var option = false
    var command = false

    static let globe = Mods(globe: true)

    func union(_ other: Mods) -> Mods {
        Mods(
            globe: globe || other.globe,
            shift: shift || other.shift,
            control: control || other.control,
            option: option || other.option,
            command: command || other.command
        )
    }
}

enum Action: Equatable {
    case focus(Direction)
    case move(Direction)
    case resize(Direction)
    case toggleFloat
    case close
    case reload

    var repeats: Bool {
        switch self {
        case .focus, .move, .resize:
            return true
        case .toggleFloat, .close, .reload:
            return false
        }
    }
}

struct Bind: Equatable {
    var extra: Mods
    var keyCode: UInt16
    var action: Action
}

struct Config {
    var main = Mods.globe
    var gapsInner: CGFloat = 8
    var gapsOuter: CGFloat = 8
    var splitRatio: CGFloat = 0.5
    var floats: Set<String> = [
        "com.apple.systempreferences",
        "com.apple.SystemSettings",
        "com.apple.calculator",
        "com.apple.Stickies",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.Spotlight",
        "com.apple.loginwindow",
    ]
    var binds: [Bind] = Config.fallbackBinds

    static let fallbackBinds: [Bind] = [
        parseBind("h, focus left"),
        parseBind("j, focus down"),
        parseBind("k, focus up"),
        parseBind("l, focus right"),
        parseBind("shift+h, move left"),
        parseBind("shift+j, move down"),
        parseBind("shift+k, move up"),
        parseBind("shift+l, move right"),
        parseBind("ctrl+h, resize left"),
        parseBind("ctrl+j, resize down"),
        parseBind("ctrl+k, resize up"),
        parseBind("ctrl+l, resize right"),
        parseBind("t, toggle float"),
        parseBind("w, close"),
        parseBind("shift+r, reload"),
    ].compactMap { $0 }

    static let defaultText = """
    # macwm
    #
    # System Settings, Keyboard, Press the globe key to, Do Nothing.
    # The globe key is fn. Globe plus an arrow key is Home, End, or Page Up/Down,
    # so these defaults use hjkl. Arrow keys are fine if modifier is option.
    # Turn Stage Manager off. It fights tiling.
    #
    # modifier is globe, option, control, command, or a combo such as ctrl+option.
    # The modifier is held for every bind below.
    # If any bind line is present, it replaces the default binds.
    # If any float line is present, it replaces the default float list.

    modifier = globe
    gaps_inner = 8
    gaps_outer = 8
    split_ratio = 0.5

    float = com.apple.systempreferences
    float = com.apple.SystemSettings
    float = com.apple.calculator
    float = com.apple.Stickies
    float = com.apple.controlcenter
    float = com.apple.notificationcenterui
    float = com.apple.Spotlight
    float = com.apple.loginwindow

    bind = h, focus left
    bind = j, focus down
    bind = k, focus up
    bind = l, focus right
    bind = shift+h, move left
    bind = shift+j, move down
    bind = shift+k, move up
    bind = shift+l, move right
    bind = ctrl+h, resize left
    bind = ctrl+j, resize down
    bind = ctrl+k, resize up
    bind = ctrl+l, resize right
    bind = t, toggle float
    bind = w, close
    bind = shift+r, reload

    # modifier = option
    # bind = left, focus left
    # bind = right, focus right
    # bind = up, focus up
    # bind = down, focus down
    """

    static func parse(_ text: String) -> (Config, [String]) {
        var config = Config()
        var warnings: [String] = []
        var binds: [Bind] = []
        var floats = Set<String>()
        var sawBind = false
        var sawFloat = false

        for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else {
                warnings.append("line \(index + 1): expected key = value")
                continue
            }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "modifier":
                guard let mods = parseMods(value), mods != Mods() else {
                    warnings.append("line \(index + 1): unknown modifier \(value)")
                    continue
                }
                config.main = mods
            case "gaps_inner":
                guard let n = Double(value), n >= 0 else {
                    warnings.append("line \(index + 1): bad gaps_inner")
                    continue
                }
                config.gapsInner = CGFloat(n)
            case "gaps_outer":
                guard let n = Double(value), n >= 0 else {
                    warnings.append("line \(index + 1): bad gaps_outer")
                    continue
                }
                config.gapsOuter = CGFloat(n)
            case "split_ratio":
                guard let n = Double(value) else {
                    warnings.append("line \(index + 1): bad split_ratio")
                    continue
                }
                config.splitRatio = min(max(CGFloat(n), 0.15), 0.85)
            case "float":
                sawFloat = true
                if value.isEmpty {
                    warnings.append("line \(index + 1): empty bundle id")
                } else {
                    floats.insert(value)
                }
            case "bind":
                sawBind = true
                if let bind = parseBind(value) {
                    binds.append(bind)
                } else {
                    warnings.append("line \(index + 1): bad bind \(value)")
                }
            default:
                warnings.append("line \(index + 1): unknown key \(key)")
            }
        }
        if sawBind { config.binds = binds }
        if sawFloat { config.floats = floats }
        return (config, warnings)
    }
}

enum KeyCode {
    static let left: UInt16 = 0x7B
    static let right: UInt16 = 0x7C
    static let down: UInt16 = 0x7D
    static let up: UInt16 = 0x7E

    static func code(for name: String) -> UInt16? {
        switch name.lowercased() {
        case "a": return 0x00
        case "s": return 0x01
        case "d": return 0x02
        case "f": return 0x03
        case "h": return 0x04
        case "g": return 0x05
        case "z": return 0x06
        case "x": return 0x07
        case "c": return 0x08
        case "v": return 0x09
        case "b": return 0x0B
        case "q": return 0x0C
        case "w": return 0x0D
        case "e": return 0x0E
        case "r": return 0x0F
        case "y": return 0x10
        case "t": return 0x11
        case "o": return 0x1F
        case "u": return 0x20
        case "i": return 0x22
        case "p": return 0x23
        case "l": return 0x25
        case "j": return 0x26
        case "k": return 0x28
        case "n": return 0x2D
        case "m": return 0x2E
        case "1": return 0x12
        case "2": return 0x13
        case "3": return 0x14
        case "4": return 0x15
        case "6": return 0x16
        case "5": return 0x17
        case "9": return 0x19
        case "7": return 0x1A
        case "8": return 0x1C
        case "0": return 0x1D
        case "return", "enter": return 0x24
        case "tab": return 0x30
        case "space": return 0x31
        case "escape", "esc": return 0x35
        case "minus": return 0x1B
        case "equal": return 0x18
        case "left": return left
        case "right": return right
        case "down": return down
        case "up": return up
        default: return nil
        }
    }
}

private func parseMods(_ text: String) -> Mods? {
    var mods = Mods()
    var any = false
    for part in text.split(separator: "+") {
        any = true
        switch part.trimmingCharacters(in: .whitespaces).lowercased() {
        case "globe", "fn": mods.globe = true
        case "shift": mods.shift = true
        case "ctrl", "control": mods.control = true
        case "opt", "option", "alt": mods.option = true
        case "cmd", "command": mods.command = true
        default: return nil
        }
    }
    return any ? mods : nil
}

private func parseBind(_ text: String) -> Bind? {
    let parts = text.split(separator: ",", maxSplits: 1).map {
        $0.trimmingCharacters(in: .whitespaces)
    }
    guard parts.count == 2 else { return nil }
    let chord = parts[0].split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    guard let key = chord.last, let code = KeyCode.code(for: key) else { return nil }
    let extra = parseMods(chord.dropLast().joined(separator: "+")) ?? Mods()
    if chord.count > 1 && extra == Mods() && !chord.dropLast().allSatisfy({ $0.isEmpty }) {
        return nil
    }
    guard let action = parseAction(parts[1]) else { return nil }
    return Bind(extra: extra, keyCode: code, action: action)
}

private func parseAction(_ text: String) -> Action? {
    let parts = text.split(separator: " ").map { $0.lowercased() }
    switch parts.first {
    case "focus":
        guard parts.count == 2, let dir = Direction(rawValue: String(parts[1])) else { return nil }
        return .focus(dir)
    case "move":
        guard parts.count == 2, let dir = Direction(rawValue: String(parts[1])) else { return nil }
        return .move(dir)
    case "resize":
        guard parts.count == 2, let dir = Direction(rawValue: String(parts[1])) else { return nil }
        return .resize(dir)
    case "toggle":
        return parts == ["toggle", "float"] ? .toggleFloat : nil
    case "close":
        return parts == ["close"] ? .close : nil
    case "reload":
        return parts == ["reload"] ? .reload : nil
    default:
        return nil
    }
}
