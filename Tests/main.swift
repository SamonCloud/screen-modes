import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ detail: String) {
    guard condition() else { fatalError(detail) }
}

func screen(_ id: DisplayID, x: CGFloat = 0, mirrorOf: DisplayID = 0, asleep: Bool = false) -> Display {
    Display(id: id, builtIn: id == 1, active: mirrorOf == 0, asleep: asleep, mirrorOf: mirrorOf,
            mirrored: mirrorOf != 0, bounds: CGRect(x: x, y: 0, width: 100, height: 80))
}

func setup(_ displays: [Display], main: DisplayID = 1, lidClosed: Bool = false, hasInternal: Bool = true) -> Topology {
    Topology(online: displays, internalID: hasInternal ? 1 : nil, main: main, lidClosed: lidClosed)
}

let inside = Mode("inside", .internalScreen, .extended)
let outside = Mode("outside", .externalScreen, .off)
let left = Mode("outside extended", .externalScreen, .extended, .left)
let twoScreens = setup([screen(1), screen(2, x: 100)])
let externalPrimary = setup([screen(1, x: -100), screen(2)], main: 2)
let builtinOffline = setup([screen(2)], main: 2)
let lidShut = setup([screen(2)], main: 2, lidClosed: true)
let internalOnly = setup([screen(1)])

expect(nextStep(inside, twoScreens, canToggle: true) == .ready, "Accept the configured internal primary")
expect(nextStep(left, externalPrimary, canToggle: true) == .ready, "Accept an external primary with internal extension to the left")
expect(nextStep(inside, externalPrimary, canToggle: true) ==
       .position([Placement(id: 1, x: 0, y: 0), Placement(id: 2, x: 100, y: 0)], 1), "Return internal to the origin")
expect(nextStep(outside, twoScreens, canToggle: true) ==
       .position([Placement(id: 1, x: -100, y: 0), Placement(id: 2, x: 0, y: 0)], 2), "Promote external before turning off internal")
expect(nextStep(outside, externalPrimary, canToggle: true) == .disable(2), "Disconnect internal only after replacement is primary")
expect(nextStep(outside, internalOnly, canToggle: true) == .waitingForDisplay, "Never disable the only screen")
expect(nextStep(outside, setup([screen(1), screen(2, asleep: true)]), canToggle: true) == .waitingForDisplay, "Reject a sleeping replacement")
expect(nextStep(outside, setup([screen(1), screen(2, mirrorOf: 1)]), canToggle: true) == .unmirror, "End mirroring before promoting external")
expect(nextStep(outside, externalPrimary, canToggle: false) == .unsupported, "Do not move or disable when private APIs are unavailable")
expect(nextStep(outside, builtinOffline, canToggle: true) == .ready, "Verify external-only mode")
expect(nextStep(inside, builtinOffline, canToggle: true) == .restore, "Restore disabled internal before changing origins")
expect(nextStep(inside, lidShut, canToggle: true) == .waitingForLid, "Retain dual-screen selection while lid is closed")
expect(nextStep(outside, lidShut, canToggle: true) == .ready, "External-only works without changing an already offline internal panel")

var presence = ExternalPresence()
expect(!presence.disconnected(at: 10, wakeGraceUntil: 0), "Do not reset selection instantly")
expect(!presence.disconnected(at: 11.4, wakeGraceUntil: 0), "Debounce a short disconnect")
presence.clear()
expect(!presence.disconnected(at: 20, wakeGraceUntil: 23), "Allow the dock to return after wake")
expect(!presence.disconnected(at: 22, wakeGraceUntil: 23), "Wake grace overrides debounce")
expect(presence.disconnected(at: 23, wakeGraceUntil: 23), "Once confirmed, return to internal-only")
let internalMirror = Mode("internal mirror", .internalScreen, .mirrored)
let externalMirror = Mode("external mirror", .externalScreen, .mirrored)
let internalOnlyMode = Mode("internal only", .internalScreen, .off)
let mirroredFromExternal = setup([screen(1, mirrorOf: 2), screen(2)], main: 2)
expect(nextStep(internalMirror, twoScreens, canToggle: true) == .mirror([2], 1), "Mirror external from internal")
expect(nextStep(externalMirror, externalPrimary, canToggle: true) == .mirror([1], 2), "Mirror internal from external")
expect(nextStep(externalMirror, mirroredFromExternal, canToggle: true) == .ready, "Leave an applied mirror intact")
expect(nextStep(internalMirror, mirroredFromExternal, canToggle: true) == .unmirror, "Reverse an existing mirror")
expect(nextStep(internalOnlyMode, twoScreens, canToggle: true) == .disableExternal([2], 1), "Disable external after verifying internal primary")
expect(nextStep(internalOnlyMode, internalOnly, canToggle: true, hasDisabledExternal: true) == .ready, "Treat a software-disabled external as connected")

let legacy = #"[{"id":"C8055FE6-45F5-46F3-A2DC-EE6260A0BE0D","name":"旧预设","kind":1,"side":2}]"#
let oldMode = try JSONDecoder().decode([Mode].self, from: Data(legacy.utf8))[0]
expect(oldMode.primary == .externalScreen && oldMode.secondary == .off && oldMode.side == .above &&
       oldMode.name == "旧预设" && oldMode.id.uuidString == "C8055FE6-45F5-46F3-A2DC-EE6260A0BE0D", "Preserve old presets")
let roundTrip = try JSONDecoder().decode(Mode.self, from: JSONEncoder().encode(externalMirror))
expect(roundTrip.primary == .externalScreen && roundTrip.secondary == .mirrored, "Persist mirror modes")
expect(isHeadlessPlaceholder(vendor: 0x756E6B6E, model: 0x76697274), "WindowServer fallback must not count as an external monitor")
expect(!isHeadlessPlaceholder(vendor: 0x10AC, model: 0x9840), "Keep a connected Dell monitor")
expect(!isHeadlessPlaceholder(vendor: 0x756E6B6E, model: 0x9840), "Unknown vendor alone does not make a display a placeholder")
print("通过：29 项显示切换、断线和预设检查")
