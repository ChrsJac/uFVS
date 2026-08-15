#!/bin/bash
# ------------------------------------------------------------------------------
# Build an official FVS variant into a self-contained macOS executable.
#
#   tools/build_fvs.sh <path to ForestVegetationSimulator source> [variant ...]
#
# Example:
#   tools/build_fvs.sh ~/src/ForestVegetationSimulator-main sn
#
# This compiles the official FVS source unmodified. It exists because the
# stock build path does not work out of the box on macOS:
#
#   * FVS's makefile needs GNU make 4.x. macOS ships 3.81 (2006), which cannot
#     parse the multi-line $(shell ...) in the version-metadata block.
#   * gfortran is not part of macOS or the Xcode command line tools.
#
# So this script reproduces the makefile's own compile and link steps directly,
# using the same flags, then rewrites the runtime library paths so the finished
# binary carries its Fortran runtime beside it instead of depending on wherever
# the compiler happened to be installed.
#
# No FVS source is modified. Nothing here changes a model or an equation.
# ------------------------------------------------------------------------------
set -u

SRC="${1:-}"
shift || true
VARIANTS=("$@")
[ ${#VARIANTS[@]} -eq 0 ] && VARIANTS=(sn)

if [ -z "$SRC" ] || [ ! -d "$SRC/bin" ]; then
  echo "usage: $0 <ForestVegetationSimulator source dir> [variant ...]" >&2
  exit 1
fi
SRC="$(cd "$SRC" && pwd)"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$HERE/engine"
mkdir -p "$OUT"

# --- locate a Fortran compiler ------------------------------------------------
# Prefer a system install; fall back to a payload-extracted copy under
# ~/.local/gfortran (see docs/ENGINE_SETUP.md), which needs no admin rights.
FC=""
for c in \
  /opt/gfortran/bin/gfortran \
  /opt/homebrew/bin/gfortran \
  /usr/local/bin/gfortran \
  "$HOME/.local/gfortran/opt/gfortran/bin/aarch64-apple-darwin20.0-gfortran" \
  "$HOME/.local/gfortran/opt/gfortran/bin/x86_64-apple-darwin20.0-gfortran"
do
  [ -x "$c" ] && { FC="$c"; break; }
done
if [ -z "$FC" ]; then
  echo "No gfortran found. See docs/ENGINE_SETUP.md." >&2
  exit 1
fi
CC="${CC:-/usr/bin/clang}"
export SDKROOT="${SDKROOT:-$(xcrun --show-sdk-path 2>/dev/null)}"

# Where the compiler keeps its runtime libraries, so they can be bundled.
FCLIB="$("$FC" -print-file-name=libgfortran.dylib 2>/dev/null)"
FCLIB="$(cd "$(dirname "$FCLIB")" 2>/dev/null && pwd)"

echo "FVS source : $SRC"
echo "Fortran    : $FC"
echo "C          : $CC"
echo "Runtime    : ${FCLIB:-<none>}"
echo "Output     : $OUT"

# --- flags, matching bin/makefile --------------------------------------------
#
# One deliberate difference from the official makefile: it sets
#   -ffpe-trap=invalid,zero,underflow,overflow,denormal
# which makes the CPU raise a trap on exceptional floating-point results. On
# Apple silicon that aborts FVS with SIGILL during a normal run — 'denormal' is
# not even supported here, and trapping 'underflow' fires on ordinary arithmetic
# that IEEE handles by flushing to zero.
#
# Dropping the flag changes no computation. It only stops the CPU from
# signalling on results the standard already defines. -fbacktrace is kept so a
# genuine crash still prints where it happened.
FFLAGS=(-g -cpp -DCMPgcc -Wall -Wno-integer-division -fbacktrace
        -std=legacy -fallow-argument-mismatch -fallow-invalid-boz)
CFLAGS=(-DANSI -DCMPgcc -DSQLITE_THREADSAFE=0 -DSQLITE_OMIT_LOAD_EXTENSION -Dunix -w)
# The makefile derives these from git; absent a repo they are simply unknown.
VER=(-DFVS_GIT_ORG='"USDAForestService"' -DFVS_GIT_VERSION='"unknown"'
     -DFVS_GIT_HASH='"unknown"' -DFVS_GIT_DATE='"unknown"'
     -DFVS_GIT_BRANCH='"unknown"' -DFVS_GIT_REMOTE='"unknown"')

build_variant() {
  local v="$1"
  local list="$SRC/bin/FVS${v}_sourceList.txt"
  if [ ! -f "$list" ]; then
    echo "  no source list for variant '$v'" >&2
    return 1
  fi

  local bd="$SRC/bin/FVS${v}_uFVSbuild"
  rm -rf "$bd"; mkdir -p "$bd"

  # The makefile flattens every source file into one build directory so that
  # include files resolve without any -I paths.
  ( cd "$SRC/bin" && grep -v '^[[:space:]]*$' "$list" | while read -r f; do
      [ -f "$f" ] && cp -p "$f" "$bd/"
    done )

  cd "$bd" || return 1
  local nf; nf=$(ls | wc -l | tr -d ' ')
  echo "  [$v] $nf files"

  # Modules must exist before anything that uses them.
  local mods; mods=$(ls *_mod.f 2>/dev/null)
  for m in $mods; do
    "$FC" "${FFLAGS[@]}" "${VER[@]}" -c "$m" -o "${m%.f}.o" 2>>build.err || {
      echo "  [$v] FAILED compiling module $m"; tail -15 build.err; return 1; }
  done

  # version.f and main.f are free-form; everything else is fixed-form.
  for special in version.f main.f; do
    [ -f "$special" ] || continue
    "$FC" "${FFLAGS[@]}" "${VER[@]}" -ffree-form -c "$special" -o "${special%.f}.o" 2>>build.err || {
      echo "  [$v] FAILED compiling $special"; tail -15 build.err; return 1; }
  done

  # Everything else.
  local failed=0 n=0
  for f in *.f *.for *.F; do
    [ -f "$f" ] || continue
    case "$f" in *_mod.f|version.f|main.f) continue;; esac
    [ -f "${f%.*}.o" ] && continue
    "$FC" "${FFLAGS[@]}" "${VER[@]}" -c "$f" -o "${f%.*}.o" 2>>build.err || { failed=1; echo "  [$v] FAILED: $f"; }
    n=$((n+1))
  done
  for f in *.c *.cpp; do
    [ -f "$f" ] || continue
    [ -f "${f%.*}.o" ] && continue
    "$CC" "${CFLAGS[@]}" -c "$f" -o "${f%.*}.o" 2>>build.err || { failed=1; echo "  [$v] FAILED: $f"; }
    n=$((n+1))
  done
  if [ $failed -ne 0 ]; then
    echo "  [$v] compile errors; see $bd/build.err"
    grep -i "error" build.err | head -15
    return 1
  fi
  echo "  [$v] compiled $n translation units"

  # Link the standalone program.
  "$FC" -o "$OUT/FVS${v}" ./*.o 2>>build.err || {
    echo "  [$v] link failed"; grep -i "error\|undefined" build.err | head -20; return 1; }

  echo "  [$v] linked $OUT/FVS${v}"
  return 0
}

bundle_runtime() {
  # Give the binaries their Fortran runtime locally, so they do not depend on
  # the compiler staying installed. install_name_tool invalidates the ad-hoc
  # code signature, so each file is re-signed afterwards or macOS kills it.
  [ -n "$FCLIB" ] || return 0
  local libs=(libgfortran.5.dylib libquadmath.0.dylib libgcc_s.1.1.dylib)
  for l in "${libs[@]}"; do
    [ -f "$FCLIB/$l" ] && cp -f "$FCLIB/$l" "$OUT/" && chmod u+w "$OUT/$l"
  done
  ( cd "$OUT" || return 0
    for f in FVS* "${libs[@]}"; do
      [ -f "$f" ] || continue
      install_name_tool -id "@loader_path/$f" "$f" 2>/dev/null
      otool -L "$f" 2>/dev/null | tail -n +2 | awk '{print $1}' | grep -E "gfortran|/opt/" | while read -r dep; do
        install_name_tool -change "$dep" "@loader_path/$(basename "$dep")" "$f" 2>/dev/null
      done
    done
    for f in FVS* "${libs[@]}"; do
      [ -f "$f" ] && codesign -f -s - "$f" 2>/dev/null
    done )
}

ok=0; bad=0
for v in "${VARIANTS[@]}"; do
  if build_variant "$v"; then ok=$((ok+1)); else bad=$((bad+1)); fi
done

bundle_runtime

echo
echo "built $ok variant(s), $bad failed"
ls -lh "$OUT" 2>/dev/null | tail -n +2
[ $bad -eq 0 ] || exit 1
