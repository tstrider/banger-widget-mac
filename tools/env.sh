#!/bin/zsh
# Shared tool paths for the Banger build. Source this before using ffmpeg/xcodegen.
#
# Nothing in here is allowed to be a path that only exists on one machine, or one
# inside /private/tmp, which macOS clears on reboot. Either would make `install.sh`
# fail with a "no such file or directory" that looks nothing like the cause.

# The repo, derived from where this file actually is. Works from any checkout, and
# works when this script is sourced from another directory.
BANGER_ROOT="${0:A:h:h}"
export BANGER_ROOT

# Build helpers. Order: something already on PATH, then the durable copy under
# ~/.local/libexec/banger, then a Homebrew prefix. Never /tmp.
_banger_tools="$HOME/.local/libexec/banger"

# $1 = command name, $2 = a flag that makes it print something and exit 0,
# $3... = extra absolute candidates in preference order after PATH.
#
# Every candidate is RUN, not just tested with -x. A stale symlink to an x86_64
# binary is executable and still fails with "bad CPU type in executable" at the
# moment you need it.
_banger_find () {
  local name="$1" probe="$2"; shift 2
  local candidate
  for candidate in "$(command -v "$name" 2>/dev/null)" "$@"; do
    [[ -n "$candidate" && -x "$candidate" ]] || continue
    "$candidate" "$probe" >/dev/null 2>&1 || continue
    print -r -- "$candidate"
    return 0
  done
  return 1
}

export XCODEGEN="${XCODEGEN:-$(_banger_find xcodegen --version \
  "$_banger_tools/xcodegen-app/bin/xcodegen" \
  /opt/homebrew/bin/xcodegen /usr/local/bin/xcodegen)}"

# ffmpeg is optional. Building and installing the app does not need it.
export FFMPEG="${FFMPEG:-$(_banger_find ffmpeg -version \
  "$_banger_tools/ffmpeg" \
  /opt/homebrew/bin/ffmpeg /usr/local/bin/ffmpeg)}"
# ffprobe-static ships x86_64 only; `ffmpeg -i` probes fine and is already arm64.
export FFPROBE="${FFPROBE:-$FFMPEG}"

# Scratch space for anything a tool needs to write that is not a result.
export BANGER_SCRATCH="${BANGER_SCRATCH:-${TMPDIR:-/tmp}/banger-scratch}"
mkdir -p "$BANGER_SCRATCH" 2>/dev/null || true

export BANGER_GROUP="${BANGER_GROUP:-group.com.bangerwidget.banger}"

# DerivedData must NOT live inside this project. ~/Documents is managed by a file
# provider that stamps com.apple.FinderInfo onto bundle directories, and codesign
# refuses to sign a bundle carrying one ("resource fork, Finder information, or
# similar detritus not allowed"). Building the widget extension fails outright.
#
# The folder name ends in .noindex so Spotlight never lists the build copies of
# Banger.app next to the real one in /Applications.
export BANGER_DD_ROOT="${BANGER_DD_ROOT:-$HOME/Library/Developer/Xcode/DerivedData/Banger.noindex}"

# Xcode 27 picks x86_64 on Apple silicon unless the destination is spelled out.
export BANGER_DESTINATION="${BANGER_DESTINATION:-platform=macOS,arch=arm64}"

# Say so loudly rather than failing later with a confusing error from xcodebuild.
if [[ -z "${XCODEGEN:-}" || ! -x "${XCODEGEN:-}" ]]; then
  print -u2 "env.sh: xcodegen not found. Install it (brew install xcodegen) or set XCODEGEN."
fi
