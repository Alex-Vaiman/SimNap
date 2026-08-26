import AppKit
import SimulatorNetworkCore
import SimulatorNetworkHostCore

private enum SnapshotResult: Sendable {
    case success([SimulatorDeviceStatus])
    case failure(String)
}

private enum Mutation: Sendable {
    case online(String)
    case offline(String, OfflineError)
}

private enum MutationResult: Sendable {
    case success
    case failure(String)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    /// One menu for the lifetime of the app, repopulated in place. Assigning a
    /// new menu to the status item while the user has it open replaces the
    /// menu out from under them.
    private let menu = NSMenu()
    private var refreshTimer: Timer?
    private var statuses: [SimulatorDeviceStatus] = []
    private var hasLoadedSnapshot = false
    private var isRefreshing = false
    private var isMutating = false
    private var refreshError: String?
    /// Bumped by every mutation, so a refresh that started earlier can tell
    /// that its snapshot is stale and drop it.
    private var refreshEpoch = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu()
        requestRefresh()
        // Keeps the status-bar icon current while the menu is closed; the menu
        // contents themselves are refreshed when it opens.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.requestRefresh()
            }
        }
    }

    /// Refreshing when the menu opens is what makes a manual "Refresh" item
    /// unnecessary: what you see is fetched because you looked at it.
    func menuWillOpen(_ menu: NSMenu) {
        requestRefresh()
    }

    private func rebuildMenu() {
        populate(menu)
        applyStatusIcon()
    }

    private func applyStatusIcon() {
        guard let button = statusItem.button else { return }
        let icon = StatusIcon.resolve(
            statuses: statuses,
            refreshError: refreshError,
            hasLoadedSnapshot: hasLoadedSnapshot
        )
        button.toolTip = icon.label
        if let image = icon.image {
            button.image = image
            button.imagePosition = .imageOnly
            button.title = ""
        } else {
            button.image = nil
            button.title = icon.fallbackTitle
        }
    }

    /// Builds a standalone menu so the same construction can be validated
    /// headlessly by `--self-check`.
    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        populate(menu)
        return menu
    }

    func populate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        // Carries the version so "which build is installed" is answered by
        // opening the menu, with nothing to click.
        let headerItem = menu.addItem(withTitle: "SimNap \(SimNapVersion.current)", action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(.separator())

        if !hasLoadedSnapshot {
            let loadingItem = menu.addItem(withTitle: "Loading Simulators…", action: nil, keyEquivalent: "")
            loadingItem.isEnabled = false
        } else if statuses.isEmpty {
            let emptyItem = menu.addItem(withTitle: "No booted Simulators", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
        }

        for entry in statuses {
            let device = entry.device
            let stateTitle: String
            if let state = entry.state {
                stateTitle = state.mode == .offline ? "Offline" : "Online"
            } else {
                stateTitle = "Status Unavailable"
            }
            let item = NSMenuItem(title: "\(device.name) — \(stateTitle)", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            if let errorDescription = entry.errorDescription {
                let errorItem = submenu.addItem(
                    withTitle: "Status error: \(errorDescription)",
                    action: nil,
                    keyEquivalent: ""
                )
                errorItem.isEnabled = false
                submenu.addItem(.separator())
            }
            submenu.addItem(actionItem(title: "Online", udid: device.udid, action: #selector(setOnline(_:))))
            submenu.addItem(actionItem(title: "Offline — Timed Out", udid: device.udid, action: #selector(setOfflineTimedOut(_:))))
            submenu.addItem(actionItem(title: "Offline — Not Connected to Internet", udid: device.udid, action: #selector(setOfflineNotConnected(_:))))
            submenu.addItem(.separator())
            submenu.addItem(actionItem(title: "Copy CLI Command", udid: device.udid, action: #selector(copyCLICommand(_:))))
            item.submenu = submenu
            menu.addItem(item)
        }

        // A failure is worth a line. A refresh in progress is not: the menu
        // refreshes because it was opened, so the line would appear on every
        // single open and change the menu's height while being read.
        if let refreshError {
            menu.addItem(.separator())
            let errorItem = menu.addItem(withTitle: "Refresh failed: \(refreshError)", action: nil, keyEquivalent: "")
            errorItem.isEnabled = false
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "About SimNap", action: #selector(showAbout), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open CLI Help", action: #selector(openCLIHelp), keyEquivalent: "").target = self
        menu.addItem(.separator())
        // Quit goes through a local selector, not NSApplication.terminate:,
        // because this delegate is the target and does not implement it.
        menu.addItem(withTitle: "Quit", action: #selector(quitApp), keyEquivalent: "q").target = self
    }

    /// Populates the snapshot with one healthy device and one whose status
    /// could not be read, so `MenuSelfCheck` can validate a fully built menu.
    func loadSelfCheckSampleStatuses() {
        statuses = [
            SimulatorDeviceStatus(
                device: SimulatorDevice(udid: "SELF-CHECK-OK", name: "Self Check OK", runtime: "iOS"),
                state: PersistedSimulatorNetworkState(generation: 1, mode: .offline, offlineError: .timedOut)
            ),
            SimulatorDeviceStatus(
                device: SimulatorDevice(udid: "SELF-CHECK-BAD", name: "Self Check Unreadable", runtime: "iOS"),
                state: nil,
                errorDescription: "sample status failure"
            )
        ]
        hasLoadedSnapshot = true
    }

    /// Targets are set per item at creation. A blanket pass over `menu.items`
    /// would also overwrite the target AppKit manages for submenu parents and
    /// for items with no action of ours.
    private func actionItem(title: String, udid: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = udid
        // Only a mutation disables these. Disabling them during a refresh
        // greyed out every toggle on each menu open, since opening triggers one.
        item.isEnabled = !isMutating
        return item
    }

    @objc private func setOnline(_ sender: NSMenuItem) {
        guard let udid = sender.representedObject as? String else { return }
        perform(.online(udid))
    }

    @objc private func setOfflineTimedOut(_ sender: NSMenuItem) {
        guard let udid = sender.representedObject as? String else { return }
        perform(.offline(udid, .timedOut))
    }

    @objc private func setOfflineNotConnected(_ sender: NSMenuItem) {
        guard let udid = sender.representedObject as? String else { return }
        perform(.offline(udid, .notConnectedToInternet))
    }

    @objc private func copyCLICommand(_ sender: NSMenuItem) {
        guard let udid = sender.representedObject as? String else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("simulator-network offline --device \(udid)", forType: .string)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "SimNap \(SimNapVersion.current)"
        alert.informativeText = """
            Simulated offline networking for iOS Simulator apps that call \
            SimulatorNetwork.start().

            The bundled CLI reports the same version:
            simulator-network --version
            """
        alert.runModal()
    }

    @objc private func openCLIHelp() {
        let alert = NSAlert()
        alert.messageText = "SimNap CLI"
        alert.informativeText = "Run `simulator-network --help` in Terminal."
        alert.runModal()
    }

    private func requestRefresh() {
        guard !isRefreshing, !isMutating else { return }
        isRefreshing = true
        refreshError = nil
        let startedAtEpoch = refreshEpoch

        let operation = Task.detached(priority: .utility) { () -> SnapshotResult in
            do {
                return .success(try SimulatorNetworkHostCore().bootedDeviceStatuses())
            } catch {
                return .failure(String(describing: error))
            }
        }
        Task { [weak self] in
            let result = await operation.value
            guard let self else { return }
            isRefreshing = false
            guard startedAtEpoch == refreshEpoch else {
                // A mutation landed while this was reading, so this snapshot
                // describes the state before it. Read again rather than
                // waiting for the timer — the mutation's own refresh was
                // refused while this one was still in flight.
                requestRefresh()
                return
            }
            switch result {
            case .success(let statuses):
                self.statuses = statuses
                hasLoadedSnapshot = true
                refreshError = nil
            case .failure(let message):
                refreshError = message
            }
            rebuildMenu()
        }
    }

    private func perform(_ mutation: Mutation) {
        guard !isMutating else { return }
        isMutating = true
        // Any refresh already in flight read state from before this mutation,
        // so its result must not be allowed to land on top of it.
        refreshEpoch += 1
        rebuildMenu()

        let operation = Task.detached(priority: .userInitiated) { () -> MutationResult in
            let host = SimulatorNetworkHostCore()
            do {
                switch mutation {
                case .online(let udid):
                    try host.setOnline(deviceUDID: udid)
                case .offline(let udid, let error):
                    try host.setOffline(deviceUDID: udid, error: error)
                }
                return .success
            } catch {
                return .failure(String(describing: error))
            }
        }
        Task { [weak self] in
            let result = await operation.value
            guard let self else { return }
            isMutating = false
            switch result {
            case .success:
                requestRefresh()
            case .failure(let message):
                rebuildMenu()
                presentError(message)
                requestRefresh()
            }
        }
    }

    private func presentError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "SimNap could not change Simulator state"
        alert.informativeText = message
        alert.runModal()
    }
}

MainActor.assumeIsolated {
    // Before the instance guard: the self-check is a short-lived validation
    // and must not be refused while a real instance is running.
    if CommandLine.arguments.contains("--self-check") {
        exit(MenuSelfCheck.run())
    }

    guard SingleInstanceGuard.acquire() else {
        FileHandle.standardError.write(Data(
            "SimNap menu bar is already running. Use the existing status-bar icon, or quit it first.\n".utf8
        ))
        exit(1)
    }

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
