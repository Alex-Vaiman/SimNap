# SimNap

Deterministic application-level HTTP/HTTPS network control for cooperating
iOS Simulator apps. Flip a booted Simulator offline/online from a CLI or
menu bar, and every integrated app on that Simulator reacts immediately —
including apps that were killed while offline and just cold-launched.

## What it actually controls

SimNap gates traffic at the URL Loading System, per Simulator UDID:

- **Guaranteed:** `URLSession` (and Alamofire `Session`) instances built from
  a `SimulatorNetwork`-integrated `URLSessionConfiguration`. New HTTP/HTTPS
  requests started while offline fail with the selected simulated error.
- **Already in flight:** requests admitted while online remain owned by their
  original session and are not cancelled by a later offline transition.
- **Not controlled:** `URLSession.shared` — it is built internally and never
  goes through the intercepted class methods, so `start()` does not reach it;
  raw BSD sockets; `Network.framework`; third-party stacks that bypass the
  URL Loading System; configurations obtained before `start()`; and anything
  on a physical device (SimNap is a documented pass-through there — no
  observers, no swizzling, no blocking).

This simulates network failure at the app's transport boundary, not at the
Mac's firewall. It does not touch CoreSimulator routing, host network
interfaces, or unintegrated apps.

## Repository layout

Two independent Swift packages, kept apart on purpose: the root package is
the only thing an iOS app adds as a dependency, and it stays free of any
macOS-only code.

- **`Package.swift`** (root) — `SimulatorNetworkCore`, the iOS-side library
  (Foundation only). Owns runtime lifecycle, state reconciliation, the
  offline-only `URLProtocol` interceptor. This is the product
  you add to an app: `.package(url: ".../SimNap", ...)`.
- **`Host/Package.swift`** — macOS-only tooling, built and run separately
  (`cd Host && swift build`). Depends on the root package locally for the
  shared model types.
  - `SimulatorNetworkHostCore` — Simulator discovery, per-Simulator
    locking, persisted-state read/write, the Darwin wake-up.
  - `simulator-network` — the CLI.
  - `simulator-network-menubar` — an optional macOS status-bar app.
- **`Demo/SimNapDemo`** — a throwaway iOS app exercising the root package
  end to end. References the root package locally, same as any consumer
  would via a remote SPM dependency.
- **`Scripts/e2e.sh`** — automated end-to-end test suite driving real CLI
  processes and real Simulators (see below).

## Integrating into an app

One line, as early in launch as you can put it:

```swift
import SimulatorNetworkCore

SimulatorNetwork.start()
```

`start()` reconciles persisted Simulator state and, on the Simulator only,
makes `URLSessionConfiguration.default` and `.ephemeral` hand out
configurations that already carry the offline interceptor. Any `URLSession`
or Alamofire `Session` your app builds from those afterwards is gated, with
no further integration. `stop()` hands Foundation back.

Order is the one thing that matters: a configuration obtained *before*
`start()` was already copied and cannot be reached, so start early.

For a session you want gated regardless of ordering, or one built from a
configuration you constructed yourself, integrate it explicitly:

```swift
let configuration = SimulatorNetwork.configuration(from: .default)
let session = URLSession(configuration: configuration)
```

This is the guaranteed path and is unaffected by `start()`.

```swift
for await state in SimulatorNetwork.states {
    // .online or .offline(.timedOut | .notConnectedToInternet)
}
```

State observation is for UI only — transport enforcement happens inside the
package regardless of whether anything observes `states`.

## CLI

```bash
cd Host
swift build
.build/debug/simulator-network devices
.build/debug/simulator-network offline --device <UDID> --error timedOut
.build/debug/simulator-network online  --device <UDID>
.build/debug/simulator-network status  --device <UDID> --json
```

`offline`/`online`/`status` all require an explicit `--device` UDID — SimNap
never guesses "the first booted Simulator." State is per-Simulator: two
booted Simulators can hold different states at once, and every cooperating
app inside one Simulator shares that Simulator's state.

`offline` and `online` report the record they wrote, captured inside the
writer lock, rather than re-reading afterwards — a re-read can return another
command's write. Their `--json` output carries a `changed` field, false when
the requested state was already applied and nothing was written.

## Menu bar app

Run it from a checkout:

```bash
cd Host
swift run simulator-network-menubar
```

Or install it as a normal macOS application:

```bash
./Scripts/build-app.sh --install
```

That assembles `SimNap.app` (a `LSUIElement` accessory — status bar only, no
Dock icon), ad-hoc signs it, validates the bundle, and copies it to
`/Applications`, after which it launches from Spotlight like any other app.
Without `--install` it only builds into `Release/` (git-ignored). The CLI is bundled
inside at `Contents/MacOS/simulator-network`; the script prints the `ln -s`
to put it on your `PATH`.

A checkout run and an installed copy exclude each other — the instance lock
lives under `~/Library/Caches`, not in `TMPDIR`, which is launch-context
dependent.

Convenience UI over the same `SimulatorNetworkHostCore` the CLI uses — lists
booted Simulators, lets you toggle each online/offline, and copies the
equivalent CLI command. Not required for anything; the CLI and the package
are fully functional without it.

There is no manual "Refresh" item: the menu refreshes when you open it, and
a timer keeps the status-bar icon current while it is closed. Only one
instance runs at a time — a second launch exits with a message rather than
adding a second, indistinguishable status item.

The status-bar icon is an SF Symbol with one glyph per aggregate state:
`network` when every booted Simulator is online, `network.slash` when at
least one is simulated offline, and `questionmark.circle` while the status is
unknown. The `wifi` family is deliberately avoided — the system's own network
indicator uses it, and sharing the shape made SimNap read as a second system
indicator. Tinting cannot separate them, since a template image is recoloured
by the menu bar by definition.

An unknown status is never shown as a confident "all online" — that includes
the second or two after every launch, before the first snapshot returns. The
tooltip spells the state out.

## Demo app

`Demo/SimNapDemo.xcodeproj` is a one-screen iOS app: a live state badge, a
quick request button, and a 6-second delayed request button for comparing a
request admitted online with new requests started after an offline transition.
It references `SimulatorNetworkCore` as a local
Swift package (`../`).

```bash
xcodebuild -project Demo/SimNapDemo.xcodeproj -scheme SimNapDemo \
  -destination 'platform=iOS Simulator,id=<UDID>' build
```

## Verification

```bash
./Scripts/verify.sh
```

Builds the root package, the Host package, and the demo app for real, then
drives real `simctl`/CLI processes against a real booted Simulator — no
mocks. It boots a second, disposable Simulator for the isolation check and
deletes it afterward. Requires exactly one Simulator already booted and `jq`
installed.

Covers:

- CLI behavior, generation ordering, idempotent re-application, corrupt-record
  repair, and a running app accepting a new record epoch.
- The cold-launch guarantee and both simulated error modes.
- `stop()` leaving pass-through, and an explicit `start()` re-applying the
  persisted record.
- Header, redirect, and **POST body** round-trips while online. The body check
  is the one that fails loudest if anything ever proxies online traffic again:
  a dropped body still returns HTTP 200, so status alone proves nothing.
- The documented boundary — already-running requests, unintegrated
  `URLSession`, and raw `Network.framework` traffic staying unaffected.
- Per-Simulator isolation.
- The per-Simulator writer lock under a concurrent command burst. Each
  command reports the record it wrote inside the lock, so the assertions are
  exact: every writing command owns a distinct generation, and the record
  advances by exactly one per writing command. Verified to fail with the lock
  disabled, where eight commands lost seven updates.
- A headless menu self-check (`simulator-network-menubar --self-check`)
  asserting every actionable menu item has a target that responds to its
  action, that submenu parents are left to AppKit, that automatic enabling
  stays off, and that repopulating the menu in place is idempotent. A menu is
  otherwise only exercised by clicking it, so a mis-targeted item raises
  `unrecognized selector` in the user's face and nothing catches it. The same
  check covers the status icon: every symbol resolves (an unresolved one
  renders an empty, invisible status item), no two states share a symbol, and
  the state mapping is asserted case by case.
- The menu bar single-instance lock: a second launch is refused, the
  self-check still runs alongside a live instance, and the lock is released
  when the app exits.
- The application bundle: `Info.plist` keys including `LSUIElement`,
  `CFBundleExecutable` naming a file that exists, the ad-hoc signature, and
  both bundled binaries running under an empty environment the way launchd
  starts a Finder-launched app. Plus that the lock directory is outside
  `TMPDIR`, so every launch context shares one lock.

The demo app's `ScenarioRunner` (`Demo/SimNapDemo/ScenarioRunner.swift`) is
what makes this possible headlessly: set `SIMNAP_SCENARIO` in its
environment and a fresh process run of the app executes that scenario,
prints one `SIMNAP_RESULT {...}` JSON line, and exits — no UI automation or
tap coordinates involved.

## How it works

- Persisted state lives in one JSON record under a package-owned key in the
  target Simulator's global defaults domain, written via
  `simctl spawn <udid> defaults write NSGlobalDomain ...`. This is
  Simulator-only host-tooling plumbing — not a production storage contract.
- A Darwin notification (posted via `simctl notify_post <udid> <name>`, not
  `simctl spawn ... notifyutil` — the latter silently fails to reach the
  Simulator's notifyd on some Xcode/macOS combinations) wakes up already
  running cooperating processes to re-read that record. The notification
  carries no state itself; a missed, duplicated, or reordered one is
  harmless because every reconciliation re-reads the persisted record and a
  monotonic generation number rejects stale reads within one record epoch.
  Recreating or repairing the record assigns a new epoch, so a running app
  accepts its generation even when numbering starts again at one.
- While online, the custom `URLProtocol` declines every request and the
  original URL loading system remains fully responsible for it. While
  offline, the protocol claims new HTTP/HTTPS requests and immediately fails
  them with the configured `URLError`; requests admitted earlier keep running.
