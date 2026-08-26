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
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var refreshTimer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var mutationTask: Task<Void, Never>?
    private var statuses: [SimulatorDeviceStatus] = []
    private var hasLoadedSnapshot = false
    private var isRefreshing = false
    private var isMutating = false
    private var refreshError: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "SimNap"
        rebuildMenu()
        requestRefresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.requestRefresh()
            }
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "SimNap", action: nil, keyEquivalent: "")
        menu.addItem(.separator())

        let anyOffline = statuses.contains { $0.state.mode == .offline }

        if !hasLoadedSnapshot {
            menu.addItem(withTitle: "Loading Simulators…", action: nil, keyEquivalent: "")
        } else if statuses.isEmpty {
            menu.addItem(withTitle: "No booted Simulators", action: nil, keyEquivalent: "")
        }

        for entry in statuses {
            let device = entry.device
            let status = entry.state
            let item = NSMenuItem(title: "\(device.name) — \(status.mode == .offline ? "Offline" : "Online")", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.addItem(actionItem(title: "Online", udid: device.udid, action: #selector(setOnline(_:))))
            submenu.addItem(actionItem(title: "Offline — Timed Out", udid: device.udid, action: #selector(setOfflineTimedOut(_:))))
            submenu.addItem(actionItem(title: "Offline — Not Connected to Internet", udid: device.udid, action: #selector(setOfflineNotConnected(_:))))
            submenu.addItem(.separator())
            submenu.addItem(actionItem(title: "Copy CLI Command", udid: device.udid, action: #selector(copyCLICommand(_:))))
            item.submenu = submenu
            menu.addItem(item)
        }

        if let refreshError {
            menu.addItem(.separator())
            let errorItem = menu.addItem(withTitle: "Refresh failed: \(refreshError)", action: nil, keyEquivalent: "")
            errorItem.isEnabled = false
        } else if isRefreshing {
            menu.addItem(.separator())
            let refreshingItem = menu.addItem(withTitle: "Refreshing…", action: nil, keyEquivalent: "")
            refreshingItem.isEnabled = false
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "Refresh", action: #selector(refresh), keyEquivalent: "r")
        menu.addItem(withTitle: "Open CLI Help", action: #selector(openCLIHelp), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        for item in menu.items {
            item.target = self
            item.submenu?.items.forEach { $0.target = self }
        }

        statusItem.button?.title = anyOffline ? "SimNap ⚠︎" : "SimNap"
        statusItem.menu = menu
    }

    private func actionItem(title: String, udid: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.representedObject = udid
        item.isEnabled = !isMutating && !isRefreshing
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

    @objc private func refresh() {
        requestRefresh()
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
        rebuildMenu()

        let operation = Task.detached(priority: .utility) { () -> SnapshotResult in
            do {
                return .success(try SimulatorNetworkHostCore().bootedDeviceStatuses())
            } catch {
                return .failure(String(describing: error))
            }
        }
        refreshTask = Task { [weak self] in
            let result = await operation.value
            guard !Task.isCancelled, let self else { return }
            isRefreshing = false
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
        guard !isMutating, !isRefreshing else { return }
        isMutating = true
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
        mutationTask = Task { [weak self] in
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
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
