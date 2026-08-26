import AppKit

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

        if failures.isEmpty {
            print("menu self-check: \(checked) items OK")
            return 0
        }
        for failure in failures {
            print("menu self-check FAILED: \(failure)")
        }
        return 1
    }

    private static func validate(menu: NSMenu, path: String, failures: inout [String], checked: inout Int) {
        if menu.autoenablesItems {
            failures.append("\(path): autoenablesItems is true, so explicit isEnabled values are overridden by AppKit")
        }

        for item in menu.items {
            checked += 1
            let itemPath = "\(path) > \(item.isSeparatorItem ? "<separator>" : item.title)"

            // Items that own a submenu are excluded: AppKit assigns them
            // `submenuAction:` against the parent menu and dispatches it
            // internally, so `responds(to:)` is not meaningful there.
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
