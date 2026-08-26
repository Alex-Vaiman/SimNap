import AppKit
import SimulatorNetworkCore
import SimulatorNetworkHostCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let host = SimulatorNetworkHostCore()
    private var refreshTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.title = "SimNap"
        rebuildMenu()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.rebuildMenu()
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "SimNap", action: nil, keyEquivalent: "")
        menu.addItem(.separator())

        let devices = (try? host.bootedDevices()) ?? []
        var anyOffline = false

        if devices.isEmpty {
            menu.addItem(withTitle: "No booted Simulators", action: nil, keyEquivalent: "")
        }

        for device in devices {
            let status = (try? host.status(for: device.udid)) ?? .initial
            if status.mode == .offline { anyOffline = true }

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
        return item
    }

    @objc private func setOnline(_ sender: NSMenuItem) {
        guard let udid = sender.representedObject as? String else { return }
        try? host.setOnline(deviceUDID: udid)
        rebuildMenu()
    }

    @objc private func setOfflineTimedOut(_ sender: NSMenuItem) {
        guard let udid = sender.representedObject as? String else { return }
        try? host.setOffline(deviceUDID: udid, error: .timedOut)
        rebuildMenu()
    }

    @objc private func setOfflineNotConnected(_ sender: NSMenuItem) {
        guard let udid = sender.representedObject as? String else { return }
        try? host.setOffline(deviceUDID: udid, error: .notConnectedToInternet)
        rebuildMenu()
    }

    @objc private func copyCLICommand(_ sender: NSMenuItem) {
        guard let udid = sender.representedObject as? String else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("simulator-network offline --device \(udid)", forType: .string)
    }

    @objc private func refresh() {
        rebuildMenu()
    }

    @objc private func openCLIHelp() {
        let alert = NSAlert()
        alert.messageText = "SimNap CLI"
        alert.informativeText = "Run `simulator-network --help` in Terminal."
        alert.runModal()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
