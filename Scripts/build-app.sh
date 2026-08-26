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
VERSION="1.0.0"

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

log "Building $CONFIGURATION..."
(cd "$HOST_DIR" && swift build -c "$CONFIGURATION") >/dev/null
BIN_DIR="$HOST_DIR/.build/$CONFIGURATION"
[ -x "$BIN_DIR/simulator-network-menubar" ] || die "menu bar binary missing"
[ -x "$BIN_DIR/simulator-network" ] || die "CLI binary missing"

log "Assembling $APP..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# CFBundleExecutable must match this name exactly or launchd cannot start it.
cp "$BIN_DIR/simulator-network-menubar" "$APP/Contents/MacOS/SimNap"
# Bundled alongside so the app is self-contained and the CLI it points users
# to can be put on PATH from a known location.
cp "$BIN_DIR/simulator-network" "$APP/Contents/MacOS/simulator-network"

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
codesign --force --sign - --timestamp=none "$APP/Contents/MacOS/simulator-network" >/dev/null 2>&1
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

EXECUTABLE_NAME=$(plist_value CFBundleExecutable)
[ -x "$APP/Contents/MacOS/$EXECUTABLE_NAME" ] \
  || die "CFBundleExecutable '$EXECUTABLE_NAME' does not exist in Contents/MacOS"

codesign --verify --strict "$APP" || die "signature does not verify"

# The decisive check: the bundled binary must actually run, with an empty
# environment, the way launchd starts a Finder-launched app.
env -i "$APP/Contents/MacOS/$EXECUTABLE_NAME" --self-check >/dev/null \
  || die "bundled executable failed its self-check under an empty environment"
env -i "$APP/Contents/MacOS/simulator-network" devices >/dev/null \
  || die "bundled CLI could not reach simctl under an empty environment"

log "Bundle OK: $APP"

if [ -n "$INSTALL_DIR" ]; then
  DEST="$INSTALL_DIR/SimNap.app"
  log "Installing to $DEST..."
  pkill -f "$DEST/Contents/MacOS/SimNap" 2>/dev/null || true
  rm -rf "$DEST"
  mkdir -p "$INSTALL_DIR"
  cp -R "$APP" "$DEST"
  log "Installed. Launch it from Spotlight or: open -a SimNap"
else
  log "Not installed. Re-run with --install (or --install-to <dir>)."
fi

echo
echo "To put the CLI on PATH:"
echo "  ln -sf \"${INSTALL_DIR:-$BUILD_DIR}/SimNap.app/Contents/MacOS/simulator-network\" /usr/local/bin/simulator-network"
