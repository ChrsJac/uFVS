# Connecting an FVS engine

The downloadable desktop releases include a platform-specific official FVS
executable beside the application. A source checkout may instead use an
external executable or shared-library build.

Without an engine, uFVS still does everything on the inventory side — import,
validation, sampling design, statistics, product classes by diameter and
species, keyword generation. What it will not do is produce a projection or a
volume, because those are FVS calculations and uFVS does not estimate them.

## Option 1 — an official release build

For a downloaded uFVS release, no engine setup is needed. The release launcher
uses the native engine in its `engine` folder and ignores saved developer engine
settings. The remaining options apply to a source checkout.

Check the FVS website and repository for prebuilt binaries for your platform:

- https://www.fs.usda.gov/fvs/
- https://github.com/USDAForestService/ForestVegetationSimulator/releases

Install it, then in uFVS go to **Run Settings** and set:

- Engine: `FVS executable`
- Path: the full path to the variant executable, e.g. `/usr/local/FVSbin/FVSsn`

uFVS invokes it as `FVSsn --keywordfile=run.key` inside the run directory, which
is the documented command-line interface (`base/cmdline.f`).

### Windows

The official [FVS Software Complete Package](https://www.fs.usda.gov/fvs/software/complete.php)
provides native Windows executables. Install it, then either let uFVS discover
the usual `C:\FVS` directory or choose the required `FVS*.exe` on the Run page.
If a portable copy is preferred, place the executable in uFVS's `engine` folder;
Windows files must have the `.exe` suffix (for example `engine/FVSsn.exe`).

The macOS executable shipped in this development copy is not a Windows binary
and is ignored by the Windows engine detector.

## Option 2 — build from source on macOS

The FVS build needs a Fortran compiler and CMake, neither of which ships with
macOS. **This machine currently has neither**, so these steps have not been run
here.

```bash
# 1. Toolchain (installs gfortran as part of gcc)
brew install gcc cmake
```

If Homebrew itself is not installed, get it from https://brew.sh first. The
Homebrew install and `brew install` steps need your password, so run them
yourself rather than delegating them.

```bash
# 2. Source
git clone https://github.com/USDAForestService/ForestVegetationSimulator.git
cd ForestVegetationSimulator/bin

# 3. Configure and build one or more variants.
#    Variant codes are the two-letter directory names in the source root:
#    sn = Southern, ne = Northeast, ls = Lake States, pn = Pacific Northwest, ...
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --target FVSsn -j4
```

Consult the project's own build notes before relying on these commands — the
FVS wiki is authoritative and the build system changes:
https://github.com/USDAForestService/ForestVegetationSimulator/wiki

Then point uFVS at the resulting executable, as in Option 1.

## Option 3 — shared libraries (rFVS style)

If you have built FVS as shared libraries (`FVSsn.dylib`, `FVSsn.so`,
`FVSsn.dll`), set:

- Engine: `FVS shared libraries (rFVS style)`
- Path: the directory containing them

uFVS loads the library **inside the worker process**, never inside the
interface, so a fault in the engine cannot take the application down.

## Verifying the connection

**Run Settings** shows what uFVS found: the path, whether it is executable, and
which variants are available. The status also appears in the left sidebar and
the status bar at all times, so an unconfigured engine is never a surprise.

## What happens when a run fails

By design, nothing bad. FVS runs in a separate OS process created by `callr`,
in its own directory:

```
runs/20260814_180238_374e62/
  FVS_Data.db        input database uFVS wrote
  run.key            keyword file uFVS wrote
  run.json           engine path, input hash, keyword hash, platform, status
  FVSOut.db          FVS output, if it got that far
  fvs_stdout.log     engine output
  fvs_stderr.log     engine errors
  worker_stdout.log  worker output
```

If the engine exits non-zero — or segfaults — uFVS reports the exit status, the
stage it failed at, and the engine messages, then offers Retry, edit the
offending activity, view the log, or open the run folder. Your project, edits
and loaded data are untouched. This is tested: see `tests/test_runner.R`.

In batch mode each stand is its own job, so one bad stand does not stop the
others.

## Reproducibility

Every run records the uFVS version, engine mode and path, variant, input hash,
keyword hash, R version, platform, and timestamps in `run.json`. FVS and the
volume libraries change over time, so a result is only meaningful alongside a
record of what produced it.

The mutable engine setting, project JSON, and run folders are stored under the
user's application-data directory when the application folder is not writable.
This is why a copy of uFVS can be unzipped and run without writing to `Program
Files` or `/opt`.
