#!/bin/sh
# ------------------------------------------------------------------------------
# uFVS.app/Contents/MacOS/uFVS
#
# The macOS launcher. Everything it uses lives inside the .app bundle, resolved
# from this file's own location, so the bundle works from /Applications, from a
# Downloads folder, from an external disk, and from a path containing spaces.
#
# It never looks at /Library/Frameworks/R.framework, /usr/local/bin/R,
# /opt/homebrew, or PATH. If the bundled runtime is missing the app says so in a
# dialog rather than failing silently.
#
#   uFVS.app/Contents/
#     MacOS/uFVS          this file
#     Resources/app/      the Shiny application
#     Resources/R/        the private R runtime
#     Resources/R-library/  the private package library
#     Resources/fvs/      the FVS engine and its Fortran libraries
# ------------------------------------------------------------------------------

set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CONTENTS=$(CDPATH= cd -- "$HERE/.." && pwd)
RESOURCES="$CONTENTS/Resources"

APP_DIR="$RESOURCES/app"
RUNTIME_DIR="$RESOURCES/R"
LIBRARY_DIR="$RESOURCES/R-library"
FVS_DIR="$RESOURCES/fvs"
RSCRIPT="$RUNTIME_DIR/Rscript"

STATE_DIR="$HOME/Library/Application Support/uFVS/runtime"
LOG_DIR="$HOME/Library/Logs/uFVS"
mkdir -p "$STATE_DIR" "$LOG_DIR" 2>/dev/null || true
LOG_FILE="$LOG_DIR/launcher.log"
SERVER_LOG="$LOG_DIR/server.log"
SESSION_FILE="$STATE_DIR/session.json"
LOCK_DIR="$STATE_DIR/instance.lock"

log() {
  printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG_FILE" 2>/dev/null || true
}

fail() {
  message="$1"
  log "STARTUP FAILED: $message"
  detail=$(tail -n 25 "$SERVER_LOG" 2>/dev/null)
  full="$message

Log: $LOG_FILE"
  if [ -n "$detail" ]; then
    full="$message

Last messages from uFVS:
$detail

Log: $LOG_FILE"
  fi
  # osascript is the only way to reach the user: a double-clicked .app has no
  # terminal to print to.
  /usr/bin/osascript -e 'on run argv
    display dialog (item 1 of argv) with title "uFVS" buttons {"OK"} default button "OK" with icon stop
  end run' "$full" >/dev/null 2>&1 || true
  exit 1
}

log "---- uFVS launcher starting ----"
log "bundle: $CONTENTS"

[ -d "$APP_DIR" ] || fail "The uFVS application files are missing from this bundle. Re-download uFVS and copy uFVS.app out of the disk image or ZIP."
[ -x "$RSCRIPT" ] || fail "The bundled R runtime is missing from this bundle. Re-download uFVS and copy uFVS.app out of the disk image or ZIP."

# --- one instance at a time ---------------------------------------------------
# A second double-click should raise the window that is already open, not start
# a competing server against the same project files.
open_existing() {
  [ -f "$SESSION_FILE" ] || return 1
  existing_url=$(sed -n 's/.*"url"[^"]*"\([^"]*\)".*/\1/p' "$SESSION_FILE" | head -n 1)
  [ -n "$existing_url" ] || return 1
  if /usr/bin/curl -sf -m 3 -o /dev/null "$existing_url"; then
    log "already running at $existing_url; opening a window there"
    /usr/bin/open "$existing_url" >/dev/null 2>&1 || true
    return 0
  fi
  return 1
}

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  running_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
  if [ -n "${running_pid:-}" ] && kill -0 "$running_pid" 2>/dev/null; then
    if open_existing; then exit 0; fi
    log "instance $running_pid holds the lock but is not answering; taking over"
    kill "$running_pid" 2>/dev/null || true
    sleep 1
  fi
  # The previous run was killed before it could clean up.
  log "clearing a stale lock"
  rm -rf "$LOCK_DIR" 2>/dev/null || true
  mkdir "$LOCK_DIR" 2>/dev/null || fail "uFVS could not claim its lock directory in $STATE_DIR."
fi
printf '%s\n' "$$" >"$LOCK_DIR/pid"

# --- shut the whole tree down on the way out ----------------------------------
SERVER_PID=""

kill_descendants() {
  parent="$1"
  signal="$2"
  for child in $(pgrep -P "$parent" 2>/dev/null); do
    kill_descendants "$child" "$signal"
  done
  kill "-$signal" "$parent" 2>/dev/null || true
}

cleanup() {
  trap - EXIT INT TERM HUP
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    log "stopping R/FVS process tree at $SERVER_PID"
    # TERM first so Shiny closes its connections and callr workers exit; then
    # KILL anything still standing, including a wedged FVS run.
    kill_descendants "$SERVER_PID" TERM
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      kill -0 "$SERVER_PID" 2>/dev/null || break
      sleep 0.5
    done
    kill_descendants "$SERVER_PID" KILL
  fi
  rm -f "$SESSION_FILE" 2>/dev/null || true
  rm -rf "$LOCK_DIR" 2>/dev/null || true
  log "---- uFVS launcher finished ----"
}
trap cleanup EXIT INT TERM HUP

# --- start the server ---------------------------------------------------------
rm -f "$SESSION_FILE" 2>/dev/null || true

UFVS_RELEASE=1
UFVS_DESKTOP=1
UFVS_APP_DIR="$APP_DIR"
UFVS_RUNTIME_DIR="$RUNTIME_DIR"
UFVS_LIBRARY_DIR="$LIBRARY_DIR"
UFVS_FVS_DIR="$FVS_DIR"
UFVS_RESOURCES_DIR="$RESOURCES"
UFVS_SESSION_FILE="$SESSION_FILE"
UFVS_LAUNCH_BROWSER=0
R_LIBS_USER="$LIBRARY_DIR"
R_LIBS_SITE=""
export UFVS_RELEASE UFVS_DESKTOP UFVS_APP_DIR UFVS_RUNTIME_DIR UFVS_LIBRARY_DIR \
  UFVS_FVS_DIR UFVS_RESOURCES_DIR UFVS_SESSION_FILE UFVS_LAUNCH_BROWSER \
  R_LIBS_USER R_LIBS_SITE
# The port is chosen by httpuv unless the caller pinned one, which keeps two
# copies of uFVS on one Mac from colliding.
UFVS_PORT="${UFVS_PORT:-0}"
export UFVS_PORT

cd "$APP_DIR" || fail "uFVS could not open its application directory."

: >"$SERVER_LOG" 2>/dev/null || true
log "starting: $RSCRIPT $APP_DIR/launch.R"
"$RSCRIPT" "$APP_DIR/launch.R" >>"$SERVER_LOG" 2>&1 &
SERVER_PID=$!
log "server pid $SERVER_PID"

# --- wait for the server, then open the browser -------------------------------
URL=""
WAITED=0
LIMIT="${UFVS_START_TIMEOUT:-90}"
while [ "$WAITED" -lt "$LIMIT" ]; do
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    fail "uFVS stopped while starting up."
  fi
  if [ -z "$URL" ] && [ -f "$SESSION_FILE" ]; then
    URL=$(sed -n 's/.*"url"[^"]*"\([^"]*\)".*/\1/p' "$SESSION_FILE" | head -n 1)
    [ -n "$URL" ] && log "server reports $URL"
  fi
  # Only open a window once the port actually answers, so the browser never
  # lands on a connection-refused page.
  if [ -n "$URL" ] && /usr/bin/curl -sf -m 3 -o /dev/null "$URL"; then
    break
  fi
  sleep 1
  WAITED=$((WAITED + 1))
done

if [ -z "$URL" ] || ! /usr/bin/curl -sf -m 3 -o /dev/null "$URL"; then
  fail "uFVS did not finish starting within ${LIMIT} seconds."
fi

# UFVS_NO_BROWSER lets the build tests drive this launcher exactly as a user
# would without a browser window appearing on the build machine.
if [ "${UFVS_NO_BROWSER:-0}" = "1" ]; then
  log "browser suppressed by UFVS_NO_BROWSER; serving at $URL"
else
  log "opening $URL"
  /usr/bin/open "$URL" >/dev/null 2>&1 || \
    log "could not open the default browser; the address is $URL"
fi

# Stay alive as the owner of the process tree. uFVS exits when the last browser
# window closes; quitting the app here tears the tree down through cleanup().
wait "$SERVER_PID"
STATUS=$?
log "server exited with status $STATUS"
exit 0
