#!/bin/zsh
# Start the Mac sender app. The phone app must be running (it listens on
# :9100 in Debug, :9000 in Release); USB connectivity goes through macOS's built-in usbmuxd — no tunnel
# tool needed. The Mac app retries until the device shows up.
set -e
cd "$(dirname "$0")"

if [[ $# -gt 1 || ( $# -eq 1 && "$1" != "--install-only" ) ]]; then
  echo "Usage: ./run.sh [--install-only]"
  exit 1
fi

APP="build/Build/Products/Debug/OpenDisplay Dev.app"
INSTALLED_APP="$HOME/Applications/OpenDisplay Dev.app"
if [[ ! -d "$APP" ]]; then
  echo "Mac app not built — run: xcodegen generate && xcodebuild -project OpenSidecar.xcodeproj -scheme OpenSidecarMac -configuration Debug -derivedDataPath build build"
  exit 1
fi

# With no Apple Development identity installed, Xcode signs each build ad hoc.
# Its default designated requirement is the binary's changing cdhash, which
# makes macOS forget Screen Recording after every rebuild. Give the Debug app
# one stable requirement based on its already-distinct bundle identifier.
# A real development signature is left untouched.
STABLE_REQUIREMENT='designated => identifier "com.peetzweg.opensidecar.mac.debug"'
if codesign -dv "$APP" 2>&1 | grep -q 'Signature=adhoc' \
    && ! codesign -d -r- "$APP" 2>&1 | grep -Fq "$STABLE_REQUIREMENT"; then
  codesign --force --sign - \
    --requirements "=$STABLE_REQUIREMENT" \
    --entitlements Mac/OpenSidecarMac.entitlements \
    "$APP"
  codesign --verify --deep --strict "$APP"
fi

# Launch a stable, ordinary application path, not DerivedData (which may be
# symlinked into /tmp to avoid cloud-sync metadata breaking code signing).
# Keep this installation unchanged during a permission-grant/test session.
codesign --verify --deep --strict "$APP"
# Compare symlinks as links (frameworks contain version aliases); diff -r
# follows them and can report directory loops. Checksums also catch rebuilt
# files whose size and timestamp happen to be unchanged.
INSTALL_DIFF="missing"
if [[ -d "$INSTALLED_APP" ]]; then
  INSTALL_DIFF=$(rsync -acni --delete "$APP/" "$INSTALLED_APP/")
fi
if [[ -n "$INSTALL_DIFF" ]]; then
  if pgrep -x 'OpenDisplay Dev' >/dev/null; then
    echo "Quit OpenDisplay Dev before installing a changed build."
    exit 1
  fi
  if [[ -e "$INSTALLED_APP" ]]; then
    INSTALLED_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INSTALLED_APP/Contents/Info.plist")
    if [[ "$INSTALLED_ID" != "com.peetzweg.opensidecar.mac.debug" ]]; then
      echo "Refusing to replace an unrelated app at $INSTALLED_APP"
      exit 1
    fi
  fi
  mkdir -p "$INSTALLED_APP"
  rsync -ac --delete "$APP/" "$INSTALLED_APP/"
  codesign --verify --deep --strict "$INSTALLED_APP"
fi

# Make the bundle ID resolvable by TCC even on the first local installation.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$INSTALLED_APP"

if [[ "${1:-}" == "--install-only" ]]; then
  echo "OpenDisplay Dev installed at $INSTALLED_APP"
else
  open "$INSTALLED_APP"
  echo "OpenDisplay Dev running — logs at ~/Library/Logs/OpenDisplay Dev/opendisplay.log."
fi
