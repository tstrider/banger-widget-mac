#!/bin/zsh
# install.sh — build Banger and put it where macOS will keep it running.
#
#   ./tools/install.sh              build Release, install to /Applications, launch
#   ./tools/install.sh --no-launch  install but do not start it
#   ./tools/install.sh --uninstall  quit it, remove it, leave tasks.json alone
#
# Written to be run by someone who does not read Swift. It prints what it is doing and
# tells you the one thing you have to do by hand at the end (drag the widget onto the
# desktop — macOS gives no way to do that from a script).

set -euo pipefail
SELFDIR="${0:A:h}"
source "$SELFDIR/env.sh"
ROOT="${SELFDIR:h}"
APP="/Applications/Banger.app"
DATA="$HOME/Library/Application Support/Banger"
# First entry on the user's PATH, and writable without sudo — unlike /usr/local/bin.
BINDIR="$HOME/.local/bin"

quit_running () {
  if pgrep -x Banger >/dev/null 2>&1; then
    print "Quitting the running copy..."
    pkill -x Banger || true
    for i in {1..20}; do pgrep -x Banger >/dev/null 2>&1 || break; sleep 0.25; done
    pgrep -x Banger >/dev/null 2>&1 && pkill -9 -x Banger || true
  fi
  # The widget extension is its own process and outlives the app. Left running, the
  # desktop keeps drawing the OLD widget code after an install. macOS relaunches it
  # from the new copy the next time the widget draws.
  pkill -f "Banger.app/Contents/PlugIns/BangerWidget.appex" || true
}

if [[ "${1:-}" == "--uninstall" ]]; then
  quit_running
  [[ -d "$APP" ]] && rm -rf "$APP" && print "Removed $APP"
  [[ -e "$BINDIR/bangerctl" ]] && rm -f "$BINDIR/bangerctl" && print "Removed $BINDIR/bangerctl"
  print "Your tasks are still at $DATA/tasks.json — delete that yourself if you want them gone."
  exit 0
fi

print "Building Banger (Release). This takes a minute or two the first time."
cd "$ROOT"
"$XCODEGEN" generate --spec "$ROOT/project.yml" --project "$ROOT" >/dev/null

# NOT inside $ROOT: ~/Documents is file-provider managed and stamps
# com.apple.FinderInfo on the widget bundle, which codesign then refuses to sign.
DERIVED="$BANGER_DD_ROOT/release"
xcodebuild -project "$ROOT/Banger.xcodeproj" -scheme Banger \
  -configuration Release -destination "$BANGER_DESTINATION" \
  -derivedDataPath "$DERIVED" \
  -quiet build

# The command-line tool is a separate scheme; the app scheme does not build it.
xcodebuild -project "$ROOT/Banger.xcodeproj" -scheme bangerctl \
  -configuration Release -destination "$BANGER_DESTINATION" \
  -derivedDataPath "$DERIVED" \
  -quiet build

BUILT="$DERIVED/Build/Products/Release/Banger.app"
[[ -d "$BUILT" ]] || { print -u2 "Build finished but $BUILT is not there. Something is wrong."; exit 1 }

quit_running
print "Installing to $APP"
rm -rf "$APP"
cp -R "$BUILT" "$APP"

# macOS will not look at a widget extension it has never seen. Registering the app
# bundle makes the widget show up in the widget picker.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$APP" >/dev/null 2>&1 || true
# And forget the build copy, so there is one Banger in the app list and one in the
# widget picker, not two.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -u "$BUILT" >/dev/null 2>&1 || true

print "Installing bangerctl to $BINDIR"
mkdir -p "$BINDIR"
cp -f "$DERIVED/Build/Products/Release/bangerctl" "$BINDIR/bangerctl"

mkdir -p "$DATA"

if [[ "${1:-}" != "--no-launch" ]]; then
  print "Starting it. It has no Dock icon and no window — that is correct."
  open -a "$APP"
  sleep 1
  if pgrep -x Banger >/dev/null 2>&1; then
    print "Running."
  else
    print -u2 "It did not stay running. Check Console.app for 'Banger'."
  fi
fi

cat <<'DONE'

Installed.

Two things left, both one-offs:

  1. Put the widget on the desktop. Right-click any empty part of the desktop,
     choose "Edit Widgets", find Banger, and drag it to the top right.
     macOS gives no way to do this from a script.

  2. Add a task and watch it go bang:

       bangerctl add "Call the realtor"
       bangerctl done 1

     If the shell says "command not found", open a new Terminal window first —
     bangerctl went into ~/.local/bin and that shell has not looked there yet.

To have it start every time you log in: System Settings > General > Login Items,
then add /Applications/Banger.app under "Open at Login".
DONE
