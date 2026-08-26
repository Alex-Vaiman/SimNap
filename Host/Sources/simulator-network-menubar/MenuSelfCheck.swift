import AppKit
import SimulatorNetworkCore
import SimulatorNetworkHostCore

/// Headless validation of the status-bar menu, run via `--self-check`.
///
/// Exists because a menu is otherwise only exercised by clicking it. With
/// `autoenablesItems = false` AppKit no longer disables an item whose target
/// cannot handle its action, so such an item becomes clickable and raises
/// `unrecognized selector` at click time — invisible to a build and to a
/// process-liveness smoke test.
@MainActor
enum MenuSelfCheck {
    static func run() -> Int32 {
        var failures: [String] = []
        var checked = 0

        let delegate = AppDelegate()

        // The initial "loading" menu first, then a populated one, so items that
        // only appear once devices are known are covered too.
        validate(menu: delegate.buildMenu(), path: "initial", failures: &failures, checked: &checked)
        delegate.loadSelfCheckSampleStatuses()
        validate(menu: delegate.buildMenu(), path: "populated", failures: &failures, checked: &checked)

        // The live menu is repopulated in place on every refresh rather than
        // replaced, so repopulating the same menu must be idempotent — a
        // missing removeAllItems would silently append duplicates each cycle.
        let reused = NSMenu()
        delegate.populate(reused)
        let firstPassCount = reused.numberOfItems
        delegate.populate(reused)
        delegate.populate(reused)
        if reused.numberOfItems != firstPassCount {
            failures.append(
                "repopulating a menu in place is not idempotent: \(firstPassCount) items became \(reused.numberOfItems)"
            )
        }
        validate(menu: reused, path: "repopulated", failures: &failures, checked: &checked)

        validateStatusIcons(failures: &failures, checked: &checked)

        if failures.isEmpty {
            print("menu self-check: \(checked) items OK")
            return 0
        }
        for failure in failures {
            print("menu self-check FAILED: \(failure)")
        }
        return 1
    }

    private static func validateStatusIcons(failures: inout [String], checked: inout Int) {
        var symbolsSeen: [String: StatusIcon] = [:]

        for icon in StatusIcon.allCases {
            checked += 1

            // A name that does not resolve yields no image, and a status item
            // with no image and no title is invisible — indistinguishable from
            // the app having failed to launch.
            if icon.image == nil {
                failures.append(
                    "status icon \(icon): SF Symbol '\(icon.symbolName)' did not resolve, the status item would render empty"
                )
            }

            if let clash = symbolsSeen[icon.symbolName] {
                failures.append(
                    "status icon \(icon) reuses symbol '\(icon.symbolName)' from \(clash); the states would look identical"
                )
            }
            symbolsSeen[icon.symbolName] = icon
        }

        // The mapping itself: an unreadable status must not be reported as a
        // confident "all online".
        let online = SimulatorDeviceStatus(
            device: SimulatorDevice(udid: "A", name: "A", runtime: "iOS"),
            state: PersistedSimulatorNetworkState(generation: 1, mode: .online, offlineError: .timedOut)
        )
        let offline = SimulatorDeviceStatus(
            device: SimulatorDevice(udid: "B", name: "B", runtime: "iOS"),
            state: PersistedSimulatorNetworkState(generation: 1, mode: .offline, offlineError: .timedOut)
        )
        let unreadable = SimulatorDeviceStatus(
            device: SimulatorDevice(udid: "C", name: "C", runtime: "iOS"),
            state: nil,
            errorDescription: "unreadable"
        )

        let cases: [(String, [SimulatorDeviceStatus], String?, StatusIcon)] = [
            ("no devices", [], nil, .neutral),
            ("all online", [online], nil, .neutral),
            ("one offline", [online, offline], nil, .offline),
            ("unreadable status", [online, unreadable], nil, .warning),
            ("refresh failed", [online], "boom", .warning),
            ("offline plus unreadable", [offline, unreadable], nil, .warning)
        ]

        for (name, statuses, refreshError, expected) in cases {
            checked += 1
            let actual = StatusIcon.resolve(statuses: statuses, refreshError: refreshError)
            if actual != expected {
                failures.append("status icon for '\(name)': expected \(expected), got \(actual)")
            }
        }
    }

    private static func validate(menu: NSMenu, path: String, failures: inout [String], checked: inout Int) {
        if menu.autoenablesItems {
            failures.append("\(path): autoenablesItems is true, so explicit isEnabled values are overridden by AppKit")
        }

        for item in menu.items {
            checked += 1
            let itemPath = "\(path) > \(item.isSeparatorItem ? "<separator>" : item.title)"

            // AppKit owns submenu parents: it assigns them `submenuAction:`
            // against the parent menu and dispatches it internally, so
            // `responds(to:)` says nothing useful. The invariant that does
            // hold is that we must not have retargeted them — pointing one at
            // the delegate is exactly the defect a blanket target assignment
            // reintroduces, and exempting them outright would hide it.
            if item.submenu != nil {
                if let target = item.target, !(target is NSMenu) {
                    failures.append(
                        "\(itemPath): submenu parent was retargeted at \(type(of: target)); leave it to AppKit"
                    )
                }
            }

            if let action = item.action, item.submenu == nil {
                guard let target = item.target else {
                    // A nil target routes through the responder chain, which a
                    // status-bar accessory app has no reliable path for.
                    failures.append("\(itemPath): action \(action) has no target")
                    continue
                }
                if !target.responds(to: action) {
                    failures.append("\(itemPath): target \(type(of: target)) does not respond to \(action)")
                }
            }

            if let submenu = item.submenu {
                validate(menu: submenu, path: itemPath, failures: &failures, checked: &checked)
            }
        }
    }
}
