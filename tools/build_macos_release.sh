#!/bin/bash
# Build a self-contained Apple Silicon uFVS.app.
#
# Everything the application needs at runtime ends up inside the bundle:
#
#   uFVS.app/Contents/
#     MacOS/uFVS            the launcher
#     Resources/app/        the Shiny application
#     Resources/R/          the private R runtime (a copied R.framework)
#     Resources/R-library/  the private package library
#     Resources/fvs/        the FVS engine and its Fortran libraries
#     Resources/            BUILD_INFO.json, notices, docs
#
# The build machine needs R 4.x, the tested package set, and an arm64 FVS
# executable. None of those paths are used at runtime: the Mach-O patching
# below rewrites every reference to the build machine's R into a bundle-relative
# one, and the build fails if any is left.

set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
VERSION="0.1.0"
OUT_DIR="$ROOT/release"
R_HOME_INPUT="${UFVS_R_HOME:-}"
ENGINE_DIR="${UFVS_ENGINE_DIR:-$ROOT/engine}"
FVS_SOURCE_REVISION="${UFVS_FVS_SOURCE_REVISION:-a17ee9728fe3273e9526d66e66fb4a79bdba6c10}"
FVS_SOURCE_URL="${UFVS_FVS_SOURCE_URL:-https://github.com/USDAForestService/ForestVegetationSimulator}"
FVS_TOOLCHAIN="${UFVS_FVS_TOOLCHAIN:-not recorded for this checked-in engine}"
SKIP_SELF_TEST=0
SKIP_FVS_SMOKE_TEST=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --out) OUT_DIR="$2"; shift 2 ;;
    --r-home) R_HOME_INPUT="$2"; shift 2 ;;
    --engine-dir) ENGINE_DIR="$2"; shift 2 ;;
    --fvs-source-revision) FVS_SOURCE_REVISION="$2"; shift 2 ;;
    --skip-self-test) SKIP_SELF_TEST=1; shift ;;
    --skip-fvs-smoke-test) SKIP_FVS_SMOKE_TEST=1; shift ;;
    -h|--help)
      sed -n '1,20p' "$0"
      echo "Usage: $0 [--out DIR] [--r-home R_HOME] [--engine-dir DIR] [--fvs-source-revision SHA] [--skip-self-test] [--skip-fvs-smoke-test]"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

if [ "$(uname -m)" != "arm64" ]; then
  echo "This script must run on Apple Silicon (arm64)." >&2
  exit 1
fi

if [ -z "$R_HOME_INPUT" ]; then
  R_HOME_INPUT=$(R RHOME 2>/dev/null || true)
fi
if [ -z "$R_HOME_INPUT" ] || [ ! -d "$R_HOME_INPUT" ]; then
  echo "No R runtime found. Supply --r-home with the tested R Resources directory." >&2
  exit 1
fi
R_HOME=$(CDPATH= cd -- "$R_HOME_INPUT" && pwd -P)
R_VERSION=$(basename "$(CDPATH= cd -- "$R_HOME/.." && pwd)")
R_VERSION_ROOT=$(CDPATH= cd -- "$R_HOME/.." && pwd)
BUILDER_RSCRIPT="$R_HOME/bin/Rscript"
if [ ! -x "$BUILDER_RSCRIPT" ]; then
  echo "Rscript was not found below $R_HOME." >&2
  exit 1
fi

if [ ! -d "$ENGINE_DIR" ]; then
  echo "FVS engine directory not found: $ENGINE_DIR" >&2
  exit 1
fi
ENGINE_FILES=("$ENGINE_DIR"/FVS*)
ARM64_ENGINE=0
for f in "${ENGINE_FILES[@]}"; do
  [ -f "$f" ] || continue
  case "$(basename "$f")" in
    FVS[a-z][a-z]|FVS[a-z][a-z][a-z])
      if file "$f" | grep -q "arm64"; then ARM64_ENGINE=1; fi
      ;;
  esac
done
if [ "$ARM64_ENGINE" -ne 1 ]; then
  echo "No native arm64 FVS variant was found in $ENGINE_DIR." >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
OUT_DIR=$(CDPATH= cd -- "$OUT_DIR" && pwd)
TEMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ufvs-macos-release.XXXXXX")
STAGE="$TEMP_ROOT/uFVS-$VERSION-macOS-arm64"
APP="$STAGE/uFVS.app"
CONTENTS="$APP/Contents"
RES="$CONTENTS/Resources"
cleanup() { rm -rf "$TEMP_ROOT"; }
trap cleanup EXIT INT TERM

mkdir -p "$CONTENTS/MacOS" "$RES/app" "$RES/fvs" "$RES/THIRD_PARTY" \
  "$RES/R/R.framework/Versions"

# --- the application ----------------------------------------------------------
cp -p "$ROOT/app.R" "$RES/app/app.R"
cp -p "$ROOT/tools/launch.R" "$RES/app/launch.R"
ditto "$ROOT/R/." "$RES/app/R"
ditto "$ROOT/config/." "$RES/app/config"
ditto "$ROOT/www/." "$RES/app/www"

# --- read-only resources ------------------------------------------------------
cp -p "$ROOT/README.md" "$ROOT/NOTICE.md" "$ROOT/LICENSE" "$ROOT/CITATION.cff" "$RES/"
ditto "$ROOT/THIRD_PARTY/." "$RES/THIRD_PARTY"
if [ -d "$ROOT/docs" ]; then ditto "$ROOT/docs/." "$RES/docs"; fi
# Build the bundle icon from the checked-in logo, so no binary icon asset has to
# live in the repository and the icon always matches the application's mark.
if [ -f "$ROOT/www/ufvs-mark.png" ]; then
  ICONSET="$TEMP_ROOT/uFVS.iconset"
  mkdir -p "$ICONSET"
  for size in 16 32 64 128 256 512; do
    sips -z "$size" "$size" "$ROOT/www/ufvs-mark.png" \
      --out "$ICONSET/icon_${size}x${size}.png" >/dev/null 2>&1 || true
    double=$((size * 2))
    sips -z "$double" "$double" "$ROOT/www/ufvs-mark.png" \
      --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null 2>&1 || true
  done
  # iconutil accepts 16, 32, 128, 256 and 512 at 1x and 2x; 64 is not a member
  # of the set and makes it reject the whole iconset.
  rm -f "$ICONSET/icon_64x64.png" "$ICONSET/icon_64x64@2x.png"
  iconutil -c icns "$ICONSET" -o "$RES/uFVS.icns" >/dev/null 2>&1 || \
    echo "note: the bundle icon could not be generated; the default icon will be used."
fi

# --- the FVS engine -----------------------------------------------------------
ditto "$ENGINE_DIR/." "$RES/fvs"
rm -f "$RES/fvs/README-WINDOWS.txt"

# --- the private R runtime ----------------------------------------------------
# Copy the complete tested R framework version, then expose it through the
# standard Current symlink expected by R's internal directory layout.
ditto "$R_VERSION_ROOT/." "$RES/R/R.framework/Versions/$R_VERSION"
( cd "$RES/R/R.framework/Versions" && ln -s "$R_VERSION" Current )

cp -p "$ROOT/tools/bundled_rscript.sh" "$RES/R/Rscript"
cp -p "$ROOT/tools/bundled_rscript.sh" \
  "$RES/R/R.framework/Versions/$R_VERSION/Resources/bin/Rscript"
cp -p "$ROOT/tools/bundled_rscript.sh" \
  "$RES/R/R.framework/Versions/$R_VERSION/Resources/bin/R"
chmod 755 "$RES/R/Rscript" \
  "$RES/R/R.framework/Versions/$R_VERSION/Resources/bin/Rscript" \
  "$RES/R/R.framework/Versions/$R_VERSION/Resources/bin/R"

"$BUILDER_RSCRIPT" "$ROOT/tools/stage_r_packages.R" --target "$RES/R-library"
"$BUILDER_RSCRIPT" "$ROOT/tools/write_third_party_inventory.R" \
  --library "$RES/R-library" --target "$RES/THIRD_PARTY"

STAGED_R_HOME="$RES/R/R.framework/Versions/$R_VERSION/Resources"
ORIG_R_LIB="$R_HOME/lib"

patch_core_macho() {
  local f="$1" dep base replacement
  [ -f "$f" ] || return 0
  while IFS= read -r dep; do
    [ -n "$dep" ] || continue
    case "$dep" in
      "$ORIG_R_LIB"/*)
        base=$(basename "$dep")
        case "$f" in
          "$STAGED_R_HOME"/bin/exec/*) replacement="@loader_path/../../lib/$base" ;;
          "$STAGED_R_HOME"/modules/*) replacement="@loader_path/../lib/$base" ;;
          "$STAGED_R_HOME"/library/*/libs/*) replacement="@loader_path/../../../lib/$base" ;;
          *) replacement="@loader_path/$base" ;;
        esac
        install_name_tool -change "$dep" "$replacement" "$f" 2>/dev/null
        ;;
    esac
  done < <(otool -L "$f" | sed -n '2,$p' | sed -E 's/^[[:space:]]+([^ ]+).*/\1/')
  if [[ "$f" == *.dylib ]]; then
    install_name_tool -id "@loader_path/$(basename "$f")" "$f" 2>/dev/null || true
  fi
  codesign -f -s - "$f" >/dev/null 2>&1 || true
}

# The R executable, base/recommended extensions, and all R-side libraries must
# point at the copied framework, not at /Library/Frameworks/R.framework on the
# build machine.
while IFS= read -r f; do
  file "$f" | grep -q 'Mach-O' || continue
  patch_core_macho "$f"
done < <(find "$RES/R" -type f -print)

# A staged package's shared object sits at
#   Resources/R-library/<pkg>/libs/<file>
# so three levels up is Contents/Resources, from which the runtime is reachable.
patch_package_macho() {
  local f="$1" dep base replacement
  [ -f "$f" ] || return 0
  file "$f" | grep -q 'Mach-O' || return 0
  while IFS= read -r dep; do
    [ -n "$dep" ] || continue
    case "$dep" in
      "$ORIG_R_LIB"/*)
        base=$(basename "$dep")
        replacement="@loader_path/../../../R/R.framework/Versions/$R_VERSION/Resources/lib/$base"
        install_name_tool -change "$dep" "$replacement" "$f" 2>/dev/null
        ;;
    esac
  done < <(otool -L "$f" | sed -n '2,$p' | sed -E 's/^[[:space:]]+([^ ]+).*/\1/')
  codesign -f -s - "$f" >/dev/null 2>&1 || true
}
while IFS= read -r f; do patch_package_macho "$f"; done < <(
  find "$RES/R-library" -type f \( -name '*.so' -o -name '*.dylib' \) -print)

# Remove compiler-installation rpaths from the bundled FVS files. The official
# executable already carries its Fortran libraries beside it; only @loader_path
# is valid in a moved bundle.
while IFS= read -r f; do
  file "$f" | grep -q 'Mach-O' || continue
  while IFS= read -r rp; do
    [ -n "$rp" ] || continue
    install_name_tool -delete_rpath "$rp" "$f" 2>/dev/null || true
  done < <(otool -l "$f" | awk '$1 == "path" && $2 ~ /^\// {print $2}')
  codesign -f -s - "$f" >/dev/null 2>&1 || true
done < <(find "$RES/fvs" -type f -print)

# --- portability audit --------------------------------------------------------
# A bundle that still names a build-machine path is not portable, however well
# it runs here. Fail the build rather than ship it.
leftovers=$(while IFS= read -r f; do
  file "$f" | grep -q 'Mach-O' || continue
  otool -L "$f" 2>/dev/null | grep -F "$ORIG_R_LIB" && echo " in $f"
done < <(find "$RES/R" "$RES/R-library" "$RES/fvs" -type f -print) || true)
if [ -n "$leftovers" ]; then
  echo "Staged Mach-O files still depend on the build machine's R:" >&2
  echo "$leftovers" >&2
  exit 1
fi

# The same check for the development machine's home directory and for Homebrew,
# MacPorts and the system R framework, in any staged Mach-O file.
machine_paths=$(while IFS= read -r f; do
  file "$f" | grep -q 'Mach-O' || continue
  otool -L "$f" 2>/dev/null | sed -n '2,$p' |
    grep -E "^[[:space:]]+($HOME|/opt/homebrew|/opt/local|/usr/local/(lib|opt)|/Library/Frameworks/R\.framework)/" &&
    echo " in $f"
done < <(find "$RES" -type f -print) || true)
if [ -n "$machine_paths" ]; then
  echo "Staged Mach-O files still link against build-machine locations:" >&2
  echo "$machine_paths" >&2
  exit 1
fi

# --- the bundle ---------------------------------------------------------------
VERSIONED_PLIST="$CONTENTS/Info.plist"
cp -p "$ROOT/tools/macos_app_Info.plist" "$VERSIONED_PLIST"
sed -i '' -e "s#0.1.0#$VERSION#g" "$VERSIONED_PLIST"
cp -p "$ROOT/tools/macos_launcher.sh" "$CONTENTS/MacOS/uFVS"
chmod 755 "$CONTENTS/MacOS/uFVS"

"$BUILDER_RSCRIPT" "$ROOT/tools/write_build_info.R" \
  --root "$RES" --app "$RES/app" --library "$RES/R-library" \
  --platform "macOS" --architecture "arm64" --engine-dir "$RES/fvs" \
  --fvs-source-revision "$FVS_SOURCE_REVISION" --fvs-source-url "$FVS_SOURCE_URL" \
  --fvs-toolchain "$FVS_TOOLCHAIN"

# Ad-hoc sign the bundle last, once nothing else will modify it.
codesign -f -s - --deep "$APP" >/dev/null 2>&1 || \
  echo "note: the bundle could not be ad-hoc signed; Gatekeeper may ask the user to confirm."

# --- test the bundle, in the launcher's own environment -----------------------
export UFVS_RELEASE=1
export UFVS_APP_DIR="$RES/app"
export UFVS_RUNTIME_DIR="$RES/R"
export UFVS_LIBRARY_DIR="$RES/R-library"
export UFVS_FVS_DIR="$RES/fvs"
export UFVS_RESOURCES_DIR="$RES"
export R_LIBS_USER="$RES/R-library"

if [ "$SKIP_SELF_TEST" -eq 0 ]; then
  "$RES/R/Rscript" "$ROOT/tools/release_self_test.R"
fi

if [ "$SKIP_FVS_SMOKE_TEST" -eq 0 ]; then
  "$RES/R/Rscript" "$ROOT/tools/fvs_smoke_test.R" \
    --bundle "$APP" --engine "$RES/fvs/FVSsn"
  "$RES/R/Rscript" "$ROOT/tools/release_http_smoke_test.R" \
    --launcher "$CONTENTS/MacOS/uFVS"
  "$RES/R/Rscript" "$ROOT/tools/acceptance_test.R"
fi

ZIP="$OUT_DIR/uFVS-macOS-arm64.zip"
rm -f "$ZIP"
# --keepParent on the .app itself, so the ZIP expands straight to uFVS.app.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
echo "Created $ZIP"
