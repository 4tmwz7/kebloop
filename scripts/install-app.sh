#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
BUNDLE_ID="com.kebloop.launcher"
DESTINATION="/Applications"
NO_LAUNCH=0

usage() {
  cat <<'USAGE'
Usage: scripts/install-app.sh [--destination DIR] [--no-launch]

Build Kebloop, install it as DIR/Kebloop.app (default: /Applications/Kebloop.app),
and launch the installed app. --no-launch skips only the launch step.
USAGE
}

fail() {
  printf 'install-app: %s\n' "$*" >&2
  exit 1
}

while (($#)); do
  case "$1" in
    --destination)
      (($# >= 2)) || fail "--destination requires a directory."
      DESTINATION="$2"
      shift 2
      ;;
    --no-launch)
      NO_LAUNCH=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage >&2
      fail "unknown argument: $1"
      ;;
  esac
done

[[ "$(uname -s)" == "Darwin" ]] || fail "this install script requires macOS."
[[ -n "$DESTINATION" ]] || fail "destination directory cannot be empty."
while [[ "$DESTINATION" != "/" && "$DESTINATION" == */ ]]; do
  DESTINATION="${DESTINATION%/}"
done

if [[ -L "$DESTINATION" ]]; then
  fail "refusing to install through a symlinked destination directory: $DESTINATION"
fi
if ! mkdir -p -- "$DESTINATION"; then
  printf 'install-app: cannot create destination %s. Try --destination "$HOME/Applications".\n' "$DESTINATION" >&2
  exit 1
fi
[[ -d "$DESTINATION" && ! -L "$DESTINATION" ]] \
  || fail "destination must be a real directory, not a symlink: $DESTINATION"
DESTINATION="$(cd -- "$DESTINATION" && pwd -P)"
TARGET_APP="$DESTINATION/Kebloop.app"
TARGET_EXECUTABLE="$TARGET_APP/Contents/MacOS/Kebloop"

verify_bundle() {
  local bundle="$1"
  [[ -d "$bundle" && ! -L "$bundle" ]] || return 1
  [[ -f "$bundle/Contents/Info.plist" && ! -L "$bundle/Contents/Info.plist" ]] || return 1
  [[ -x "$bundle/Contents/MacOS/Kebloop" && ! -L "$bundle/Contents/MacOS/Kebloop" ]] || return 1
  /usr/bin/plutil -lint "$bundle/Contents/Info.plist" >/dev/null || return 1
  local bundle_id
  bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$bundle/Contents/Info.plist" 2>/dev/null)" || return 1
  [[ "$bundle_id" == "$BUNDLE_ID" ]] || return 1
  codesign --verify --deep --strict "$bundle" >/dev/null 2>&1 || return 1
  return 0
}

check_replaceable_target() {
  if [[ -L "$TARGET_APP" ]]; then
    fail "refusing to replace symlinked app bundle: $TARGET_APP"
  elif [[ -e "$TARGET_APP" ]]; then
    [[ -d "$TARGET_APP" ]] || fail "refusing to replace non-directory target: $TARGET_APP"
    if find "$TARGET_APP" -type l -print -quit | /usr/bin/grep -q .; then
      fail "refusing to replace an app bundle containing symlinks: $TARGET_APP"
    fi
    verify_bundle "$TARGET_APP" \
      || fail "refusing to replace an app that is not a valid Kebloop bundle: $TARGET_APP"
  fi
}

check_replaceable_target

DIST_DIR="$REPO_ROOT/dist"
[[ ! -L "$DIST_DIR" ]] || fail "refusing to build through symlinked output directory: $DIST_DIR"

TEMP_DIR="$(mktemp -d "$DESTINATION/.Kebloop-install.XXXXXX")" \
  || fail "cannot write to $DESTINATION. Try --destination \"\$HOME/Applications\"."
STAGED_APP="$TEMP_DIR/Kebloop.app"
PREVIOUS_APP="$TEMP_DIR/previous.app"
HAD_PREVIOUS=0
COMMITTED=0
KEEP_TEMP=0

cleanup() {
  local status=$?
  trap - EXIT
  if (( HAD_PREVIOUS && ! COMMITTED )) && [[ ! -e "$TARGET_APP" && -d "$PREVIOUS_APP" ]]; then
    if ! mv -- "$PREVIOUS_APP" "$TARGET_APP"; then
      printf 'install-app: could not restore the previous app bundle; it remains at %s\n' "$PREVIOUS_APP" >&2
      KEEP_TEMP=1
      status=1
    fi
  fi
  if (( ! KEEP_TEMP )); then rm -rf -- "$TEMP_DIR"; fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

process_executable() {
  /usr/sbin/lsof -a -p "$1" -d txt -Fn 2>/dev/null | awk '
    /^ftxt$/ { in_text = 1; next }
    /^f/ { if ($0 != "ftxt") in_text = 0 }
    in_text && /^n/ && !found { executable = substr($0, 2); found = 1 }
    END { if (found) print executable }
  ' || true
}

stop_exact_processes() {
  local wanted="$1"
  local pid executable attempt
  [[ -x /usr/sbin/lsof ]] || fail "lsof is unavailable; cannot safely check for a running Kebloop process."
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    executable="$(process_executable "$pid")"
    executable="${executable% (deleted)}"
    if [[ -z "$executable" ]] && kill -0 "$pid" 2>/dev/null; then
      fail "could not verify the executable path for Kebloop process $pid; close it and retry."
    fi
    [[ "$executable" == "$wanted" ]] || continue

    printf 'Stopping running Kebloop from %s\n' "$wanted"
    if ! kill -TERM "$pid" 2>/dev/null && kill -0 "$pid" 2>/dev/null; then
      fail "could not send SIGTERM to Kebloop process $pid. Close it and retry."
    fi
    for ((attempt = 0; attempt < 50; attempt++)); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
    if kill -0 "$pid" 2>/dev/null; then
      fail "Kebloop process $pid did not exit after SIGTERM. Close it and retry."
    fi
  done < <(/usr/bin/pgrep -x Kebloop 2>/dev/null || true)
}

# The build replaces dist/Kebloop.app, so stop that exact executable first
# when performing a normal install. --no-launch leaves a running dev build alone.
DIST_EXECUTABLE="$DIST_DIR/Kebloop.app/Contents/MacOS/Kebloop"
if (( ! NO_LAUNCH )); then
  stop_exact_processes "$DIST_EXECUTABLE"
fi

"$SCRIPT_DIR/build-app.sh"
SOURCE_APP="$DIST_DIR/Kebloop.app"
verify_bundle "$SOURCE_APP" || fail "built app bundle failed verification: $SOURCE_APP"
if find "$SOURCE_APP" -type l -print -quit | /usr/bin/grep -q .; then
  fail "refusing to install an app bundle that contains symlinks: $SOURCE_APP"
fi

ditto "$SOURCE_APP" "$STAGED_APP"
verify_bundle "$STAGED_APP" || fail "staged app bundle failed verification: $STAGED_APP"
if find "$STAGED_APP" -type l -print -quit | /usr/bin/grep -q .; then
  fail "refusing to install an app bundle that contains symlinks: $STAGED_APP"
fi

# Check again after building in case another app appeared while the build ran.
check_replaceable_target
stop_exact_processes "$TARGET_EXECUTABLE"

if [[ -e "$TARGET_APP" ]]; then
  mv -- "$TARGET_APP" "$PREVIOUS_APP"
  HAD_PREVIOUS=1
fi
if ! mv -- "$STAGED_APP" "$TARGET_APP"; then
  fail "could not move the verified app bundle into place: $TARGET_APP"
fi
COMMITTED=1
printf 'Installed and verified %s\n' "$TARGET_APP"

if (( ! NO_LAUNCH )); then
  /usr/bin/open "$TARGET_APP"
fi
