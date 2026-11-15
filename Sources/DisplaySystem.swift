import AppKit
import CoreGraphics
import Darwin
import IOKit

typealias DisplayID = CGDirectDisplayID

func isHeadlessPlaceholder(vendor: UInt32, model: UInt32) -> Bool {
    // WindowServer's fallback output when no physical display is available.
    vendor == 0x756E6B6E && model == 0x76697274 // 'unkn' / 'virt'
}

struct Display: Equatable {
    let id: DisplayID
    let builtIn: Bool
    let active: Bool
    let asleep: Bool
    let mirrorOf: DisplayID
    let mirrored: Bool
    let bounds: CGRect
}

struct Topology: Equatable {
    let online: [Display]
    let internalID: DisplayID?
    let main: DisplayID
    let lidClosed: Bool
    var externalHardware: [DisplayID: String] = [:]

    var internalScreen: Display? { online.first(where: \.builtIn) }
    var internalInUse: Bool { internalScreen.map { $0.active || $0.mirrorOf != 0 } ?? false }
    var external: [Display] { online.filter { !$0.builtIn } }
}

enum DisplayFailure: LocalizedError {
    case unavailable, unsafe, core(String, Int32)

    var errorDescription: String? {
        switch self {
        case .unavailable: return "当前无法安全地切换屏幕"
        case .unsafe: return "主屏尚未就绪，已保留副屏"
        case let .core(operation, code): return "\(operation)失败（\(code)）"
        }
    }
}

final class DisplaySystem {
    private typealias ListFn = @convention(c) (UInt32, UnsafeMutablePointer<DisplayID>, UnsafeMutablePointer<UInt32>) -> Int32
    private typealias EnableFn = @convention(c) (CGDisplayConfigRef, DisplayID, Bool) -> Int32
    private let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL)

    private func symbol<T>(_ names: [String], as _: T.Type) -> T? {
        for name in names {
            if let p = sky.flatMap({ dlsym($0, name) }) ?? dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) {
                return unsafeBitCast(p, to: T.self)
            }
        }
        return nil
    }

    private lazy var allDisplays = symbol(["SLSGetDisplayList", "CGSGetDisplayList"], as: ListFn.self)
    private lazy var enable = symbol(["SLSConfigureDisplayEnabled", "CGSConfigureDisplayEnabled"], as: EnableFn.self)
    var canToggleInternal: Bool {
        #if arch(arm64)
        return allDisplays != nil && enable != nil
        #else
        return false
        #endif
    }

    private func ids(_ list: (UInt32, UnsafeMutablePointer<DisplayID>, UnsafeMutablePointer<UInt32>) -> Int32) -> [DisplayID]? {
        var ids = [DisplayID](repeating: 0, count: 64)
        var count: UInt32 = 0
        let result = ids.withUnsafeMutableBufferPointer {
            list(UInt32($0.count), $0.baseAddress!, &count)
        }
        guard result == 0, count < ids.count else { return nil }
        return ids.prefix(Int(count)).filter { $0 != 0 }.sorted()
    }

    func topology() -> Topology? {
        guard let online = ids({ CGGetOnlineDisplayList($0, $1, $2).rawValue }) else { return nil }
        let all = allDisplays.flatMap { ids($0) } ?? online
        let displays = online.compactMap { id -> Display? in
            guard !isHeadlessPlaceholder(vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id)) else {
                return nil
            }
            return Display(id: id, builtIn: CGDisplayIsBuiltin(id) == 1, active: CGDisplayIsActive(id) == 1,
                           asleep: CGDisplayIsAsleep(id) == 1, mirrorOf: CGDisplayMirrorsDisplay(id),
                           mirrored: CGDisplayIsInMirrorSet(id) == 1, bounds: CGDisplayBounds(id))
        }
        let internalID = displays.first(where: \.builtIn)?.id
            ?? all.first(where: { CGDisplayIsBuiltin($0) == 1 })
        let externalHardware = Dictionary(uniqueKeysWithValues: Set(all + online).compactMap { id -> (DisplayID, String)? in
            guard CGDisplayIsBuiltin(id) == 0 else { return nil }
            let vendor = CGDisplayVendorNumber(id)
            let model = CGDisplayModelNumber(id)
            let serial = CGDisplaySerialNumber(id)
            guard !isHeadlessPlaceholder(vendor: vendor, model: model),
                  vendor != 0 || model != 0 || serial != 0 else { return nil }
            return (id, "\(vendor):\(model):\(serial)")
        })
        return Topology(online: displays, internalID: internalID, main: CGMainDisplayID(),
                        lidClosed: lidClosed(), externalHardware: externalHardware)
    }

    private func lidClosed() -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        return IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool ?? false
    }

    private func check(_ result: Int32, _ operation: String) throws {
        if result != 0 { throw DisplayFailure.core(operation, result) }
    }

    private func configure(_ changes: (CGDisplayConfigRef) throws -> Void) throws {
        var optional: CGDisplayConfigRef?
        try check(CGBeginDisplayConfiguration(&optional).rawValue, "开始显示配置")
        guard let config = optional else { throw DisplayFailure.unavailable }
        do { try changes(config) }
        catch { CGCancelDisplayConfiguration(config); throw error }
        try check(CGCompleteDisplayConfiguration(config, .forSession).rawValue, "提交显示配置")
    }

    func showInternal(_ enabled: Bool, replacement: DisplayID? = nil,
                      rememberedID: DisplayID? = nil, snapshot: Topology? = nil) throws {
        guard canToggleInternal, let enable, let state = snapshot ?? topology() else {
            throw DisplayFailure.unavailable
        }
        let fallback = enabled && state.external.isEmpty ? rememberedID : nil
        guard let id = state.internalID ?? fallback else { throw DisplayFailure.unavailable }
        if !enabled {
            // Recheck against the live topology immediately before turning off the panel.
            guard let replacement, state.main == replacement,
                  state.external.contains(where: {
                      $0.id == replacement && $0.active && !$0.asleep && !$0.mirrored
                  }) else { throw DisplayFailure.unsafe }
        }
        try configure { try check(enable($0, id, enabled), enabled ? "恢复内屏" : "关闭内屏") }
    }

    func stopMirroring(_ displays: [Display]) throws {
        try configure { config in
            for screen in displays where screen.mirrorOf != 0 {
                try check(CGConfigureDisplayMirrorOfDisplay(config, screen.id, kCGNullDirectDisplay).rawValue, "退出镜像")
            }
        }
    }

    func mirror(_ ids: [DisplayID], primary: DisplayID) throws {
        try configure { config in
            for id in ids {
                try check(CGConfigureDisplayMirrorOfDisplay(config, id, primary).rawValue, "启用镜像")
            }
        }
    }

    func disableExternal(_ ids: [DisplayID], keeping primary: DisplayID) throws {
        guard canToggleInternal, let enable, let state = topology(), state.main == primary,
              !state.lidClosed, let internalScreen = state.internalScreen, internalScreen.id == primary,
              internalScreen.active, !internalScreen.asleep, !internalScreen.mirrored else {
            throw DisplayFailure.unsafe
        }
        guard ids.allSatisfy({ id in
            state.external.contains { $0.id == id && !$0.mirrored } && state.externalHardware[id] != nil
        }) else { throw DisplayFailure.unavailable }
        try configure { config in
            for id in ids { try check(enable(config, id, false), "关闭外屏") }
        }
    }

    func restoreExternal(_ fingerprints: Set<String>) throws {
        guard canToggleInternal, let enable, let state = topology() else { throw DisplayFailure.unavailable }
        let online = Set(state.external.map(\.id))
        let ids = state.externalHardware.keys.filter {
            !online.contains($0) && state.externalHardware[$0].map(fingerprints.contains) == true
        }.sorted()
        guard !ids.isEmpty else { return }
        try configure { config in
            for id in ids { try check(enable(config, id, true), "恢复外屏") }
        }
    }

    func arrange(_ positions: [Placement], primary: DisplayID) throws {
        try configure { config in
            for item in positions.sorted(by: { ($0.id == primary ? 0 : 1, $0.id) < ($1.id == primary ? 0 : 1, $1.id) }) {
                try check(CGConfigureDisplayOrigin(config, item.id, item.x, item.y).rawValue, "排列屏幕")
            }
        }
    }
}
