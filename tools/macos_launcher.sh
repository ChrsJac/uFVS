#!/bin/sh
# Executable inside uFVS.app. It intentionally uses only files in this
# extracted release; it never searches for or falls back to system R.

set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../../../" && pwd)
RUNTIME="$ROOT/runtime/Rscript"

if [ ! -x "$RUNTIME" ]; then
  /usr/bin/osascript -e 'display dialog "The uFVS bundled R runtime is missing. Re-extract the downloaded ZIP." buttons {"OK"} default button "OK" with icon stop' >/dev/null 2>&1 || true
  exit 1
fi

export UFVS_RELEASE=1
export R_LIBS_USER="$ROOT/library"
export UFVS_PORT="${UFVS_PORT:-0}"
cd "$ROOT" || exit 1
exec "$RUNTIME" "$ROOT/tools/launch.R"
