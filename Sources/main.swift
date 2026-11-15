import AppKit

if CommandLine.arguments.contains("--diagnose") {
    let system = DisplaySystem()
    print("内屏切换接口可用：\(system.canToggleInternal)")
    if let topology = system.topology() {
        print("合盖：\(topology.lidClosed)；内屏 ID：\(topology.internalID.map(String.init) ?? "无")；主屏 ID：\(topology.main)")
        for display in topology.online {
            print("ID \(display.id)：\(display.builtIn ? "内屏" : "外屏")，active=\(display.active)，asleep=\(display.asleep)，mirrorOf=\(display.mirrorOf)，bounds=\(display.bounds)")
        }
        print("在线显示器：\(topology.online.count)")
    } else {
        print("无法获取当前显示拓扑")
    }
} else {
    let app = NSApplication.shared
    let delegate = ScreenModesApp()
    app.setActivationPolicy(.accessory)
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
