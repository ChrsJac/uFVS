#!/bin/bash
# Build a self-contained Apple Silicon uFVS release.
#
# The build machine needs R 4.x, the tested package set, and an arm64 FVS
# executable. The resulting ZIP does not use any of those paths at runtime.

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
      sed -n '1,18p' "$0"
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
cleanup() { rm -rf "$TEMP_ROOT"; }
trap cleanup EXIT INT TERM

mkdir -p "$STAGE/tools" "$STAGE/engine" "$STAGE/THIRD_PARTY" "$STAGE/runtime/R.framework/Versions" \
  "$STAGE/uFVS.app/Contents/MacOS"
cp -p "$ROOT/app.R" "$ROOT/README.md" "$ROOT/NOTICE.md" "$ROOT/LICENSE" "$ROOT/CITATION.cff" "$STAGE/"
ditto "$ROOT/R/." "$STAGE/R"
ditto "$ROOT/config/." "$STAGE/config"
ditto "$ROOT/www/." "$STAGE/www"
if [ -d "$ROOT/docs" ]; then ditto "$ROOT/docs/." "$STAGE/docs"; fi
ditto "$ROOT/THIRD_PARTY/." "$STAGE/THIRD_PARTY"
cp -p "$ROOT/tools/launch.R" "$STAGE/tools/launch.R"
ditto "$ENGINE_DIR/." "$STAGE/engine"

# Copy the complete tested R framework version, then expose it through the
# standard Current symlink expected by R's internal directory layout.
ditto "$R_VERSION_ROOT/." "$STAGE/runtime/R.framework/Versions/$R_VERSION"
( cd "$STAGE/runtime/R.framework/Versions" && ln -s "$R_VERSION" Current )

cp -p "$ROOT/tools/bundled_rscript.sh" "$STAGE/runtime/Rscript"
cp -p "$ROOT/tools/bundled_rscript.sh" \
  "$STAGE/runtime/R.framework/Versions/$R_VERSION/Resources/bin/Rscript"
cp -p "$ROOT/tools/bundled_rscript.sh" \
  "$STAGE/runtime/R.framework/Versions/$R_VERSION/Resources/bin/R"
chmod 755 "$STAGE/runtime/Rscript" \
  "$STAGE/runtime/R.framework/Versions/$R_VERSION/Resources/bin/Rscript" \
  "$STAGE/runtime/R.framework/Versions/$R_VERSION/Resources/bin/R"

"$BUILDER_RSCRIPT" "$ROOT/tools/stage_r_packages.R" --target "$STAGE/library"
"$BUILDER_RSCRIPT" "$ROOT/tools/write_third_party_inventory.R" \
  --library "$STAGE/library" --target "$STAGE/THIRD_PARTY"

R_LIB="$STAGE/runtime/R.framework/Versions/$R_VERSION/Resources/lib"
R_EXEC="$STAGE/runtime/R.framework/Versions/$R_VERSION/Resources/bin/exec/R"
STAGED_R_HOME="$STAGE/runtime/R.framework/Versions/$R_VERSION/Resources"
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
done < <(find "$STAGE/runtime" -type f -print)

patch_package_macho() {
  local f="$1" dep base replacement
  [ -f "$f" ] || return 0
  file "$f" | grep -q 'Mach-O' || return 0
  while IFS= read -r dep; do
    [ -n "$dep" ] || continue
    case "$dep" in
      "$ORIG_R_LIB"/*)
        base=$(basename "$dep")
        replacement="@loader_path/../../../runtime/R.framework/Versions/$R_VERSION/Resources/lib/$base"
        install_name_tool -change "$dep" "$replacement" "$f" 2>/dev/null
        ;;
    esac
  done < <(otool -L "$f" | sed -n '2,$p' | sed -E 's/^[[:space:]]+([^ ]+).*/\1/')
  codesign -f -s - "$f" >/dev/null 2>&1 || true
}
while IFS= read -r f; do patch_package_macho "$f"; done < <(
  find "$STAGE/library" -type f \( -name '*.so' -o -name '*.dylib' \) -print)

# Remove compiler-installation rpaths from the bundled FVS files. The official
# executable already carries its Fortran libraries beside it; only @loader_path
# is valid in a moved release.
while IFS= read -r f; do
  file "$f" | grep -q 'Mach-O' || continue
  while IFS= read -r rp; do
    [ -n "$rp" ] || continue
    install_name_tool -delete_rpath "$rp" "$f" 2>/dev/null || true
  done < <(otool -l "$f" | awk '$1 == "path" && $2 ~ /^\// {print $2}')
  codesign -f -s - "$f" >/dev/null 2>&1 || true
done < <(find "$STAGE/engine" -type f -print)

# Fail the build if any staged extension still names the build machine's R.
leftovers=$(while IFS= read -r f; do
  file "$f" | grep -q 'Mach-O' || continue
  otool -L "$f" 2>/dev/null | grep -F "$ORIG_R_LIB" && echo " in $f"
done < <(find "$STAGE/runtime" "$STAGE/library" "$STAGE/engine" -type f -print) || true)
if [ -n "$leftovers" ]; then
  echo "Staged Mach-O files still depend on the build machine's R:" >&2
  echo "$leftovers" >&2
  exit 1
fi

VERSIONED_PLIST="$STAGE/uFVS.app/Contents/Info.plist"
cp -p "$ROOT/tools/macos_app_Info.plist" "$VERSIONED_PLIST"
sed -i '' -e "s#0.1.0#$VERSION#g" "$VERSIONED_PLIST"
cp -p "$ROOT/tools/macos_launcher.sh" "$STAGE/uFVS.app/Contents/MacOS/uFVS"
chmod 755 "$STAGE/uFVS.app/Contents/MacOS/uFVS"

"$BUILDER_RSCRIPT" "$ROOT/tools/write_build_info.R" \
  --root "$STAGE" --platform "macOS" --architecture "arm64" --engine-dir "$STAGE/engine" \
  --fvs-source-revision "$FVS_SOURCE_REVISION" --fvs-source-url "$FVS_SOURCE_URL" \
  --fvs-toolchain "$FVS_TOOLCHAIN"

if [ "$SKIP_SELF_TEST" -eq 0 ]; then
  UFVS_RELEASE=1 R_LIBS_USER="$STAGE/library" "$STAGE/runtime/Rscript" \
    "$ROOT/tools/release_self_test.R" --root "$STAGE"
fi

if [ "$SKIP_FVS_SMOKE_TEST" -eq 0 ]; then
  UFVS_RELEASE=1 R_LIBS_USER="$STAGE/library" "$STAGE/runtime/Rscript" \
    "$ROOT/tools/fvs_smoke_test.R" --root "$STAGE" --engine "$STAGE/engine/FVSsn"
  UFVS_RELEASE=1 R_LIBS_USER="$STAGE/library" "$STAGE/runtime/Rscript" \
    "$ROOT/tools/release_http_smoke_test.R" --root "$STAGE" --port 18765
fi

ZIP="$OUT_DIR/uFVS-macOS-arm64.zip"
rm -f "$ZIP"
ditto -c -k --norsrc --keepParent "$STAGE" "$ZIP"
echo "Created $ZIP"
