import Foundation

enum MainScreen: Int, Codable, CaseIterable {
    case internalScreen, externalScreen
    var title: String { self == .internalScreen ? "内屏" : "外屏" }
    var secondary: MainScreen { self == .internalScreen ? .externalScreen : .internalScreen }
}

enum SecondaryBehavior: Int, Codable, CaseIterable {
    case extended, mirrored, off
    var title: String {
        switch self {
        case .extended: return "扩展"
        case .mirrored: return "镜像"
        case .off: return "关闭"
        }
    }
}

enum Side: Int, Codable, CaseIterable {
    case right, left, above, below
    var title: String { ["右侧", "左侧", "上方", "下方"][rawValue] }
}

struct Mode: Codable, Identifiable {
    let id: UUID
    var name: String
    var primary: MainScreen
    var secondary: SecondaryBehavior
    var side: Side

    init(_ name: String, _ primary: MainScreen, _ secondary: SecondaryBehavior,
         _ side: Side = .right, id: UUID = UUID()) {
        self.id = id
        self.name = name
        self.primary = primary
        self.secondary = secondary
        self.side = side
    }

    var closesInternal: Bool { primary == .externalScreen && secondary == .off }
    var closesExternal: Bool { primary == .internalScreen && secondary == .off }
    var defaultName: String { "\(primary.title)主屏 · \(primary.secondary.title)\(secondary.title)" }

    private enum Keys: String, CodingKey { case id, name, primary, secondary, side, kind }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: Keys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        side = try values.decode(Side.self, forKey: .side)
        if values.contains(.primary) {
            primary = try values.decode(MainScreen.self, forKey: .primary)
            secondary = try values.decode(SecondaryBehavior.self, forKey: .secondary)
        } else {
            let kind = try values.decode(Int.self, forKey: .kind)
            switch kind {
            case 0: primary = .internalScreen; secondary = .extended
            case 1: primary = .externalScreen; secondary = .off
            case 2: primary = .externalScreen; secondary = .extended
            default: throw DecodingError.dataCorruptedError(forKey: .kind, in: values, debugDescription: "Unknown legacy display mode")
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: Keys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(primary, forKey: .primary)
        try values.encode(secondary, forKey: .secondary)
        try values.encode(side, forKey: .side)
    }

    static let defaults = [Mode("内屏主屏 · 外屏扩展", .internalScreen, .extended),
                           Mode("外屏主屏 · 关闭内屏", .externalScreen, .off)]
}

struct Placement: Equatable {
    let id: DisplayID
    let x: Int32
    let y: Int32
}

enum DisplayStep: Equatable {
    case ready, waitingForLid, waitingForDisplay, unsupported, restore, unmirror,
         position([Placement], DisplayID), mirror([DisplayID], DisplayID), disable(DisplayID),
         disableExternal([DisplayID], DisplayID)
}

func nextStep(_ mode: Mode, _ state: Topology, canToggle: Bool, hasDisabledExternal: Bool = false) -> DisplayStep {
    guard !state.external.isEmpty || hasDisabledExternal else { return .waitingForDisplay }
    let internalScreen = state.internalScreen
    if mode.secondary == .off && !canToggle && (mode.closesExternal || internalScreen != nil) {
        return .unsupported
    }
    if !mode.closesInternal && state.lidClosed { return .waitingForLid }
    if !mode.closesInternal && !state.internalInUse && internalScreen?.asleep != true {
        if !canToggle { return .unsupported }
        return state.internalID == nil ? .waitingForDisplay : .restore
    }

    let externalMain = state.external.first(where: { $0.id == state.main && !$0.asleep })
        ?? state.external.first(where: { $0.active && !$0.asleep })
        ?? state.external.first(where: { !$0.asleep && $0.mirrorOf != 0 })
    guard let primary = mode.primary == .internalScreen ? internalScreen : externalMain,
          !primary.asleep else { return .waitingForDisplay }

    let secondaries = state.online.filter { $0.id != primary.id }
    if mode.secondary == .mirrored && state.main == primary.id && primary.active &&
        !secondaries.isEmpty && secondaries.allSatisfy({ $0.mirrorOf == primary.id }) { return .ready }

    if state.online.contains(where: { $0.mirrorOf != 0 }) { return .unmirror }
    guard primary.active else { return .waitingForDisplay }

    if mode.secondary != .extended && state.main != primary.id {
        let origin = primary.bounds.origin
        let translated = state.online.filter(\.active).map {
            Placement(id: $0.id, x: Int32($0.bounds.minX - origin.x), y: Int32($0.bounds.minY - origin.y))
        }
        return .position(translated, primary.id)
    }
    switch mode.secondary {
    case .mirrored:
        guard !secondaries.isEmpty, secondaries.allSatisfy({ $0.active && !$0.asleep }) else {
            return .waitingForDisplay
        }
        return .mirror(secondaries.map(\.id), primary.id)
    case .off:
        if mode.closesInternal {
            if internalScreen?.active == true || (internalScreen != nil && !state.lidClosed) {
                return .disable(primary.id)
            }
            return .ready
        }
        return secondaries.isEmpty ? .ready : .disableExternal(secondaries.map(\.id), primary.id)
    case .extended:
        break
    }

    guard secondaries.allSatisfy({ $0.active && !$0.asleep }) else { return .waitingForDisplay }
    var positions = [Placement(id: primary.id, x: 0, y: 0)]
    var cursor: CGFloat
    switch mode.side {
    case .right: cursor = primary.bounds.width
    case .below: cursor = primary.bounds.height
    case .left, .above: cursor = 0
    }
    for screen in secondaries {
        var x: CGFloat = 0
        var y: CGFloat = 0
        switch mode.side {
        case .right: x = cursor; cursor += screen.bounds.width
        case .left: cursor -= screen.bounds.width; x = cursor
        case .below: y = cursor; cursor += screen.bounds.height
        case .above: cursor -= screen.bounds.height; y = cursor
        }
        positions.append(Placement(id: screen.id, x: Int32(x), y: Int32(y)))
    }
    let alreadyArranged = positions.allSatisfy { p in
        state.online.contains { $0.id == p.id && Int32($0.bounds.minX) == p.x && Int32($0.bounds.minY) == p.y }
    }
    return state.main == primary.id && alreadyArranged ? .ready : .position(positions, primary.id)
}

struct ExternalPresence {
    private var missingSince: TimeInterval?

    mutating func clear() { missingSince = nil }

    mutating func disconnected(at now: TimeInterval, wakeGraceUntil: TimeInterval) -> Bool {
        if let missingSince { return now >= wakeGraceUntil && now - missingSince >= 1.5 }
        missingSince = now
        return false
    }
}
