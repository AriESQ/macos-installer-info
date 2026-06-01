#!/usr/bin/env bash

# macOS APP Bundle Analysis Script
# Analyzes a .app bundle for architecture compatibility and Rosetta 2 behavior.
# Companion to analyze_pkg.sh — same diagnosis, but for drag-to-install apps
# (e.g. the .app inside a .dmg) rather than .pkg installers.
#
# Why this exists: an app can show a Rosetta 2 prompt on Apple Silicon even when
# its "main" binary looks native. Two common real-world causes this script
# surfaces:
#   1. The CFBundleExecutable is a tiny launcher stub (shell script, not Mach-O)
#      that re-execs the real binary — possibly under `arch -x86_64`.
#   2. The main executable is arm64, but a loaded dependency (framework, dylib,
#      .node / Python C-extension, XPC/helper) is x86_64-only and drags the
#      process into Rosetta at runtime.
#
# Usage: ./analyze_app.sh /path/to/Some.app

set -uo pipefail

APP="${1:-}"

if [ -z "$APP" ]; then
    echo "Usage: $0 <path-to-app-bundle.app>"
    exit 1
fi

APP="${APP%/}"   # strip a trailing slash so basename/paths stay clean

if [ ! -e "$APP" ]; then
    echo "❌ Error: Path not found: $APP"
    exit 1
fi

# Friendly redirects for the neighboring input types this repo handles.
case "$APP" in
    *.pkg)
        echo "❌ That's a .pkg installer, not a .app bundle."
        echo "   Use the installer analyzer instead:"
        echo "      ./analyze_pkg.sh \"$APP\""
        exit 1
        ;;
    *.dmg)
        echo "❌ That's a .dmg disk image, not a .app bundle."
        echo "   Mount it first, then point this script at the .app inside:"
        echo "      hdiutil attach \"$APP\""
        echo "      ./analyze_app.sh \"/Volumes/<name>/Some.app\""
        exit 1
        ;;
esac

if [ ! -d "$APP" ] || [ ! -f "$APP/Contents/Info.plist" ]; then
    echo "❌ Error: Not a .app bundle (no Contents/Info.plist): $APP"
    echo "   Expected a directory ending in .app containing Contents/Info.plist."
    exit 1
fi

echo "═══════════════════════════════════════════════════"
echo "macOS APP Bundle Analysis Report"
echo "═══════════════════════════════════════════════════"
echo ""

echo "📦 Bundle: $(basename "$APP")"
echo "🔍 Path:   $APP"
echo ""

stage_start() { STAGE_T0=$SECONDS; }
stage_end()   { echo "   ⏱  $((SECONDS - STAGE_T0))s"; }

INFO_PLIST="$APP/Contents/Info.plist"

# ----------------------------------------------------------------------------
# Bundle identity & architecture hints
# ----------------------------------------------------------------------------
echo "🪪  Bundle Identity:"
stage_start
BUNDLE_ID=$(defaults read "$INFO_PLIST" CFBundleIdentifier 2>/dev/null || true)
BUNDLE_VERSION=$(defaults read "$INFO_PLIST" CFBundleShortVersionString 2>/dev/null || true)
BUNDLE_BUILD=$(defaults read "$INFO_PLIST" CFBundleVersion 2>/dev/null || true)
MIN_OS=$(defaults read "$INFO_PLIST" LSMinimumSystemVersion 2>/dev/null || true)
ARCH_PRIORITY=$(defaults read "$INFO_PLIST" LSArchitecturePriority 2>/dev/null | tr -d '\n' || true)
REQ_NATIVE=$(defaults read "$INFO_PLIST" LSRequiresNativeExecution 2>/dev/null || true)
[ -n "$BUNDLE_ID" ]      && echo "   Bundle ID: $BUNDLE_ID"
[ -n "$BUNDLE_VERSION" ] && echo "   Version: $BUNDLE_VERSION"
[ -n "$BUNDLE_BUILD" ]   && echo "   Build: $BUNDLE_BUILD"
[ -n "$MIN_OS" ]         && echo "   Minimum macOS: $MIN_OS"
[ -n "$ARCH_PRIORITY" ]  && echo "   ⚠️  LSArchitecturePriority: $ARCH_PRIORITY (can bias slice selection)"
[ -n "$REQ_NATIVE" ]     && echo "   LSRequiresNativeExecution: $REQ_NATIVE (blocks Rosetta when true)"
stage_end
echo ""

# ----------------------------------------------------------------------------
# Main executable
# ----------------------------------------------------------------------------
echo "🚀 Main Executable:"
stage_start
MAIN_IS_MACHO=false
MAIN_IS_LAUNCHER=false
MAIN_HAS_NATIVE=false   # arm64 / arm64e present in the real main binary
MAIN_HAS_X86=false
ANY_ARM64E=false
RESOLVED_TARGET=""      # real binary a launcher stub re-execs (if resolvable)
TARGET_ARCHS=""

EXEC_NAME=$(defaults read "$INFO_PLIST" CFBundleExecutable 2>/dev/null || true)
if [ -z "$EXEC_NAME" ]; then
    echo "   ⚠️  CFBundleExecutable not set in Info.plist"
    MAIN_EXEC=""
else
    MAIN_EXEC="$APP/Contents/MacOS/$EXEC_NAME"
    echo "   CFBundleExecutable: $EXEC_NAME"
    if [ ! -f "$MAIN_EXEC" ]; then
        echo "   ⚠️  Declared executable not found at: $MAIN_EXEC"
        MAIN_EXEC=""
    else
        FTYPE=$(file -b "$MAIN_EXEC" 2>/dev/null || true)
        echo "   Type: $FTYPE"
        if echo "$FTYPE" | grep -q "Mach-O"; then
            MAIN_IS_MACHO=true
            ARCHS=$(lipo -archs "$MAIN_EXEC" 2>/dev/null || true)
            echo "   Architectures: $ARCHS"
            echo "$ARCHS" | grep -qE '\barm64(e)?\b' && MAIN_HAS_NATIVE=true
            echo "$ARCHS" | grep -qE '\bx86_64\b'    && MAIN_HAS_X86=true
            echo "$ARCHS" | grep -qE '\barm64e\b'    && ANY_ARM64E=true
            if $MAIN_HAS_NATIVE; then
                echo "   ✅ arm64 present in main executable"
            else
                echo "   ⚠️  arm64 NOT present in main executable"
            fi
        else
            # Not Mach-O — almost always a launcher stub that re-execs the real
            # binary. This is itself a frequent Rosetta cause (the stub or the
            # binary it calls is x86_64), so surface what it points at.
            MAIN_IS_LAUNCHER=true
            echo "   ⚠️  Main executable is NOT a Mach-O binary — it's a launcher stub."
            echo "      🔴 A script as CFBundleExecutable is itself a Rosetta trigger:"
            echo "         macOS's pre-launch arch check reads ONLY this file for a"
            echo "         native slice. A script has none, so LaunchServices offers to"
            echo "         install/use Rosetta — even when the real binary is arm64."
            if file -b "$MAIN_EXEC" 2>/dev/null | grep -qiE 'text|script'; then
                echo "      Launcher contents:"
                sed 's/^/         /' "$MAIN_EXEC" 2>/dev/null | head -40
                if grep -qE 'arch[[:space:]]+-x86_64|arch[[:space:]]+-arch[[:space:]]+x86_64' "$MAIN_EXEC" 2>/dev/null; then
                    echo "      🔴 Launcher invokes 'arch -x86_64' — it forces Rosetta explicitly."
                fi

                # Resolve the re-exec target: take the basename after `exec` and
                # find the matching Mach-O anywhere in the bundle. Robust to the
                # stub's own cd/$DIR path juggling (e.g. exec ./Foo after a cd).
                tgt=$(grep -oE 'exec[[:space:]]+[^ "]+' "$MAIN_EXEC" 2>/dev/null | head -1 | awk '{print $2}')
                tgt="${tgt#./}"
                tgt_base=$(basename "$tgt" 2>/dev/null)
                if [ -n "$tgt_base" ]; then
                    while IFS= read -r cand; do
                        file -b "$cand" 2>/dev/null | grep -q "Mach-O" || continue
                        RESOLVED_TARGET="$cand"
                        break
                    done < <(find "$APP" -type f -name "$tgt_base" 2>/dev/null)
                fi
            fi
            if [ -n "$RESOLVED_TARGET" ]; then
                TARGET_ARCHS=$(lipo -archs "$RESOLVED_TARGET" 2>/dev/null || true)
                echo "      → Re-execs real binary: ${RESOLVED_TARGET#"$APP"/}"
                echo "      → Real binary architectures: $TARGET_ARCHS"
                echo "$TARGET_ARCHS" | grep -qE '\barm64(e)?\b' && MAIN_HAS_NATIVE=true
                echo "$TARGET_ARCHS" | grep -qE '\bx86_64\b'    && MAIN_HAS_X86=true
                echo "$TARGET_ARCHS" | grep -qE '\barm64e\b'    && ANY_ARM64E=true
                if $MAIN_HAS_NATIVE; then
                    echo "      ✅ real binary has an arm64 slice"
                else
                    echo "      🔴 real binary is x86_64-only → the app runs under Rosetta 2"
                fi
            else
                echo "      (could not resolve the re-exec target automatically;"
                echo "       rely on the Mach-O sweep below for the verdict)"
            fi
        fi
    fi
fi
stage_end
echo ""

# ----------------------------------------------------------------------------
# Code signature + entitlements (best-effort)
# ----------------------------------------------------------------------------
echo "🔐 Code Signature:"
stage_start
if [ -n "${MAIN_EXEC:-}" ]; then
    CODESIGN_INFO=$(codesign -d -vv --entitlements - "$MAIN_EXEC" 2>&1 || true)
    TEAM_ID=$(echo "$CODESIGN_INFO" | grep "TeamIdentifier=" | cut -d= -f2)
    AUTHORITY=$(echo "$CODESIGN_INFO" | grep "Authority=" | head -1 | cut -d= -f2)
    [ -n "$TEAM_ID" ]   && echo "   Team ID: $TEAM_ID"
    [ -n "$AUTHORITY" ] && echo "   Signed by: $AUTHORITY"
    echo "$CODESIGN_INFO" | grep -q "flags=.*runtime" && echo "   ✅ Hardened Runtime enabled"
    echo "$CODESIGN_INFO" | grep -q "not signed"      && echo "   ⚠️  Not signed"
else
    echo "   (no main executable resolved; skipping)"
fi
stage_end
echo ""

# ----------------------------------------------------------------------------
# Deep Mach-O sweep — the core of the analyzer.
# Walk every regular file in the bundle, keep the Mach-O objects, record archs,
# and bucket anything missing an arm64 (or arm64e) slice. Mirrors the helper
# sweep in analyze_pkg.sh.
# ----------------------------------------------------------------------------
echo "🔬 Deep Mach-O Sweep:"
stage_start
SWEEP="/tmp/app_analysis_$(date +%s).txt"
: > "$SWEEP"

MACHO_COUNT=0
INTEL_ONLY_COUNT=0
INTEL_ONLY_LIST=()

sweep_total=$(find "$APP" -type f 2>/dev/null | wc -l | tr -d ' ')
echo "   scanning $sweep_total files..."
sweep_i=0
while IFS= read -r f; do
    sweep_i=$((sweep_i+1))
    if [ $((sweep_i % 200)) -eq 0 ]; then
        printf '\r      %d / %d files checked' "$sweep_i" "$sweep_total" >&2
    fi
    [ -f "$f" ] || continue
    file -b "$f" 2>/dev/null | grep -q "Mach-O" || continue
    archs=$(lipo -archs "$f" 2>/dev/null || true)
    [ -z "$archs" ] && continue
    MACHO_COUNT=$((MACHO_COUNT+1))
    echo "$archs" | grep -qE '\barm64e\b' && ANY_ARM64E=true
    rel="${f#"$APP"/}"
    if echo "$archs" | grep -qE '\bx86_64\b' && ! echo "$archs" | grep -qE '\barm64(e)?\b'; then
        INTEL_ONLY_COUNT=$((INTEL_ONLY_COUNT+1))
        INTEL_ONLY_LIST+=("$rel")
        printf 'NOARM | %-20s | %s\n' "$archs" "$rel" >> "$SWEEP"
    else
        printf 'OK    | %-20s | %s\n' "$archs" "$rel" >> "$SWEEP"
    fi
done < <(find "$APP" -type f 2>/dev/null)
if [ "$sweep_total" -ge 200 ]; then
    printf '\r      %d / %d files checked\n' "$sweep_i" "$sweep_total" >&2
fi

echo "   Mach-O objects found: $MACHO_COUNT (of $sweep_total files)"
echo "   Intel-only (x86_64, no arm64): $INTEL_ONLY_COUNT"
if ((${#INTEL_ONLY_LIST[@]} > 0)); then
    echo "   x86_64-only objects (likely Rosetta triggers):"
    for rel in "${INTEL_ONLY_LIST[@]}"; do
        case "$rel" in
            *.app/Contents/MacOS/*) kind="helper app" ;;
            *.framework/*)          kind="framework" ;;
            *.node)                 kind="native node addon" ;;
            *.dylib)                kind="dylib" ;;
            *.so)                   kind="shared object / python ext" ;;
            *.xpc/*)                kind="xpc service" ;;
            *.bundle/*|*.bundle)    kind="plug-in bundle" ;;
            *)                      kind="mach-o" ;;
        esac
        echo "      - $rel  ($kind)"
    done
fi
$ANY_ARM64E && echo "   ℹ️  arm64e slice present (Apple PAC ABI — native on Apple Silicon)"
stage_end
echo ""

# ----------------------------------------------------------------------------
# Runtime Rosetta triggers (best-effort).
# A bundle can be 100% arm64 and STILL prompt for Rosetta because of things a
# static arch scan can't see: a launcher that explicitly runs `arch -x86_64`,
# or a per-user "Open using Rosetta" override in Get Info (LaunchServices).
# These checks surface those.
# ----------------------------------------------------------------------------
echo "🧭 Runtime Rosetta Triggers (best-effort):"
stage_start
ARCH_FORCE_HITS=0      # explicit `arch -x86_64` invocations found in bundle scripts
LSREG_ROSETTA=false    # LaunchServices shows a Rosetta override for this bundle

# 1. Explicit translation forcing in any text/script inside the bundle.
#    Matches: `arch -x86_64 …`, `arch -arch x86_64 …`.
ARCH_FORCE_MATCHES=$(grep -RInE 'arch[[:space:]]+(-arch[[:space:]]+)?x86_64' "$APP" 2>/dev/null \
    | grep -viE 'Binary file' | head -20)
if [ -n "$ARCH_FORCE_MATCHES" ]; then
    ARCH_FORCE_HITS=$(printf '%s\n' "$ARCH_FORCE_MATCHES" | grep -c .)
    echo "   🔴 Found $ARCH_FORCE_HITS explicit 'arch -x86_64' invocation(s) — these force Rosetta:"
    printf '%s\n' "$ARCH_FORCE_MATCHES" | sed "s#$APP/#      #"
else
    echo "   ✅ No explicit 'arch -x86_64' forcing found in bundle scripts."
fi

# 2. Per-user "Open using Rosetta" override (Get Info checkbox), stored in the
#    LaunchServices database. There is no public API for it, so parse lsregister.
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREG" ]; then
    # Grab the dump lines around this bundle's path, then look for an arch hint.
    LS_ENTRY=$("$LSREG" -dump 2>/dev/null \
        | grep -F -A 25 "$APP" \
        | grep -iE 'arch|rosetta|translated|path:' | head -20)
    if printf '%s\n' "$LS_ENTRY" | grep -qiE 'x86_64|rosetta|translated'; then
        LSREG_ROSETTA=true
        echo "   🔴 LaunchServices records a Rosetta/x86_64 preference for this app:"
        printf '%s\n' "$LS_ENTRY" | sed 's/^/      /'
    else
        echo "   ✅ No 'Open using Rosetta' override recorded in LaunchServices."
    fi
    echo "      (To inspect/clear manually: Finder → Get Info → uncheck"
    echo "       'Open using Rosetta'. It is per-user state, not part of the .app.)"
else
    echo "   ℹ️  lsregister not found; skipped the 'Open using Rosetta' check."
fi

# 3. Is Rosetta even present? (If not, a "prompt" is the install offer itself.)
if /usr/bin/pgrep -q oahd 2>/dev/null || [ -d /Library/Apple/usr/libexec/oah ]; then
    echo "   ℹ️  Rosetta 2 is installed on this Mac."
else
    echo "   ℹ️  Rosetta 2 not detected — a prompt would be the install offer."
fi

echo "   Note: causes invisible to static analysis remain possible —"
echo "   downloaded/extracted Intel helpers, or a dlopen that relaunches under"
echo "   Rosetta when an arch-matched library is missing at runtime."
stage_end
echo ""

# ----------------------------------------------------------------------------
# Summary & verdict
# ----------------------------------------------------------------------------
echo "═══════════════════════════════════════════════════"
echo "📊 Summary & Recommendations"
echo "═══════════════════════════════════════════════════"
echo "Bundle: $(basename "$APP")"
echo "Mach-O objects: $MACHO_COUNT   |   x86_64-only: $INTEL_ONLY_COUNT"
echo ""

if $MAIN_IS_LAUNCHER; then
    # CFBundleExecutable is a stub; the verdict rests on the real re-exec target
    # (resolved above) plus the dependency sweep.
    echo "⚠️  MAIN EXECUTABLE IS A LAUNCHER STUB (not Mach-O)"
    echo "   - CFBundleExecutable is a script that re-execs the real binary."
    if [ -n "$RESOLVED_TARGET" ]; then
        echo "   - Real binary: ${RESOLVED_TARGET#"$APP"/}  [${TARGET_ARCHS:-unknown}]"
    fi

    if $MAIN_HAS_X86 && ! $MAIN_HAS_NATIVE; then
        echo "   - The real binary is x86_64-only → the app runs under Rosetta 2."
        echo "     The prompt is EXPECTED here, not a false positive."
        echo ""
        echo "   FIX (developer): ship a universal2 (arm64 + x86_64) real binary"
        echo "   and re-exec it natively; drop any 'arch -x86_64' in the launcher."
    elif $MAIN_HAS_NATIVE && [ "$INTEL_ONLY_COUNT" -gt 0 ]; then
        echo "   - The real binary IS arm64-native, but $INTEL_ONLY_COUNT bundled Mach-O"
        echo "     object(s) are x86_64-only (listed above). Loading one of these"
        echo "     drags the process into Rosetta 2 — a prompt on a 'native' app."
        echo ""
        echo "   FIX (developer): rebuild those dependencies as universal2/arm64."
        echo "   Common culprits: vendored dylibs, plug-ins, native addons, helpers."
        echo ""
        echo "   Inspect one offender with:"
        echo "      lipo -archs \"$APP/<path-from-list-above>\""
    elif $MAIN_HAS_NATIVE; then
        echo "   - Real binary is arm64 and no x86_64-only Mach-O was found."
        echo "   - 🔴 ROOT CAUSE: CFBundleExecutable is a script, not an arm64 Mach-O."
        echo "        Before launch, macOS inspects only Contents/MacOS/<exec> for a"
        echo "        native slice; a script has none, so it prompts for Rosetta even"
        echo "        though the app is actually arm64-native."
        echo "        FIX (developer): make CFBundleExecutable a real arm64/universal"
        echo "        Mach-O — point it at the real binary, or ship a tiny COMPILED"
        echo "        trampoline instead of a shell script."
        if [ -n "$RESOLVED_TARGET" ]; then
            echo "        WORKAROUND (user): run the inner binary directly to confirm it"
            echo "        runs natively without Rosetta:"
            echo "          \"$RESOLVED_TARGET\""
        fi
        if [ "$ARCH_FORCE_HITS" -gt 0 ]; then
            echo "   - Also: the bundle forces 'arch -x86_64' (see above) — drop it too."
        fi
        if $LSREG_ROSETTA; then
            echo "   - Also: 'Open using Rosetta' is set (Get Info) — uncheck it."
        fi
    elif [ "$INTEL_ONLY_COUNT" -gt 0 ] && [ "$INTEL_ONLY_COUNT" -eq "$MACHO_COUNT" ]; then
        echo "   - Could not resolve the target, but every Mach-O in the bundle is"
        echo "     x86_64-only → the app runs under Rosetta 2 by necessity."
    else
        echo "   - Could not resolve the target binary's architecture automatically."
        echo "     Use the Mach-O sweep above; $INTEL_ONLY_COUNT object(s) are x86_64-only."
    fi

elif $MAIN_IS_MACHO && ! $MAIN_HAS_NATIVE && $MAIN_HAS_X86; then
    echo "ℹ️  INTEL-ONLY APP"
    echo "   - The main executable has no arm64 slice; it runs under Rosetta 2."
    echo "   - A Rosetta prompt here is correct, not a false positive."
    echo ""
    echo "   FIX (developer): ship a universal2 main executable."

elif $MAIN_IS_MACHO && $MAIN_HAS_NATIVE && [ "$INTEL_ONLY_COUNT" -gt 0 ]; then
    echo "⚠️  MISMATCH DETECTED"
    echo "   - The main executable IS arm64-native."
    echo "   - But $INTEL_ONLY_COUNT bundled Mach-O object(s) are x86_64-only (listed above)."
    echo "   - When the app loads or relaunches into one, macOS falls back to"
    echo "     Rosetta 2 — a Rosetta prompt on an otherwise-native app."
    echo ""
    echo "   FIX (developer): rebuild the offending dependencies as universal2/arm64."
    echo "   Common culprits: native Node addons (.node), Python C-extensions (.so),"
    echo "   vendored dylibs, and bundled helper apps / XPC services."
    echo ""
    echo "   Inspect one offender with:"
    echo "      lipo -archs \"$APP/<path-from-list-above>\""

elif $MAIN_IS_MACHO && $MAIN_HAS_NATIVE; then
    if [ "$ARCH_FORCE_HITS" -gt 0 ]; then
        echo "⚠️  NATIVE BINARY, BUT ROSETTA IS FORCED"
        echo "   - Main executable includes arm64 and no x86_64-only Mach-O exists,"
        echo "     but the bundle runs 'arch -x86_64' (see above) → forced Rosetta."
        echo "   FIX (developer): remove the 'arch -x86_64' wrapper."
    elif $LSREG_ROSETTA; then
        echo "⚠️  NATIVE BINARY, BUT 'OPEN USING ROSETTA' IS SET"
        echo "   - The app is arm64-native; the Rosetta prompt comes from the"
        echo "     per-user Get Info override, not the app."
        echo "   FIX (user): Finder → Get Info → uncheck 'Open using Rosetta'."
    else
        echo "✅ NATIVE — no Rosetta expected"
        echo "   - Main executable includes arm64, and no x86_64-only Mach-O was found."
        echo "   - No 'arch -x86_64' forcing and no LaunchServices override detected."
    fi

else
    echo "ℹ️  Unable to classify automatically"
    echo "   - main is Mach-O:      $MAIN_IS_MACHO"
    echo "   - main is launcher:    $MAIN_IS_LAUNCHER"
    echo "   - main arm64/arm64e:   $MAIN_HAS_NATIVE"
    echo "   - main x86_64:         $MAIN_HAS_X86"
    echo "   - x86_64-only Mach-O:  $INTEL_ONLY_COUNT"
fi

echo ""
echo "Full sweep written to: $SWEEP"
echo "   grep '^NOARM' \"$SWEEP\"   # re-list x86_64-only objects"
echo "To clean up:  trash \"$SWEEP\"      # preferred"
echo "          or  rm -f \"$SWEEP\""
echo ""
