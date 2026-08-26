#!/usr/bin/env bash
# Assembles SimNap.app — a normal macOS application bundle for the menu bar
# app — and validates it. The product lands in Release/ inside the repo
# (git-ignored); pass --install to also copy it into /Applications.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST_DIR="$ROOT/Host"
BUILD_DIR="$ROOT/Release"
APP="$BUILD_DIR/SimNap.app"
CONFIGURATION="release"
INSTALL_DIR=""
VERSION_SOURCE="$ROOT/Host/Sources/SimulatorNetworkHostCore/SimNapVersion.swift"
VERSION=$(sed -n 's/.*static let current = "\(.*\)".*/\1/p' "$VERSION_SOURCE")

while [ $# -gt 0 ]; do
  case "$1" in
    --debug)   CONFIGURATION="debug" ;;
    --install) INSTALL_DIR="/Applications" ;;
    --install-to) INSTALL_DIR="${2:?--install-to needs a directory}"; shift ;;
    -h|--help)
      echo "usage: $(basename "$0") [--debug] [--install | --install-to <dir>]"
      exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

log() { echo "[build-app] $*"; }
die() { echo "[build-app] FAILED: $*" >&2; exit 1; }

[ -n "$VERSION" ] || die "could not read the version from $VERSION_SOURCE"
log "Version $VERSION"

log "Building $CONFIGURATION..."
(cd "$HOST_DIR" && swift build -c "$CONFIGURATION") >/dev/null
BIN_DIR="$HOST_DIR/.build/$CONFIGURATION"
[ -x "$BIN_DIR/simulator-network-menubar" ] || die "menu bar binary missing"
[ -x "$BIN_DIR/simnap" ] || die "CLI binary missing"

log "Assembling $APP..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# CFBundleExecutable must match this name exactly or launchd cannot start it.
cp "$BIN_DIR/simulator-network-menubar" "$APP/Contents/MacOS/SimNap"
# Bundled alongside so the app is self-contained and the CLI can be linked
# onto PATH from a known location.
#
# Deliberately NOT named "simnap": macOS filesystems are case-insensitive by
# default, so it would be the same file as the "SimNap" app executable above.
# One would overwrite the other and the symlink on PATH would resolve to the
# menu bar app. The name on PATH comes from the symlink, not from this file.
cp "$BIN_DIR/simnap" "$APP/Contents/MacOS/simnap-cli"

# Committed rather than generated here, so building does not depend on
# re-rendering it. Regenerate with: swift Scripts/make-icon.swift
ICON_SOURCE="$ROOT/Resources/AppIcon.icns"
[ -f "$ICON_SOURCE" ] || die "Resources/AppIcon.icns is missing"
cp "$ICON_SOURCE" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleDisplayName</key><string>SimNap</string>
    <key>CFBundleExecutable</key><string>SimNap</string>
    <key>CFBundleIdentifier</key><string>com.simnap.menubar</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleName</key><string>SimNap</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>12.0</string>
    <!-- Menu bar accessory: no Dock icon, no window on launch. -->
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature. Unsigned bundles are refused outright on Apple silicon.
# Nested binaries are signed before the bundle; --deep is deprecated.
log "Signing (ad-hoc)..."
codesign --force --sign - --timestamp=none "$APP/Contents/MacOS/simnap-cli" >/dev/null 2>&1
codesign --force --sign - --timestamp=none "$APP/Contents/MacOS/SimNap" >/dev/null 2>&1
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1

# ---------------------------------------------------------------------------
# Validate the bundle rather than trusting that it assembled correctly.
# ---------------------------------------------------------------------------
log "Validating..."
plutil -lint "$APP/Contents/Info.plist" >/dev/null || die "Info.plist is malformed"

plist_value() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist" 2>/dev/null; }
[ "$(plist_value CFBundleIdentifier)" = "com.simnap.menubar" ] || die "wrong CFBundleIdentifier"
[ "$(plist_value CFBundlePackageType)" = "APPL" ] || die "wrong CFBundlePackageType"
# Without LSUIElement the app takes a Dock icon and a menu bar of its own,
# which is wrong for a status-bar accessory.
[ "$(plist_value LSUIElement)" = "true" ] || die "LSUIElement is not set"

# Without a resolvable icon the app shows the generic placeholder in Finder
# and the Dock, which looks like a broken install.
[ "$(plist_value CFBundleIconFile)" = "AppIcon" ] || die "CFBundleIconFile is not set"
[ -f "$APP/Contents/Resources/AppIcon.icns" ] || die "AppIcon.icns is not in the bundle"

# The bundle, the CLI and the menu must all report the same version.
[ "$(plist_value CFBundleShortVersionString)" = "$VERSION" ] || die "bundle version does not match $VERSION_SOURCE"
[ "$("$APP/Contents/MacOS/simnap-cli" --version)" = "$VERSION" ] \
  || die "the CLI reports a different version from the bundle"

# Case-insensitively equal names inside Contents/MacOS silently collapse into
# one file on a default macOS volume.
if [ "$(ls "$APP/Contents/MacOS" | tr 'A-Z' 'a-z' | sort | uniq -d)" != "" ]; then
  die "two executables in Contents/MacOS differ only by case"
fi

EXECUTABLE_NAME=$(plist_value CFBundleExecutable)
[ -x "$APP/Contents/MacOS/$EXECUTABLE_NAME" ] \
  || die "CFBundleExecutable '$EXECUTABLE_NAME' does not exist in Contents/MacOS"

codesign --verify --strict "$APP" || die "signature does not verify"

# The decisive check: the bundled binary must actually run, with an empty
# environment, the way launchd starts a Finder-launched app.
env -i "$APP/Contents/MacOS/$EXECUTABLE_NAME" --self-check >/dev/null \
  || die "bundled executable failed its self-check under an empty environment"
env -i "$APP/Contents/MacOS/simnap-cli" devices >/dev/null \
  || die "bundled CLI could not reach simctl under an empty environment"

log "Bundle OK: $APP"

if [ -n "$INSTALL_DIR" ]; then
  DEST="$INSTALL_DIR/SimNap.app"
  log "Installing to $DEST..."
  # pkill only sends the signal. Replacing the bundle before the process has
  # actually gone leaves the old build running against a deleted bundle, and a
  # survivor keeps the single-instance lock so the new copy refuses to launch.
  WAS_RUNNING=0
  if pgrep -f "$DEST/Contents/MacOS/SimNap" >/dev/null 2>&1; then
    WAS_RUNNING=1
    log "Stopping the running copy..."
    pkill -f "$DEST/Contents/MacOS/SimNap" 2>/dev/null || true
    for _ in $(seq 1 20); do
      pgrep -f "$DEST/Contents/MacOS/SimNap" >/dev/null 2>&1 || break
      sleep 0.25
    done
    if pgrep -f "$DEST/Contents/MacOS/SimNap" >/dev/null 2>&1; then
      pkill -9 -f "$DEST/Contents/MacOS/SimNap" 2>/dev/null || true
      sleep 0.5
    fi
    pgrep -f "$DEST/Contents/MacOS/SimNap" >/dev/null 2>&1 \
      && die "the running copy would not exit; quit SimNap and re-run"
  fi

  rm -rf "$DEST"
  mkdir -p "$INSTALL_DIR"
  cp -R "$APP" "$DEST"
  log "Installed."

  # A dev instance from a checkout holds the same lock. Say so rather than
  # letting the relaunch fail for a reason that looks unrelated.
  if pgrep -f "simulator-network-menubar" >/dev/null 2>&1; then
    log "Another SimNap instance is running from a checkout; quit it to use this one."
  elif [ "$WAS_RUNNING" -eq 1 ]; then
    # It was running before, so put it back rather than leaving the menu bar
    # empty and the update looking like it did nothing.
    open -a "$DEST" && sleep 2
    if pgrep -f "$DEST/Contents/MacOS/SimNap" >/dev/null 2>&1; then
      log "Relaunched SimNap $VERSION"
    else
      log "Installed, but SimNap did not relaunch; open it from Spotlight."
    fi
  else
    log "Launch it from Spotlight or: open -a SimNap"
  fi

  # Actually put the CLI on PATH. Printing the command is not installing it.
  # Uses the first writable directory already on PATH, so this needs no sudo
  # and changes nothing about the user's shell configuration.
  CLI_TARGET="$DEST/Contents/MacOS/simnap-cli"
  CLI_LINK=""
  IFS=':' read -r -a PATH_PARTS <<< "$PATH"
  for candidate in "${PATH_PARTS[@]}"; do
    [ -d "$candidate" ] && [ -w "$candidate" ] || continue
    CLI_LINK="$candidate/simnap"
    break
  done

  if [ -n "$CLI_LINK" ]; then
    ln -sf "$CLI_TARGET" "$CLI_LINK"
    [ "$("$CLI_LINK" --version)" = "$VERSION" ] || die "the CLI installed at $CLI_LINK does not run"
    log "CLI installed: $CLI_LINK -> simnap $VERSION"
  else
    log "No writable directory on PATH. Install the CLI with:"
    log "  sudo ln -sf \"$CLI_TARGET\" /usr/local/bin/simnap"
  fi
else
  log "Not installed. Re-run with --install (or --install-to <dir>)."
fi
