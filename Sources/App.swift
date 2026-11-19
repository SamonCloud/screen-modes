import AppKit
import CoreGraphics
import ServiceManagement
import os

private let logger = Logger(subsystem: "com.samuelzhao.screen-modes", category: "display")
private let displayChanged: CGDisplayReconfigurationCallBack = { _, flags, context in
    guard !flags.contains(.beginConfigurationFlag), let context else { return }
    let app = Unmanaged<ScreenModesApp>.fromOpaque(context).takeUnretainedValue()
    DispatchQueue.main.async { [weak app] in app?.reconcile() }
}

final class ScreenModesApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let system = DisplaySystem()
    private let defaults = UserDefaults.standard
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private var modes: [Mode] = []
    private var selected: UUID?
    private var state: Topology?
    private var status = "正在检测屏幕…"
    private var timer: Timer?
    private var presence = ExternalPresence()
    private var wakeGrace: TimeInterval = 0
    private var sleeping = false
    private var screensSleeping = false
    private var screenLocked = false
    private var attempts = 0
    private var nextAttempt: TimeInterval = 0
    private var displayCallbackRegistered = false
    private var terminating = false
    private var resetOutputRequested = false
    private var recoveryActivity: NSObjectProtocol?
    private var ownsDisable: Bool {
        get { defaults.bool(forKey: "restoreInternalOnLaunch") }
        set { if newValue != ownsDisable { defaults.set(newValue, forKey: "restoreInternalOnLaunch") } }
    }

    private var ownedExternals: Set<String> {
        get { Set(defaults.stringArray(forKey: "restoreExternalOnLaunch") ?? []) }
        set {
            if newValue != ownedExternals { defaults.set(newValue.sorted(), forKey: "restoreExternalOnLaunch") }
        }
    }

    private func disabledExternals(in topology: Topology) -> Set<String> {
        let online = Set(topology.external.map(\.id))
        return Set(topology.externalHardware.filter { !online.contains($0.key) }.values)
            .intersection(ownedExternals)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        modes = defaults.data(forKey: "modes").flatMap { try? JSONDecoder().decode([Mode].self, from: $0) } ?? Mode.defaults
        // A replacement launch can hand over the existing external-only session.
        if CommandLine.arguments.contains("--keep-external-only"), ownsDisable,
           let current = system.topology(), !current.external.isEmpty, !current.internalInUse {
            selected = modes.first(where: \.closesInternal)?.id
        }
        menu.delegate = self
        statusItem.menu = menu
        updateBadge()
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        center.addObserver(self, selector: #selector(screensDidSleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(screensDidWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        let session = DistributedNotificationCenter.default()
        session.addObserver(self, selector: #selector(didLock), name: Notification.Name("com.apple.screenIsLocked"),
                            object: nil, suspensionBehavior: .deliverImmediately)
        session.addObserver(self, selector: #selector(didUnlock), name: Notification.Name("com.apple.screenIsUnlocked"),
                            object: nil, suspensionBehavior: .deliverImmediately)
        displayCallbackRegistered = CGDisplayRegisterReconfigurationCallback(
            displayChanged, Unmanaged.passUnretained(self).toOpaque()
        ) == .success
        // Polling also covers lid and dock transitions for which WindowServer doesn't send a display event.
        timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in self?.reconcile() }
        reconcile()
        rebuildMenu()
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) { reconcile() }

    func applicationWillTerminate(_ notification: Notification) {
        terminating = true
        timer?.invalidate()
        DistributedNotificationCenter.default().removeObserver(self)
        if displayCallbackRegistered {
            CGDisplayRemoveReconfigurationCallback(displayChanged, Unmanaged.passUnretained(self).toOpaque())
        }
        updateRecoveryActivity(needed: false)
    }

    @objc private func willSleep() {
        sleeping = true
        presence.clear()
        // Make the panel available while WindowServer can still address it.
        if ownsDisable, let current = system.topology(),
           internalDisplaySleepAction(current, sessionProtected: true, appDisabledPanel: true) == .restorePanel {
            restoreForSleep(current)
        }
    }

    @objc private func didWake() {
        sleeping = false
        screensSleeping = false
        afterWake()
    }

    @objc private func screensDidSleep() {
        screensSleeping = true
        resetAttempts()
        reconcile()
    }

    @objc private func screensDidWake() {
        screensSleeping = false
        afterWake()
    }

    @objc private func didLock() {
        screenLocked = true
        resetAttempts()
        reconcile()
    }

    @objc private func didUnlock() {
        screenLocked = false
        screensSleeping = false
        afterWake()
    }

    private func afterWake() {
        wakeGrace = ProcessInfo.processInfo.systemUptime + 3
        resetAttempts()
        reconcile()
    }

    private func resetAttempts() { attempts = 0; nextAttempt = 0 }
    private func updateBadge() {
        statusItem.button?.image = NSImage(systemSymbolName: selected == nil ? "display" : "display.2", accessibilityDescription: "屏幕模式")
        statusItem.button?.toolTip = "屏幕模式：\(status)"
    }

    private func showStatus(_ value: String) {
        guard status != value else { return }
        status = value
        updateBadge()
    }

    fileprivate func reconcile() {
        guard !sleeping, !terminating else { return }
        guard let current = system.topology() else { showStatus("暂时无法读取屏幕状态"); return }
        let now = ProcessInfo.processInfo.systemUptime
        let previous = state
        state = current
        if previous?.external.map(\.id) != current.external.map(\.id) ||
            previous?.lidClosed != current.lidClosed {
            resetAttempts()
        }

        let mode = modes.first(where: { $0.id == selected })
        let disabled = disabledExternals(in: current)
        let hasExternal = !current.external.isEmpty || !disabled.isEmpty
        if let id = current.internalID, id != defaults.object(forKey: "lastBuiltInDisplay") as? DisplayID {
            defaults.set(Int(id), forKey: "lastBuiltInDisplay")
        }
        updateRecoveryActivity(needed: ownsDisable)

        // Screen-sleep notifications can arrive when the last usable output disappears.
        // Keep inspecting topology then, but defer normal layout changes until it wakes.
        if !hasExternal {
            let confirmed = presence.disconnected(at: now, wakeGraceUntil: wakeGrace)
            if confirmed, selected != nil {
                selected = nil
                updateBadge()
                logger.notice("Last external display disconnected; mode selection cleared")
            }
            if ownsDisable && !current.lidClosed && !current.internalAvailable {
                recoverAfterUnplug(current, now: now, confirmed: confirmed)
                return
            }
        } else {
            presence.clear()
            resetOutputRequested = false
        }
        let protected = screensSleeping || screenLocked || system.sessionLocked || now < wakeGrace
        switch internalDisplaySleepAction(current, sessionProtected: protected, appDisabledPanel: ownsDisable) {
        case .restorePanel:
            attempt("正在为锁屏或睡眠恢复内屏…", now: now) { restoreForSleep(current) }
            return
        case .keepPanelAvailable:
            if ownsDisable && current.internalAvailable {
                ownsDisable = false
                updateRecoveryActivity(needed: false)
                logger.notice("Built-in display available during lock or display sleep")
            }
            if !hasExternal && selected == nil && !current.lidClosed && current.internalAvailable {
                showStatus("仅内屏")
            } else if mode?.closesInternal == true {
                showStatus("已保留选择 · 解锁或显示器唤醒后继续")
            }
            return
        case .continueMode:
            break
        }

        if now >= wakeGrace, mode?.closesExternal != true || current.lidClosed {
            if !disabled.isEmpty {
                attempt("正在恢复外屏…", now: now) { try system.restoreExternal(disabled) }
                return
            }
            if mode?.closesExternal != true { ownedExternals = [] }
        }

        if !hasExternal {
            if selected != nil {
                showStatus("正在确认外屏连接…")
                return
            }
            // If the lid is closed, the built-in becomes usable only after opening it.
            if current.lidClosed {
                showStatus("没有外屏 · 开盖后使用内屏")
            } else if current.internalScreen?.active == true {
                ownsDisable = false
                showStatus("仅内屏")
            } else if ownsDisable || current.internalID != nil {
                attempt("正在恢复内屏…", now: now) { try system.showInternal(true) }
            } else {
                showStatus("未检测到可用屏幕")
            }
            return
        }

        guard let mode else {
            if ownsDisable && !current.lidClosed && !current.internalInUse {
                attempt("正在恢复内屏…", now: now) { try system.showInternal(true) }
            } else {
                if current.internalInUse { ownsDisable = false }
                showStatus(ownsDisable ? "已取消管理 · 开盖后恢复内屏" : "已连接外屏 · 等待选择模式")
            }
            return
        }
        if current.internalInUse && !mode.closesInternal { ownsDisable = false }
        guard now >= wakeGrace else { showStatus("正在等待屏幕唤醒…"); return }
        switch nextStep(mode, current, canToggle: system.canToggleInternal, hasDisabledExternal: !disabled.isEmpty) {
        case .ready:
            resetAttempts()
            showStatus("已应用：\(mode.name)")
        case .waitingForLid: showStatus("已保留选择 · 开盖后恢复")
        case .waitingForDisplay: showStatus("已保留选择 · 等待屏幕可用")
        case .unsupported: showStatus("当前系统无法启用或关闭副屏")
        case .restore:
            attempt("正在启用内屏…", now: now) { try system.showInternal(true) }
        case .unmirror:
            attempt("正在退出镜像…", now: now) { try system.stopMirroring(current.online) }
        case let .position(positions, primary):
            attempt("正在排列屏幕…", now: now) { try system.arrange(positions, primary: primary) }
        case let .mirror(ids, primary):
            attempt("正在启用镜像…", now: now) { try system.mirror(ids, primary: primary) }
        case let .disableExternal(ids, primary):
            attempt("正在关闭外屏…", now: now) {
                ownedExternals.formUnion(ids.compactMap { current.externalHardware[$0] })
                try system.disableExternal(ids, keeping: primary)
            }
        case let .disable(replacement):
            attempt("正在关闭内屏…", now: now) {
                ownsDisable = true
                updateRecoveryActivity(needed: true)
                try system.showInternal(false, replacement: replacement)
            }
        }
    }

    private func updateRecoveryActivity(needed: Bool) {
        if needed && recoveryActivity == nil {
            recoveryActivity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiated, reason: "Keep sleep recovery available while the built-in display is disabled"
            )
        } else if !needed, let activity = recoveryActivity {
            ProcessInfo.processInfo.endActivity(activity)
            recoveryActivity = nil
        }
    }

    private func restoreForSleep(_ current: Topology) {
        logger.notice("Restoring the built-in display for lock or sleep")
        do { try system.showInternal(true, snapshot: current) }
        catch { logger.error("Pre-sleep restore failed: \(error.localizedDescription, privacy: .public)") }
    }

    private func recoverAfterUnplug(_ current: Topology, now: TimeInterval, confirmed: Bool) {
        guard now >= nextAttempt else { return }
        if attempts == 0 { logger.notice("No external display remains; restoring built-in display") }
        if confirmed && attempts >= 3 && !resetOutputRequested {
            resetOutputRequested = true
            nextAttempt = now + 4
            showStatus("正在重新唤醒内屏…")
            logger.notice("Direct recovery did not restore the panel; cycling display power once")
            cycleDisplayPower()
            return
        }
        let id = DisplayID(exactly: defaults.integer(forKey: "lastBuiltInDisplay"))
        attempt("正在恢复内屏…", now: now) {
            try system.showInternal(true, rememberedID: id == 0 ? nil : id, snapshot: current)
        }
    }

    private func cycleDisplayPower() {
        let sleepDisplays = Process()
        sleepDisplays.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        sleepDisplays.arguments = ["displaysleepnow"]
        sleepDisplays.terminationHandler = { [weak self] process in
            guard process.terminationStatus == 0 else {
                logger.error("Display sleep command failed: \(process.terminationStatus)")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, !self.sleeping, !self.terminating, self.system.topology()?.lidClosed == false else { return }
                let wakeDisplays = Process()
                wakeDisplays.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
                wakeDisplays.arguments = ["-u", "-t", "2"]
                do { try wakeDisplays.run() }
                catch { logger.error("Display wake command failed: \(error.localizedDescription, privacy: .public)") }
            }
        }
        do { try sleepDisplays.run() }
        catch { logger.error("Display sleep command failed: \(error.localizedDescription, privacy: .public)") }
    }

    private func attempt(_ label: String, now: TimeInterval, _ operation: () throws -> Void) {
        guard now >= nextAttempt else { return }
        guard attempts < 6 else {
            if !status.hasPrefix("未能应用") { showStatus("未能应用 · 可重新选择模式再试") }
            return
        }
        attempts += 1
        nextAttempt = now + 0.65
        showStatus(label)
        do { try operation() }
        catch {
            let message = error.localizedDescription
            showStatus("未能应用：\(message)")
            logger.error("\(message, privacy: .public)")
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuildMenu() }

    private func item(_ title: String, _ action: Selector? = nil, payload: Any? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = payload
        return item
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        menu.autoenablesItems = false
        let heading = item(status)
        heading.isEnabled = false
        menu.addItem(heading)
        menu.addItem(.separator())
        let hasExternal = state.map { !$0.external.isEmpty || !disabledExternals(in: $0).isEmpty } ?? false
        for mode in modes {
            let entry = item(mode.name, #selector(choose(_:)), payload: mode.id)
            entry.state = selected == mode.id ? .on : .off
            entry.isEnabled = hasExternal && (mode.secondary != .off || system.canToggleInternal || (mode.closesInternal && state?.lidClosed == true))
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        let auto = item("恢复屏幕并交还系统管理", #selector(releaseMode))
        menu.addItem(auto)
        let config = item("配置模式")
        let submenu = NSMenu()
        for mode in modes {
            submenu.addItem(item("编辑「\(mode.name)」…", #selector(edit(_:)), payload: mode.id))
        }
        if !modes.isEmpty { submenu.addItem(.separator()) }
        submenu.addItem(item("添加模式…", #selector(add)))
        config.submenu = submenu
        menu.addItem(config)
        if #available(macOS 13.0, *) {
            let login = item("登录时启动", #selector(toggleLogin))
            login.state = SMAppService.mainApp.status == .enabled ? .on :
                          (SMAppService.mainApp.status == .requiresApproval ? .mixed : .off)
            menu.addItem(login)
        }
        menu.addItem(.separator())
        let quit = item("退出屏幕模式", #selector(quit))
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    @objc private func choose(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let latest = system.topology(), !latest.external.isEmpty || !disabledExternals(in: latest).isEmpty else { return }
        selected = id
        presence.clear()
        resetAttempts()
        updateBadge()
        reconcile()
    }

    @objc private func releaseMode() {
        selected = nil
        // An explicit recovery request may also recover a panel disabled outside this launch.
        if let current = system.topology(), current.internalID != nil, !current.internalInUse,
           !current.lidClosed {
            ownsDisable = true
        }
        resetAttempts()
        updateBadge()
        reconcile()
    }

    @objc private func add() { editMode(nil) }

    @objc private func edit(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let mode = modes.first(where: { $0.id == id }) else { return }
        editMode(mode)
    }

    private func editMode(_ existing: Mode?) {
        let alert = NSAlert()
        alert.messageText = existing == nil ? "添加模式" : "编辑模式"
        alert.informativeText = "所选主屏以外的内屏或外屏会自动成为副屏。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
        if existing != nil { alert.addButton(withTitle: "删除模式").hasDestructiveAction = true }

        let name = NSTextField(string: existing?.name ?? "")
        name.placeholderString = "例如：办公桌"
        let primary = NSPopUpButton()
        primary.addItems(withTitles: MainScreen.allCases.map(\.title))
        primary.selectItem(at: (existing?.primary ?? .internalScreen).rawValue)
        let secondary = NSPopUpButton()
        secondary.addItems(withTitles: SecondaryBehavior.allCases.map(\.title))
        secondary.selectItem(at: (existing?.secondary ?? .extended).rawValue)
        let side = NSPopUpButton()
        side.addItems(withTitles: Side.allCases.map(\.title))
        side.selectItem(at: (existing?.side ?? .right).rawValue)
        side.isEnabled = secondary.indexOfSelectedItem == SecondaryBehavior.extended.rawValue
        secondary.target = self
        secondary.action = #selector(updateSide(_:))
        secondary.cell?.representedObject = side

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "名称"), name],
            [NSTextField(labelWithString: "主屏"), primary],
            [NSTextField(labelWithString: "副屏行为"), secondary],
            [NSTextField(labelWithString: "扩展方向"), side]
        ])
        grid.rowSpacing = 9
        grid.columnSpacing = 14
        grid.column(at: 1).width = 240
        grid.column(at: 1).xPlacement = .fill
        grid.setFrameSize(grid.fittingSize)
        alert.accessoryView = grid
        alert.window.initialFirstResponder = name

        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let role = MainScreen(rawValue: primary.indexOfSelectedItem) ?? .internalScreen
            let behavior = SecondaryBehavior(rawValue: secondary.indexOfSelectedItem) ?? .extended
            let text = String(name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).prefix(48))
            var edited = Mode(text, role, behavior, Side(rawValue: side.indexOfSelectedItem) ?? .right,
                              id: existing?.id ?? UUID())
            if edited.name.isEmpty { edited.name = edited.defaultName }
            if let i = modes.firstIndex(where: { $0.id == edited.id }) { modes[i] = edited }
            else { modes.append(edited) }
        case .alertThirdButtonReturn:
            if let existing {
                modes.removeAll { $0.id == existing.id }
                if selected == existing.id { releaseMode() }
            }
        default: return
        }
        if let data = try? JSONEncoder().encode(modes) { defaults.set(data, forKey: "modes") }
        resetAttempts()
        reconcile()
    }

    @objc private func updateSide(_ sender: NSPopUpButton) {
        let side = sender.cell?.representedObject as? NSPopUpButton
        side?.isEnabled = sender.indexOfSelectedItem == SecondaryBehavior.extended.rawValue
    }

    @available(macOS 13.0, *)
    @objc private func toggleLogin() {
        do {
            switch SMAppService.mainApp.status {
            case .enabled: try SMAppService.mainApp.unregister()
            case .requiresApproval: SMAppService.openSystemSettingsLoginItems()
            default: try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert(error: error)
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func quit() {
        if let current = system.topology(), !disabledExternals(in: current).isEmpty {
            do { try system.restoreExternal(ownedExternals) }
            catch {
                releaseMode()
                let alert = NSAlert(error: error)
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
                return
            }
        }
        if ownsDisable, let current = system.topology(), !current.lidClosed, !current.internalInUse {
            do { try system.showInternal(true) }
            catch {
                let alert = NSAlert()
                alert.messageText = "还没能恢复内屏"
                alert.informativeText = "\(error.localizedDescription)。可以继续让应用恢复内屏，或退出后重新打开应用。"
                alert.addButton(withTitle: "继续恢复")
                alert.addButton(withTitle: "仍然退出")
                NSApp.activate(ignoringOtherApps: true)
                if alert.runModal() == .alertFirstButtonReturn { releaseMode(); return }
            }
        }
        NSApp.terminate(nil)
    }
}
