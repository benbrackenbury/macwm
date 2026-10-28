import CoreGraphics

enum Direction: String {
    case left, right, up, down
}

enum Cut {
    case sideBySide
    case stacked
}

indirect enum Node {
    case leaf(UInt32)
    case split(Cut, CGFloat, Node, Node)
}

struct Layout {
    var root: Node?
    var splitRatio: CGFloat

    init(splitRatio: CGFloat = 0.5) {
        self.splitRatio = min(max(splitRatio, 0.15), 0.85)
    }

    func contains(_ id: UInt32) -> Bool {
        leaves().contains(id)
    }

    func leaves() -> [UInt32] {
        guard let root else { return [] }
        var out: [UInt32] = []
        func walk(_ node: Node) {
            switch node {
            case .leaf(let id):
                out.append(id)
            case .split(_, _, let a, let b):
                walk(a)
                walk(b)
            }
        }
        walk(root)
        return out
    }

    mutating func reconcile(visible: [UInt32], anchor: UInt32?, work: CGRect, gap: CGFloat) {
        let keep = Set(visible)
        for id in leaves() where !keep.contains(id) {
            remove(id)
        }
        var anchor = anchor.flatMap { contains($0) ? $0 : nil }
        for id in visible.filter({ !contains($0) }).sorted() {
            insert(id, splitting: anchor, work: work, gap: gap)
            anchor = id
        }
    }

    mutating func remove(_ id: UInt32) {
        root = root.flatMap { removed($0, id) }
    }

    mutating func swap(_ a: UInt32, _ b: UInt32) {
        root = root.map { swapped($0, a, b) }
    }

    /// Grows `id` toward `dir` by moving the nearest split edge. No-op when that edge is the screen.
    mutating func resize(_ id: UInt32, toward dir: Direction, step: CGFloat = 0.05) {
        guard let root else { return }
        self.root = resized(root, id: id, toward: dir, step: step).node
    }

    mutating func insert(_ id: UInt32, splitting anchor: UInt32?, work: CGRect, gap: CGFloat) {
        guard root != nil else {
            root = .leaf(id)
            return
        }
        let target = anchor.flatMap { contains($0) ? $0 : nil } ?? leaves()[0]
        let frame = frames(in: work, gap: gap)[target] ?? work
        let cut: Cut = frame.width >= frame.height ? .sideBySide : .stacked
        root = root.map { inserted($0, focus: target, id: id, cut: cut, ratio: splitRatio) }
    }

    func frames(in rect: CGRect, gap: CGFloat) -> [UInt32: CGRect] {
        guard let root else { return [:] }
        return place(root, in: rect, gap: gap)
    }

    /// Prefers a window that overlaps on the cross axis, then the nearer one, then the lower id.
    static func neighbor(of id: UInt32, toward dir: Direction, in frames: [UInt32: CGRect]) -> UInt32? {
        guard let mine = frames[id] else { return nil }
        var best: (id: UInt32, primary: CGFloat, overlap: CGFloat)?
        for (other, frame) in frames where other != id {
            let dx = frame.midX - mine.midX
            let dy = frame.midY - mine.midY
            let primary: CGFloat
            let overlap: CGFloat
            switch dir {
            case .left:
                guard dx < -0.5 else { continue }
                primary = -dx
                overlap = cross(mine, frame, vertical: true)
            case .right:
                guard dx > 0.5 else { continue }
                primary = dx
                overlap = cross(mine, frame, vertical: true)
            case .up:
                guard dy < -0.5 else { continue }
                primary = -dy
                overlap = cross(mine, frame, vertical: false)
            case .down:
                guard dy > 0.5 else { continue }
                primary = dy
                overlap = cross(mine, frame, vertical: false)
            }
            let next = (other, primary, overlap)
            if let current = best {
                if better(next, than: current) { best = next }
            } else {
                best = next
            }
        }
        return best?.id
    }
}

private func cross(_ a: CGRect, _ b: CGRect, vertical: Bool) -> CGFloat {
    if vertical {
        return max(0, min(a.maxY, b.maxY) - max(a.minY, b.minY))
    }
    return max(0, min(a.maxX, b.maxX) - max(a.minX, b.minX))
}

private func better(
    _ new: (id: UInt32, primary: CGFloat, overlap: CGFloat),
    than old: (id: UInt32, primary: CGFloat, overlap: CGFloat)
) -> Bool {
    let newHits = new.overlap > 0.5
    let oldHits = old.overlap > 0.5
    if newHits != oldHits { return newHits }
    if abs(new.primary - old.primary) > 0.5 { return new.primary < old.primary }
    if abs(new.overlap - old.overlap) > 0.5 { return new.overlap > old.overlap }
    return new.id < old.id
}

private func removed(_ node: Node, _ id: UInt32) -> Node? {
    switch node {
    case .leaf(let leaf) where leaf == id:
        return nil
    case .leaf:
        return node
    case .split(let cut, let ratio, let a, let b):
        switch (removed(a, id), removed(b, id)) {
        case (nil, nil):
            return nil
        case (nil, let side?):
            return side
        case (let side?, nil):
            return side
        case (let a?, let b?):
            return .split(cut, ratio, a, b)
        }
    }
}

private func inserted(_ node: Node, focus: UInt32, id: UInt32, cut: Cut, ratio: CGFloat) -> Node {
    switch node {
    case .leaf(let leaf) where leaf == focus:
        return .split(cut, ratio, .leaf(leaf), .leaf(id))
    case .leaf:
        return node
    case .split(let existing, let existingRatio, let a, let b):
        return .split(
            existing,
            existingRatio,
            inserted(a, focus: focus, id: id, cut: cut, ratio: ratio),
            inserted(b, focus: focus, id: id, cut: cut, ratio: ratio)
        )
    }
}

private func swapped(_ node: Node, _ a: UInt32, _ b: UInt32) -> Node {
    switch node {
    case .leaf(let id) where id == a:
        return .leaf(b)
    case .leaf(let id) where id == b:
        return .leaf(a)
    case .leaf:
        return node
    case .split(let cut, let ratio, let left, let right):
        return .split(cut, ratio, swapped(left, a, b), swapped(right, a, b))
    }
}

private func resized(_ node: Node, id: UInt32, toward dir: Direction, step: CGFloat) -> (node: Node, done: Bool) {
    switch node {
    case .leaf:
        return (node, false)
    case .split(let cut, let ratio, let a, let b):
        let left = resized(a, id: id, toward: dir, step: step)
        if left.done { return (.split(cut, ratio, left.node, b), true) }
        let right = resized(b, id: id, toward: dir, step: step)
        if right.done { return (.split(cut, ratio, a, right.node), true) }
        let inA = contains(a, id)
        guard inA || contains(b, id) else { return (node, false) }
        var ratio = ratio
        switch (dir, cut, inA) {
        case (.right, .sideBySide, true), (.down, .stacked, true):
            ratio += step
        case (.left, .sideBySide, false), (.up, .stacked, false):
            ratio -= step
        default:
            return (node, false)
        }
        return (.split(cut, min(max(ratio, 0.15), 0.85), a, b), true)
    }
}

private func contains(_ node: Node, _ id: UInt32) -> Bool {
    switch node {
    case .leaf(let leaf):
        return leaf == id
    case .split(_, _, let a, let b):
        return contains(a, id) || contains(b, id)
    }
}

private func place(_ node: Node, in rect: CGRect, gap: CGFloat) -> [UInt32: CGRect] {
    switch node {
    case .leaf(let id):
        return [id: rect]
    case .split(.sideBySide, let ratio, let a, let b):
        let usable = max(0, rect.width - gap)
        let leftWidth = usable * ratio
        let left = CGRect(x: rect.minX, y: rect.minY, width: leftWidth, height: rect.height)
        let right = CGRect(
            x: rect.minX + leftWidth + gap,
            y: rect.minY,
            width: usable - leftWidth,
            height: rect.height
        )
        return place(a, in: left, gap: gap).merging(place(b, in: right, gap: gap)) { _, new in new }
    case .split(.stacked, let ratio, let a, let b):
        let usable = max(0, rect.height - gap)
        let topHeight = usable * ratio
        let top = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: topHeight)
        let bottom = CGRect(
            x: rect.minX,
            y: rect.minY + topHeight + gap,
            width: rect.width,
            height: usable - topHeight
        )
        return place(a, in: top, gap: gap).merging(place(b, in: bottom, gap: gap)) { _, new in new }
    }
}
