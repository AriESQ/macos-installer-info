#!/usr/bin/env bash
#
# Regression tests for analyze_pkg.sh.
#
# Builds synthetic .pkg fixtures with pkgbuild/productbuild and asserts on the
# analyzer's output. Synthetic rather than sampled on purpose: a fixture whose
# exact architecture mix we chose is the only way to assert precise counts, and
# real installers are multi-GB and cannot be committed.
#
#   ./tests/run_tests.sh
#
# Exits non-zero if any assertion fails.
#
# Requires clang to build the test binaries — the only way to produce an
# x86_64-only Mach-O on an Apple Silicon machine, since the system's own
# binaries carry no x86_64 slice to thin out. clang ships with the Xcode
# Command Line Tools; if it is absent these tests skip rather than fail, and
# analyze_pkg.sh itself still depends on nothing but stock macOS tools.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANALYZER="$REPO_ROOT/analyze_pkg.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pkg_analyzer_tests.XXXXXX")"

PASS=0
FAIL=0

cleanup() { [ -n "${KEEP_FIXTURES:-}" ] || rm -rf "$WORK"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------

# assert_contains <output-file> <fixed-string> <description>
assert_contains() {
    if grep -qF "$2" "$1"; then
        echo "   ✅ $3"
        PASS=$((PASS + 1))
    else
        echo "   ❌ $3"
        echo "      expected to find: $2"
        FAIL=$((FAIL + 1))
    fi
}

# assert_absent <output-file> <fixed-string> <description>
assert_absent() {
    if grep -qF "$2" "$1"; then
        echo "   ❌ $3"
        echo "      unexpectedly found: $2"
        FAIL=$((FAIL + 1))
    else
        echo "   ✅ $3"
        PASS=$((PASS + 1))
    fi
}

# ---------------------------------------------------------------------------
# Fixture construction
# ---------------------------------------------------------------------------

build_test_binaries() {
    printf 'int main(void){return 0;}\n' > "$WORK/t.c"
    clang -arch x86_64 -arch arm64 "$WORK/t.c" -o "$WORK/universal" 2>/dev/null || return 1
    clang -arch x86_64             "$WORK/t.c" -o "$WORK/intelonly" 2>/dev/null || return 1
    [ "$(lipo -archs "$WORK/universal")" = "x86_64 arm64" ] || return 1
    [ "$(lipo -archs "$WORK/intelonly")" = "x86_64" ]       || return 1
}

# write_app <app-dir> <exec-name> <binary>
write_app() {
    mkdir -p "$1/Contents/MacOS"
    cp "$3" "$1/Contents/MacOS/$2"
    cat > "$1/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>$2</string>
  <key>CFBundleIdentifier</key><string>com.test.$2</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
</dict></plist>
PLIST
}

# build_pkg <name> <root-dir> <hostArchitectures-attr-or-empty>
build_pkg() {
    local name="$1" root="$2" hostarch="$3"
    local dir="$WORK/$name"   # separate statement: bash 3.2 cannot read $name
    mkdir -p "$dir"           # from within the same `local` that declares it
    pkgbuild --root "$root" --identifier "com.test.$name" --version 1.0 \
        "$dir/$name-component.pkg" >/dev/null 2>&1 || return 1
    cat > "$dir/dist.xml" <<DIST
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="1">
  <title>$name</title>
  <options customize="never" rootVolumeOnly="true" $hostarch/>
  <choices-outline><line choice="default"/></choices-outline>
  <choice id="default"><pkg-ref id="com.test.$name"/></choice>
  <pkg-ref id="com.test.$name">$name-component.pkg</pkg-ref>
</installer-gui-script>
DIST
    productbuild --distribution "$dir/dist.xml" --package-path "$dir" \
        "$dir/$name.pkg" >/dev/null 2>&1 || return 1
    echo "$dir/$name.pkg"
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

# A universal app, hostArchitectures correctly declared, nothing staged. Guards
# the common path: the fixes for #2/#3/#4 must not disturb an ordinary package.
test_ordinary_package() {
    echo "▶️  Ordinary package (universal, hostArchitectures declared, no staged archives)"
    local root="$WORK/ordinary_root"
    write_app "$root/Applications/Plain.app" Plain "$WORK/universal"
    local pkg out
    pkg=$(build_pkg ordinary "$root" 'hostArchitectures="x86_64,arm64"') || {
        echo "   ❌ fixture build failed"; FAIL=$((FAIL + 1)); return
    }
    out="$WORK/ordinary.out"
    "$ANALYZER" "$pkg" > "$out" 2>&1

    assert_contains "$out" "(none found)"                                  "reports no staged archives"
    assert_contains "$out" "Intel-only Mach-O files (dylibs/XPC/helpers): 0" "finds no Intel-only Mach-O"
    assert_contains "$out" "Correctly Configured"                          "verdict is clean"
    assert_absent   "$out" "MISMATCH DETECTED"                             "does not report a false mismatch"
    assert_absent   "$out" "KERNEL EXTENSION"                              "does not invent a kext finding"
}

# One staged zip holding, deliberately: a kext (hard block), an AVX backend
# (inert by rule A), a Cpu/CpuFma pair (inert by rule B), and a plain Intel
# helper (a genuine Rosetta trigger). Exercises #2, #3 and #4 together.
test_staged_archive_grading() {
    echo "▶️  Staged archive with a kext, two inert backends, and a real helper"
    local root="$WORK/staged_root" staged="$WORK/staged_payload"
    mkdir -p "$staged/Library/Extensions/Widget.kext/Contents/MacOS" \
             "$staged/Library/Frameworks/Raw.framework/Libraries" \
             "$staged/Library/Helpers"
    cp "$WORK/intelonly" "$staged/Library/Extensions/Widget.kext/Contents/MacOS/Widget"
    cp "$WORK/intelonly" "$staged/Library/Frameworks/Raw.framework/Libraries/InstructionSetServicesAVX"
    cp "$WORK/universal" "$staged/Library/Frameworks/Raw.framework/Libraries/DecoderMetal"
    cp "$WORK/intelonly" "$staged/Library/Frameworks/Raw.framework/Libraries/libFooCpu_module.so"
    cp "$WORK/universal" "$staged/Library/Frameworks/Raw.framework/Libraries/libFooCpuFma_module.so"
    cp "$WORK/intelonly" "$staged/Library/Helpers/legacy_daemon"

    mkdir -p "$root/Library/Application Support/Test/Prereqs"
    ( cd "$staged" && zip -qr "$root/Library/Application Support/Test/Prereqs/prereq.zip" . )
    write_app "$root/Applications/Staged.app" Staged "$WORK/universal"

    local pkg out
    pkg=$(build_pkg staged "$root" '') || {
        echo "   ❌ fixture build failed"; FAIL=$((FAIL + 1)); return
    }
    out="$WORK/staged.out"
    "$ANALYZER" "$pkg" > "$out" 2>&1

    assert_contains "$out" "expanded: "                                      "expands the staged zip (#2)"
    assert_contains "$out" "Intel-only kernel extensions / DriverKit drivers: 1" "grades the kext separately (#3)"
    assert_contains "$out" "CANNOT RUN ON APPLE SILICON"                     "summary leads with the kext (#3)"
    assert_contains "$out" "inert on arm64 (never loaded, no Rosetta cost): 2" "finds both inert backends (#4)"
    assert_contains "$out" "x86-exclusive ISA in name"                       "inert rule A fires on AVX (#4)"
    assert_contains "$out" "dispatch family"                                 "inert rule B fires on Cpu/CpuFma (#4)"
    assert_contains "$out" "Intel-only Mach-O files (dylibs/XPC/helpers): 1" "counts only the genuine trigger (#4)"
    assert_contains "$out" "MISMATCH DETECTED"                               "flags the missing hostArchitectures"
}

# A staged .dmg must be reported and skipped, never auto-mounted, and the
# summary must admit the package was not fully analyzed.
test_staged_dmg_is_reported_not_mounted() {
    echo "▶️  Staged .dmg is reported and skipped, not mounted"
    local root="$WORK/dmg_root"
    mkdir -p "$root/Library/Application Support/Test/Prereqs"
    # Contents are irrelevant: the analyzer must refuse on the extension alone.
    echo "not a real disk image" > "$root/Library/Application Support/Test/Prereqs/thing.dmg"
    write_app "$root/Applications/Dmg.app" Dmg "$WORK/universal"

    local pkg out
    pkg=$(build_pkg dmgstage "$root" 'hostArchitectures="x86_64,arm64"') || {
        echo "   ❌ fixture build failed"; FAIL=$((FAIL + 1)); return
    }
    out="$WORK/dmgstage.out"
    "$ANALYZER" "$pkg" > "$out" 2>&1

    assert_contains "$out" "skipped:"                                  "reports the archive as skipped"
    assert_contains "$out" "hdiutil attach"                            "tells the user how to open it"
    assert_contains "$out" "staged prereq archive(s) were NOT analyzed" "summary admits the gap"
}

# ---------------------------------------------------------------------------

echo "═══════════════════════════════════════════════════"
echo "🧪 analyze_pkg.sh regression tests"
echo "═══════════════════════════════════════════════════"

if [ ! -x "$ANALYZER" ]; then
    echo "❌ analyze_pkg.sh not found or not executable at $ANALYZER"
    exit 1
fi

if ! command -v clang >/dev/null 2>&1; then
    echo "⏭️  SKIPPED — clang not available."
    echo "   These tests need clang to build x86_64-only and universal Mach-O"
    echo "   fixtures; an Apple Silicon Mac ships no x86_64 slice to thin out."
    echo "   Install the Xcode Command Line Tools: xcode-select --install"
    exit 0
fi

if ! build_test_binaries; then
    echo "❌ could not build test binaries (is the macOS SDK installed?)"
    exit 1
fi

echo ""
test_ordinary_package
echo ""
test_staged_archive_grading
echo ""
test_staged_dmg_is_reported_not_mounted

echo ""
echo "═══════════════════════════════════════════════════"
echo "   $PASS passed, $FAIL failed"
[ -n "${KEEP_FIXTURES:-}" ] && echo "   fixtures kept at $WORK"
echo "═══════════════════════════════════════════════════"
[ "$FAIL" -eq 0 ] || exit 1
