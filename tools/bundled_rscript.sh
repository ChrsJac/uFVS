#!/bin/sh
# Relocatable Rscript wrapper for the macOS release. macOS R's native
# Rscript embeds the build-time R_HOME, so it cannot be copied unchanged.

set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

if [ -x "$HERE/exec/R" ]; then
  R_HOME_DIR=$(CDPATH= cd -- "$HERE/.." && pwd)
elif [ -x "$HERE/R.framework/Versions/Current/Resources/bin/exec/R" ]; then
  R_HOME_DIR=$(CDPATH= cd -- "$HERE/R.framework/Versions/Current/Resources" && pwd)
else
  R_HOME_DIR=""
  if [ -d "$HERE/R.framework/Versions" ]; then
    for candidate in "$HERE"/R.framework/Versions/*/Resources; do
      if [ -x "$candidate/bin/exec/R" ]; then R_HOME_DIR="$candidate"; break; fi
    done
  fi
fi

if [ -z "$R_HOME_DIR" ] || [ ! -x "$R_HOME_DIR/bin/exec/R" ]; then
  echo "uFVS bundled R runtime was not found beside this launcher." >&2
  exit 1
fi

export R_HOME="$R_HOME_DIR"
R_BIN="$R_HOME_DIR/bin/exec/R"

# Rscript accepts a bare script path; the low-level R executable expects
# --file=path and --args instead. Preserve the common -e/--file forms too.
if [ "$#" -gt 0 ]; then
  case "$1" in
    -e|--expression|-f|--file|--file=*|--version|-v|--help|-h|-*)
      exec "$R_BIN" --no-echo --no-restore "$@"
      ;;
    *)
      script="$1"
      shift
      exec "$R_BIN" --no-echo --no-restore --file="$script" --args "$@"
      ;;
  esac
else
  exec "$R_BIN" --no-echo --no-restore
fi
