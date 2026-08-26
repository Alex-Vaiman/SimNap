# SimNap

Deterministic application-level HTTP/HTTPS network control for cooperating
iOS Simulator apps. Flip a booted Simulator offline/online from a CLI or
menu bar, and every integrated app on that Simulator reacts immediately —
including apps that were killed while offline and just cold-launched.

## What it actually controls

SimNap gates traffic at the URL Loading System, per Simulator UDID:

- **Guaranteed:** `URLSession` (and Alamofire `Session`) instances built from
  a `SimulatorNetwork`-integrated `URLSessionConfiguration`, including
  requests already in flight and new requests started while offline.
- **Not controlled:** raw BSD sockets, `Network.framework`, third-party
  stacks that bypass the URL Loading System, unintegrated `URLSession`
  instances, and anything on a physical device (SimNap is a documented
  pass-through there — no observers, no blocking).

This simulates network failure at the app's transport boundary, not at the
Mac's firewall. It does not touch CoreSimulator routing, host network
interfaces, or unintegrated apps.

## Repository layout

Two independent Swift packages, kept apart on purpose: the root package is
the only thing an iOS app adds as a dependency, and it stays free of any
macOS-only code.

- **`Package.swift`** (root) — `SimulatorNetworkCore`, the iOS-side library
  (Foundation only). Owns runtime lifecycle, state reconciliation, the
  proxy `URLProtocol`, and the active-request registry. This is the product
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

```swift
import SimulatorNetworkCore

let configuration = SimulatorNetwork.configuration(from: .default)
let session = URLSession(configuration: configuration)
```

That's it — it starts the runtime, reconciles persisted Simulator state, and
returns a configuration with the proxy protocol installed first. Optionally
call `SimulatorNetwork.start()` earlier in app startup to bootstrap before
your networking layer exists.

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

## Menu bar app

```bash
cd Host
swift run simulator-network-menubar
```

Convenience UI over the same `SimulatorNetworkHostCore` the CLI uses — lists
booted Simulators, lets you toggle each online/offline, and copies the
equivalent CLI command. Not required for anything; the CLI and the package
are fully functional without it.

## Demo app

`Demo/SimNapDemo.xcodeproj` is a one-screen iOS app: a live state badge, a
quick request button, and a 6-second delayed request button for watching
in-flight cancellation happen when you flip the Simulator offline mid-request
from the CLI or menu bar. It references `SimulatorNetworkCore` as a local
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
deletes it afterward. Covers: CLI behavior and generation ordering, the cold
launch guarantee, request/header/redirect forwarding, exactly-once in-flight
cancellation, the documented boundary (unintegrated `URLSession` and raw
`Network.framework` traffic staying unaffected), per-Simulator isolation,
and a menu bar crash smoke test. Requires exactly one Simulator already
booted and `jq` installed.

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
  monotonic per-Simulator generation number rejects stale reads.
- On an offline transition, the runtime flips its transport gate before
  cancelling anything, snapshots every active proxied request, and fails
  each one exactly once with the configured `URLError`.
