#!/usr/bin/env bash

# macOS PKG Installer Analysis Script
# Analyzes .pkg files for architecture compatibility and Rosetta 2 requirements.
# Usage: ./analyze_pkg.sh YourInstaller.pkg

set -uo pipefail

PKG="${1:-}"
ANALYSIS_DIR="/tmp/pkg_analysis_$(date +%s)"

if [ -z "$PKG" ]; then
    echo "Usage: $0 <path-to-installer.pkg>"
    exit 1
fi

if [ ! -e "$PKG" ]; then
    echo "❌ Error: File not found: $PKG"
    exit 1
fi

# Accept flat .pkg (xar archive), bundle .pkg (directory with Distribution/PackageInfo),
# or a Bill of Materials / Installer package per `file`.
INPUT_KIND=""
if [ -d "$PKG" ]; then
    if [ -f "$PKG/Distribution" ] || [ -f "$PKG/PackageInfo" ]; then
        INPUT_KIND="bundle"
    fi
fi
FILE_TYPE=$(file "$PKG")
if [ -z "$INPUT_KIND" ]; then
    if echo "$FILE_TYPE" | grep -qE "xar archive|Bill of Materials|Installer package"; then
        INPUT_KIND="flat"
    fi
fi
if [ -z "$INPUT_KIND" ]; then
    echo "❌ Error: File does not appear to be a macOS installer package"
    echo "   File type detected: $FILE_TYPE"
    echo ""
    echo "Expected one of:"
    echo "  - xar archive (flat package)"
    echo "  - Bill of Materials (component package)"
    echo "  - Installer package"
    echo "  - directory containing Distribution or PackageInfo (bundle package)"
    exit 1
fi

echo "═══════════════════════════════════════════════════"
echo "macOS PKG Installer Analysis Report"
echo "═══════════════════════════════════════════════════"
echo ""

echo "📦 Package: $(basename "$PKG")"
echo "🔍 File Type:"
echo "   $FILE_TYPE"
echo "   Input kind: $INPUT_KIND pkg"
echo ""

echo "🔐 Signature Status:"
pkgutil --check-signature "$PKG" 2>&1 | head -10
echo ""

echo "📂 Expanding package for analysis..."
if [ "$INPUT_KIND" = "bundle" ]; then
    # Bundle pkgs are already an expanded tree on disk; copy so the rest of the script
    # can treat it identically to a `pkgutil --expand` output.
    mkdir -p "$ANALYSIS_DIR"
    cp -R "$PKG"/. "$ANALYSIS_DIR/"
else
    if ! pkgutil --expand "$PKG" "$ANALYSIS_DIR"; then
        echo "❌ Error: Failed to expand package"
        exit 1
    fi
fi
echo "   → Expanded to: $ANALYSIS_DIR"
echo ""

# Distribution XML — parse with xmllint, not grep.
HAS_DISTRIBUTION=false
DIST_ARCH=""
echo "🏗️  Architecture Configuration:"
if [ -f "$ANALYSIS_DIR/Distribution" ]; then
    HAS_DISTRIBUTION=true
    DIST_ARCH=$(xmllint --xpath 'string(//options/@hostArchitectures)' "$ANALYSIS_DIR/Distribution" 2>/dev/null || true)
    if [ -n "$DIST_ARCH" ]; then
        echo "   hostArchitectures: $DIST_ARCH"
        if echo "$DIST_ARCH" | grep -qE 'arm64(e)?'; then
            echo "   ✅ arm64 support declared"
        else
            echo "   ⚠️  arm64 NOT declared — Installer.app will prompt for Rosetta"
        fi
    else
        echo "   ⚠️  Distribution present but hostArchitectures attribute is missing"
        echo "      → Installer.app will prompt for Rosetta on Apple Silicon"
    fi
else
    echo "   ℹ️  No Distribution file (single-component package)"
fi
echo ""

# Per-component extraction with format dispatch.
COMPONENTS=()
EXTRACTION_FAIL=()      # components whose Payload could not be extracted
STUB_COMPONENTS=()      # components classified as stub/downloader
declare -a PAYLOAD_NOTES=()

cd "$ANALYSIS_DIR"

extract_payload() {
    # $1: component dir (cwd is component dir on entry)
    local component="$1"
    local file_desc
    file_desc=$(file -b Payload 2>/dev/null || echo "missing")

    case "$file_desc" in
        *gzip*)
            if gunzip -dc Payload | cpio -id --quiet; then
                return 0
            else
                PAYLOAD_NOTES+=("$component: gzip+cpio extraction failed")
                return 1
            fi
            ;;
        *cpio*)
            if cpio -id --quiet < Payload; then
                return 0
            else
                PAYLOAD_NOTES+=("$component: raw cpio extraction failed")
                return 1
            fi
            ;;
        *)
            local magic
            magic=$(head -c 4 Payload 2>/dev/null | xxd -p)
            case "$magic" in
                70627a78*)  # "pbzx"
                    PAYLOAD_NOTES+=("$component: pbzx Payload — Stage 3 will lazy-check uvx; extraction skipped")
                    return 1
                    ;;
                fd377a58*)  # xz magic
                    PAYLOAD_NOTES+=("$component: xz-compressed Payload — Stage 3 will lazy-check uvx/xz; extraction skipped")
                    return 1
                    ;;
                *)
                    PAYLOAD_NOTES+=("$component: unknown Payload format ($file_desc, magic=$magic)")
                    return 1
                    ;;
            esac
            ;;
    esac
}

postflight_has_network_primitive() {
    # $1: path to component's Scripts dir
    local scripts_dir="$1"
    [ -d "$scripts_dir" ] || return 1
    grep -REl --include='postinstall*' --include='postflight*' \
        -e 'curl ' -e 'wget ' -e 'softwareupdate' \
        -e 'installer .* http' -e 'https?://' \
        "$scripts_dir" 2>/dev/null | head -1
}

echo "📦 Extracting payloads..."
shopt -s nullglob
for component in */; do
    component="${component%/}"
    if [ ! -d "$component" ] || [ ! -f "$component/PackageInfo" ]; then
        continue   # not a sub-package (e.g. Resources/)
    fi
    COMPONENTS+=("$component")
    if [ ! -f "$component/Payload" ]; then
        PAYLOAD_NOTES+=("$component: no Payload file (scripts-only component)")
        continue
    fi
    echo "   Processing: $component"
    pushd "$component" >/dev/null
    if ! extract_payload "$component"; then
        EXTRACTION_FAIL+=("$component")
    fi
    popd >/dev/null
done
shopt -u nullglob
echo ""

if [ ${#PAYLOAD_NOTES[@]} -gt 0 ]; then
    echo "📝 Payload notes:"
    for note in "${PAYLOAD_NOTES[@]}"; do
        echo "   - $note"
    done
    echo ""
fi

# Stub/downloader detection: component with no Payload extraction artifacts AND
# postflight that calls network primitives.
echo "🕸️  Stub/downloader scan:"
for component in "${COMPONENTS[@]}"; do
    # Count Mach-O files and staged archives under this component.
    macho_count=0
    staged_count=0
    if [ -d "$component" ]; then
        while IFS= read -r f; do
            file "$f" 2>/dev/null | grep -q "Mach-O" && macho_count=$((macho_count+1))
        done < <(find "$component" -type f \( ! -name 'PackageInfo' ! -name 'Bom' ! -name 'Payload' \) 2>/dev/null)
        staged_count=$(find "$component" -type f \( -name '*.tgz' -o -name '*.tar.gz' -o -name '*.zip' -o -name '*.pkg' -o -name '*.dmg' \) 2>/dev/null | wc -l | tr -d ' ')
    fi
    if [ "$macho_count" -eq 0 ] && [ "$staged_count" -eq 0 ]; then
        net_hit=$(postflight_has_network_primitive "$component/Scripts" || true)
        if [ -n "$net_hit" ]; then
            STUB_COMPONENTS+=("$component")
            echo "   ⚠️  $component looks like a stub/downloader:"
            echo "      postflight $net_hit contains network primitive"
            grep -nE 'curl |wget |softwareupdate|https?://' "$net_hit" 2>/dev/null | head -3 | sed 's/^/         /'
        fi
    fi
done
if [ ${#STUB_COMPONENTS[@]} -eq 0 ]; then
    echo "   (none detected)"
fi
echo ""

# Recursive Mach-O walk: collect arch info across every Mach-O on disk,
# not just main app executables.
echo "🔬 Binary Architecture Analysis:"

MAIN_EXEC_HAS_NATIVE=false   # any main .app exec ships arm64/arm64e
MAIN_EXEC_HAS_X86=false
HELPER_INTEL_ONLY_COUNT=0    # count of Mach-O files (any kind) that are x86_64-only
HELPER_INTEL_ONLY_LIST=()
ANY_ARM64E=false

while IFS= read -r app; do
    INFO_PLIST="$app/Contents/Info.plist"
    [ -f "$INFO_PLIST" ] || continue
    exec_name=$(defaults read "$INFO_PLIST" CFBundleExecutable 2>/dev/null || true)
    [ -n "$exec_name" ] || continue
    MAIN_EXEC="$app/Contents/MacOS/$exec_name"
    echo ""
    echo "   Application: $(basename "$app")"
    if [ ! -f "$MAIN_EXEC" ]; then
        echo "   (main executable not found at $MAIN_EXEC)"
        continue
    fi
    echo "   Main Executable: $(basename "$MAIN_EXEC")"
    ftype=$(file -b "$MAIN_EXEC")
    echo "   Type: $(echo "$ftype" | head -1)"
    if echo "$ftype" | grep -q "Mach-O"; then
        archs=$(lipo -archs "$MAIN_EXEC" 2>/dev/null || true)
        echo "   Architectures: $archs"
        echo "$archs" | grep -qE '\barm64(e)?\b' && MAIN_EXEC_HAS_NATIVE=true
        echo "$archs" | grep -qE '\bx86_64\b' && MAIN_EXEC_HAS_X86=true
        echo "$archs" | grep -qE '\barm64e\b' && ANY_ARM64E=true
    fi

    # Code sign + entitlements (best-effort, kept brief).
    CODESIGN_INFO=$(codesign -d -vv --entitlements - "$MAIN_EXEC" 2>&1 || true)
    TEAM_ID=$(echo "$CODESIGN_INFO" | grep "TeamIdentifier=" | cut -d= -f2)
    AUTHORITY=$(echo "$CODESIGN_INFO" | grep "Authority=" | head -1 | cut -d= -f2)
    [ -n "$TEAM_ID" ] && echo "      Team ID: $TEAM_ID"
    [ -n "$AUTHORITY" ] && echo "      Signed by: $AUTHORITY"
    echo "$CODESIGN_INFO" | grep -q "flags=.*runtime" && echo "      ✅ Hardened Runtime enabled"

    # Bundle metadata.
    BUNDLE_ID=$(defaults read "$INFO_PLIST" CFBundleIdentifier 2>/dev/null || true)
    BUNDLE_VERSION=$(defaults read "$INFO_PLIST" CFBundleShortVersionString 2>/dev/null || true)
    MIN_OS=$(defaults read "$INFO_PLIST" LSMinimumSystemVersion 2>/dev/null || true)
    [ -n "$BUNDLE_ID" ] && echo "      Bundle ID: $BUNDLE_ID"
    [ -n "$BUNDLE_VERSION" ] && echo "      Version: $BUNDLE_VERSION"
    [ -n "$MIN_OS" ] && echo "      Minimum macOS: $MIN_OS"
done < <(find "$ANALYSIS_DIR" -name '*.app' -type d 2>/dev/null)

echo ""
echo "🔎 Helper / dylib / XPC architecture sweep:"
# Walk every Mach-O file, regardless of +x bit. Count Intel-only ones —
# they're the legitimate-Rosetta signal even when the main exec is universal.
while IFS= read -r f; do
    [ -f "$f" ] || continue
    if file -b "$f" 2>/dev/null | grep -q "Mach-O"; then
        archs=$(lipo -archs "$f" 2>/dev/null || true)
        [ -z "$archs" ] && continue
        echo "$archs" | grep -qE '\barm64e\b' && ANY_ARM64E=true
        if echo "$archs" | grep -qE '\bx86_64\b' && ! echo "$archs" | grep -qE '\barm64(e)?\b'; then
            HELPER_INTEL_ONLY_COUNT=$((HELPER_INTEL_ONLY_COUNT+1))
            HELPER_INTEL_ONLY_LIST+=("${f#$ANALYSIS_DIR/}")
        fi
    fi
done < <(find "$ANALYSIS_DIR" -type f 2>/dev/null)

echo "   Intel-only Mach-O files (dylibs/XPC/helpers): $HELPER_INTEL_ONLY_COUNT"
if [ "$HELPER_INTEL_ONLY_COUNT" -gt 0 ]; then
    printf '      - %s\n' "${HELPER_INTEL_ONLY_LIST[@]:0:10}"
    [ "$HELPER_INTEL_ONLY_COUNT" -gt 10 ] && echo "      … and $((HELPER_INTEL_ONLY_COUNT - 10)) more"
fi
$ANY_ARM64E && echo "   ℹ️  arm64e slice present (Apple pointer-authentication ABI — native on Apple Silicon)"
echo ""

# Summary.
echo "═══════════════════════════════════════════════════"
echo "📊 Summary & Recommendations"
echo "═══════════════════════════════════════════════════"

# Branch 1: stub installer → result is non-comprehensive, refuse a clean verdict.
if [ ${#STUB_COMPONENTS[@]} -gt 0 ]; then
    echo "⚠️  RESULT NON-COMPREHENSIVE — stub/downloader installer detected"
    echo "   The following components have no on-disk binaries and use network primitives in postflight:"
    for c in "${STUB_COMPONENTS[@]}"; do echo "      - $c"; done
    echo ""
    echo "   The actual installed binaries are fetched at install time and cannot be statically analyzed."
    echo "   Re-run after the install has staged the real payload, or inspect what the postflight downloads."
    echo ""
elif [ ${#EXTRACTION_FAIL[@]} -gt 0 ] && ! $MAIN_EXEC_HAS_NATIVE && ! $MAIN_EXEC_HAS_X86 && [ "$HELPER_INTEL_ONLY_COUNT" -eq 0 ]; then
    # Branch 2: extraction failed for every component AND we found zero Mach-Os.
    echo "❌ EXTRACTION FAILED — verdict unreliable"
    echo "   Could not extract Payloads for: ${EXTRACTION_FAIL[*]}"
    echo "   Architecture verdict skipped to avoid a misleading result."
    echo ""
elif ! $HAS_DISTRIBUTION; then
    # Branch 3: single-component pkg, no Distribution. No mismatch to flag.
    echo "ℹ️  Component package (no Distribution)"
    echo "   This pkg has no Distribution XML, so there is no hostArchitectures to misconfigure."
    if $MAIN_EXEC_HAS_NATIVE && ! $MAIN_EXEC_HAS_X86; then
        echo "   Main binaries are Apple Silicon native only."
    elif $MAIN_EXEC_HAS_NATIVE && $MAIN_EXEC_HAS_X86; then
        echo "   Main binaries are universal (arm64 + x86_64)."
    elif $MAIN_EXEC_HAS_X86; then
        echo "   Main binaries are Intel only — Rosetta required."
    fi
    if [ "$HELPER_INTEL_ONLY_COUNT" -gt 0 ]; then
        echo "   $HELPER_INTEL_ONLY_COUNT Intel-only helper(s) — Rosetta may be invoked at runtime."
    fi
    echo ""
else
    # Branch 4: Distribution present — run the canonical mismatch check.
    DIST_DECLARES_ARM64=false
    echo "$DIST_ARCH" | grep -qE 'arm64(e)?' && DIST_DECLARES_ARM64=true

    if $MAIN_EXEC_HAS_NATIVE && ! $DIST_DECLARES_ARM64; then
        echo "⚠️  MISMATCH DETECTED"
        echo "   - App contains arm64 (and/or arm64e) binaries"
        echo "   - Distribution XML does NOT declare arm64 support (hostArchitectures='$DIST_ARCH')"
        echo "   - This will cause a FALSE Rosetta prompt on Apple Silicon"
        echo ""
        echo "   FIX: Add to Distribution XML:"
        echo "   <options hostArchitectures=\"x86_64,arm64\" />"
        if [ "$HELPER_INTEL_ONLY_COUNT" -gt 0 ]; then
            echo ""
            echo "   Note: $HELPER_INTEL_ONLY_COUNT Intel-only helper Mach-O(s) found — Rosetta will still be"
            echo "   invoked at runtime when those code paths execute, even after the installer fix."
        fi
    elif ! $MAIN_EXEC_HAS_NATIVE && $MAIN_EXEC_HAS_X86; then
        echo "ℹ️  Intel-Only Package"
        echo "   - Rosetta 2 will be required on Apple Silicon Macs"
        echo "   - This is expected behavior"
    elif $MAIN_EXEC_HAS_NATIVE && $DIST_DECLARES_ARM64; then
        echo "✅ Correctly Configured"
        echo "   - arm64-capable binaries + Distribution declares arm64"
        if [ "$HELPER_INTEL_ONLY_COUNT" -gt 0 ]; then
            echo "   - ⚠️  But $HELPER_INTEL_ONLY_COUNT Intel-only helper(s) will still invoke Rosetta at runtime"
        fi
    else
        echo "ℹ️  Unable to classify automatically"
        echo "   - Main-exec arm64/arm64e: $MAIN_EXEC_HAS_NATIVE"
        echo "   - Main-exec x86_64:       $MAIN_EXEC_HAS_X86"
        echo "   - Distribution arch:      ${DIST_ARCH:-<empty>}"
    fi
fi

echo ""
echo "Analysis complete. Expanded files at: $ANALYSIS_DIR"
echo "To clean up:  trash $ANALYSIS_DIR      # preferred"
echo "          or  rm -rf $ANALYSIS_DIR"
echo ""
