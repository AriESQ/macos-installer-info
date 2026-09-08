#!/usr/bin/env bash

# macOS PKG Installer Analysis Script
# Analyzes .pkg files for architecture compatibility and Rosetta 2 requirements.
# Usage: ./analyze_pkg.sh YourInstaller.pkg

set -uo pipefail

PKG="${1:-}"
# $$ as well as the timestamp: `date +%s` has one-second granularity, so two
# analyses started in the same second would collide — and pkgutil --expand
# refuses to write into a directory that already exists, aborting the run.
ANALYSIS_DIR="/tmp/pkg_analysis_$(date +%s)_$$"

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

stage_start() { STAGE_T0=$SECONDS; }
stage_end()   { echo "   ⏱  $((SECONDS - STAGE_T0))s"; }

echo "🔐 Signature Status:"
stage_start
pkgutil --check-signature "$PKG" 2>&1 | head -10
stage_end
echo ""

echo "📂 Expanding package for analysis..."
stage_start
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
stage_end
echo ""

# Distribution XML — parse with xmllint, not grep.
HAS_DISTRIBUTION=false
DIST_ARCH=""
echo "🏗️  Architecture Configuration:"
stage_start
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
stage_end
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

# Staged prereq archives.
#
# Some components install nothing directly; they drop an archive into
# .../Prereqs/ for a postflight script to unpack later. The binaries inside are
# invisible to the sweep below unless we expand them here, and they can hold the
# most severe finding in the whole installer — DaVinci Resolve 21.0.4 stages a
# zip whose only two Mach-O objects are Intel-only, one of them a kext.
#
# Expanded next to the archive as <archive>.expanded/ so everything lands under
# $ANALYSIS_DIR and the existing sweep picks it up with no further plumbing.
STAGED_EXPANDED=()      # archives expanded successfully
STAGED_SKIPPED=()       # archives found but not expanded, with reason

# Archives above this size are reported and skipped rather than expanded.
MAX_STAGED_MB="${MAX_STAGED_MB:-2048}"
STAGED_MAX_DEPTH=3      # archive → archive → archive; deep enough for real pkgs

expand_staged_archive() {
    # $1: archive path (relative to $ANALYSIS_DIR)  $2: component label
    # $3: current depth
    local archive="$1" component="$2" depth="$3"
    local dest="${archive}.expanded"
    local size_mb inner

    size_mb=$(( $(stat -f%z "$archive" 2>/dev/null || echo 0) / 1048576 ))
    if [ "$size_mb" -gt "$MAX_STAGED_MB" ]; then
        STAGED_SKIPPED+=("$archive (${size_mb}MB exceeds ${MAX_STAGED_MB}MB cap — set MAX_STAGED_MB to override)")
        return 1
    fi

    case "$archive" in
        *.dmg)
            # hdiutil attach mutates system state and can prompt for a licence
            # agreement; refuse rather than surprise the user mid-analysis.
            STAGED_SKIPPED+=("$archive (disk image — mount with 'hdiutil attach' and re-run against its contents)")
            return 1
            ;;
        *.tgz|*.tar.gz|*.tar)
            mkdir -p "$dest" || return 1
            if ! tar xf "$archive" -C "$dest" 2>/dev/null; then
                STAGED_SKIPPED+=("$archive (tar extraction failed)")
                return 1
            fi
            ;;
        *.zip)
            mkdir -p "$dest" || return 1
            if ! unzip -oq "$archive" -d "$dest" 2>/dev/null; then
                STAGED_SKIPPED+=("$archive (unzip failed)")
                return 1
            fi
            ;;
        *.pkg)
            # pkgutil insists on creating the destination itself.
            if ! pkgutil --expand "$archive" "$dest" >/dev/null 2>&1; then
                STAGED_SKIPPED+=("$archive (pkgutil --expand failed)")
                return 1
            fi
            ;;
        *)
            STAGED_SKIPPED+=("$archive (unrecognised archive type)")
            return 1
            ;;
    esac

    STAGED_EXPANDED+=("$archive")

    # A staged pkg has its own Payload (possibly several, one per component).
    # Run them back through the same format dispatch used for the outer pkg.
    while IFS= read -r inner; do
        [ -f "$inner/Payload" ] || continue
        ( cd "$inner" && extract_payload "$component → $(basename "$inner")" ) >/dev/null 2>&1 || true
    done < <(
        [ -f "$dest/Payload" ] && echo "$dest"
        find "$dest" -maxdepth 2 -type d -name '*.pkg' 2>/dev/null
    )

    # Recurse: staged tarballs routinely contain a pkg, which contains a Payload.
    expand_staged_tree "$dest" "$component" $((depth + 1))
    return 0
}

expand_staged_tree() {
    # $1: directory to scan  $2: component label  $3: current depth
    local dir="$1" component="$2" depth="$3" archive
    [ "$depth" -gt "$STAGED_MAX_DEPTH" ] && return 0
    while IFS= read -r archive; do
        expand_staged_archive "$archive" "$component" "$depth" || true
    done < <(find "$dir" -type f \
        \( -name '*.tgz' -o -name '*.tar.gz' -o -name '*.tar' \
           -o -name '*.zip' -o -name '*.pkg' -o -name '*.dmg' \) 2>/dev/null)
}

echo "📦 Extracting payloads..."
stage_start
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
stage_end
echo ""

if [ ${#PAYLOAD_NOTES[@]} -gt 0 ]; then
    echo "📝 Payload notes:"
    for note in "${PAYLOAD_NOTES[@]}"; do
        echo "   - $note"
    done
    echo ""
fi

# Expand staged prereq archives so their contents reach the sweep below.
echo "🎁 Staged prereq archives:"
stage_start
for component in "${COMPONENTS[@]}"; do
    expand_staged_tree "$component" "$component" 1
done
if [ ${#STAGED_EXPANDED[@]} -eq 0 ] && [ ${#STAGED_SKIPPED[@]} -eq 0 ]; then
    echo "   (none found)"
else
    for a in "${STAGED_EXPANDED[@]}"; do
        echo "   ✅ expanded: $a"
    done
    for a in "${STAGED_SKIPPED[@]}"; do
        echo "   ⚠️  skipped:  $a"
    done
fi
stage_end
echo ""

# Stub/downloader detection: component with no Payload extraction artifacts AND
# postflight that calls network primitives.
echo "🕸️  Stub/downloader scan:"
stage_start
for component in "${COMPONENTS[@]}"; do
    # Short-circuit: a stub component has NO Mach-O and NO staged archive.
    # As soon as we see either, this component is not a stub — stop scanning.
    has_macho=false
    has_staged=false
    if [ -d "$component" ]; then
        echo "   scanning $(basename "$component")..."
        if find "$component" -type f \( -name '*.tgz' -o -name '*.tar.gz' -o -name '*.zip' -o -name '*.pkg' -o -name '*.dmg' \) 2>/dev/null | grep -q .; then
            has_staged=true
        fi
        if ! $has_staged; then
            total=$(find "$component" -type f \( ! -name 'PackageInfo' ! -name 'Bom' ! -name 'Payload' \) 2>/dev/null | wc -l | tr -d ' ')
            i=0
            while IFS= read -r f; do
                i=$((i+1))
                if [ $((i % 200)) -eq 0 ]; then
                    printf '\r      %d / %d files checked' "$i" "$total" >&2
                fi
                if file "$f" 2>/dev/null | grep -q "Mach-O"; then
                    has_macho=true
                    break
                fi
            done < <(find "$component" -type f \( ! -name 'PackageInfo' ! -name 'Bom' ! -name 'Payload' \) 2>/dev/null)
            if [ "$total" -ge 200 ]; then
                printf '\r      %d / %d files checked\n' "$i" "$total" >&2
            fi
        fi
    fi
    if ! $has_macho && ! $has_staged; then
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
stage_end
echo ""

# Recursive Mach-O walk: collect arch info across every Mach-O on disk,
# not just main app executables.
echo "🔬 Binary Architecture Analysis:"
stage_start

MAIN_EXEC_HAS_NATIVE=false   # any main .app exec ships arm64/arm64e
MAIN_EXEC_HAS_X86=false
HELPER_INTEL_ONLY_COUNT=0    # count of Mach-O files (any kind) that are x86_64-only
HELPER_INTEL_ONLY_LIST=()
KEXT_INTEL_ONLY_LIST=()      # x86_64-only kexts/dexts — Rosetta cannot help these
INERT_INTEL_LIST=()          # x86_64-only, but provably never loaded on arm64
ROSETTA_INTEL_LIST=()        # x86_64-only and genuinely reachable → real Rosetta cost
ARM_CAPABLE_LIST=()          # every Mach-O carrying an arm64 slice (sibling lookups)
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

stage_end
echo ""
echo "🔎 Helper / dylib / XPC architecture sweep:"
stage_start
# Walk every Mach-O file, regardless of +x bit. Count Intel-only ones —
# they're the legitimate-Rosetta signal even when the main exec is universal.
#
# Classify in a SINGLE `file` pass over all paths (one process parses the magic
# DB once) instead of spawning `file` per file, then `lipo` only the Mach-O hits.
# `-F` gives each record as `path<SEP>description`; universal binaries emit extra
# "(for architecture …)" continuation lines that use the default ':' separator
# and therefore lack our SEP — we skip any line without it.
sweep_total=$(find "$ANALYSIS_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')
echo "   scanning $sweep_total files (single file pass)..."
SEP='@@FILEMAGIC@@'
macho_paths=()
while IFS= read -r line; do
    case "$line" in
        *"$SEP"*) ;;        # real record
        *) continue ;;      # continuation line (per-arch detail) — skip
    esac
    desc=${line#*"$SEP"}
    case "$desc" in
        *Mach-O*) macho_paths+=("${line%%"$SEP"*}") ;;
    esac
done < <(find "$ANALYSIS_DIR" -type f -print0 2>/dev/null | xargs -0 -r file -F "$SEP" 2>/dev/null)

echo "   ${#macho_paths[@]} Mach-O file(s) found; reading architectures..."
for f in "${macho_paths[@]}"; do
    archs=$(lipo -archs "$f" 2>/dev/null || true)
    [ -z "$archs" ] && continue
    echo "$archs" | grep -qE '\barm64e\b' && ANY_ARM64E=true
    if echo "$archs" | grep -qE '\bx86_64\b' && ! echo "$archs" | grep -qE '\barm64(e)?\b'; then
        rel="${f#$ANALYSIS_DIR/}"
        case "$rel" in
            *.kext/*|*.dext/*)
                # Rosetta 2 translates user-space processes only. An Intel-only
                # kext or DriverKit driver cannot load on Apple Silicon at all,
                # so it does not belong in the "Rosetta will be invoked" count.
                KEXT_INTEL_ONLY_LIST+=("$rel")
                ;;
            *)
                HELPER_INTEL_ONLY_LIST+=("$rel")
                ;;
        esac
    elif echo "$archs" | grep -qE '\barm64(e)?\b'; then
        ARM_CAPABLE_LIST+=("${f#$ANALYSIS_DIR/}")
    fi
done

# Separate genuine Rosetta triggers from x86-only code that arm64 never loads.
#
# An x86_64-only dylib cannot be dlopen'd by an arm64 process at all, so when a
# library ships per-instruction-set backends and picks one at runtime, the x86
# variants are dead weight on Apple Silicon rather than a Rosetta cost. Two
# independent signals, because they catch different real-world layouts:
#
#   A. The name carries an x86-exclusive ISA (AVX, SSE, MMX). No arm64 build of
#      such a backend can exist, so no sibling evidence is needed. This is what
#      catches BlackmagicRawAPI's InstructionSetServicesAVX/AVX2, whose universal
#      siblings (DecoderMetal, DecoderOpenCL) share no name prefix with it.
#   B. The name carries a generic backend token (Cpu, Scalar, Generic) AND a
#      same-directory sibling sharing its prefix has an arm64 slice — evidence of
#      a dispatch family where arm64 is served by another member. This catches
#      libArriImageSdkTransformsCpu_module alongside its CpuFma/Metal/OpenCl
#      siblings.
#
# Deliberately conservative: anything not matching stays in the Rosetta count.
# Over-reporting a Rosetta cost is a far safer error than hiding one.
has_arm_sibling_with_prefix() {
    # $1: directory (relative)  $2: required name prefix (>= 6 chars)
    local dir="$1" prefix="$2" cand
    [ ${#prefix} -ge 6 ] || return 1
    for cand in "${ARM_CAPABLE_LIST[@]}"; do
        [ "${cand%/*}" = "$dir" ] || continue
        case "${cand##*/}" in
            "$prefix"*) return 0 ;;
        esac
    done
    return 1
}

for rel in "${HELPER_INTEL_ONLY_LIST[@]}"; do
    base="${rel##*/}"
    dir="${rel%/*}"
    reason=""
    case "$base" in
        *AVX*|*avx*|*SSE*|*sse*|*MMX*|*mmx*)
            reason="x86-exclusive ISA in name; no arm64 build can exist"
            ;;
        *Cpu*|*CPU*|*Scalar*|*Generic*)
            # Prefix = name up to the backend token, e.g.
            # libArriImageSdkTransformsCpu_module -> libArriImageSdkTransforms
            stem="$base"
            for tok in Cpu CPU Scalar Generic; do
                case "$stem" in *"$tok"*) stem="${stem%%"$tok"*}"; break ;; esac
            done
            if has_arm_sibling_with_prefix "$dir" "$stem"; then
                reason="dispatch family; sibling ${stem}* carries arm64"
            fi
            ;;
    esac
    if [ -n "$reason" ]; then
        INERT_INTEL_LIST+=("$rel  ($reason)")
    else
        HELPER_INTEL_ONLY_COUNT=$((HELPER_INTEL_ONLY_COUNT+1))
        ROSETTA_INTEL_LIST+=("$rel")
    fi
done
HELPER_INTEL_ONLY_LIST=("${ROSETTA_INTEL_LIST[@]}")

if ((${#KEXT_INTEL_ONLY_LIST[@]} > 0)); then
    echo "   🔴 Intel-only kernel extensions / DriverKit drivers: ${#KEXT_INTEL_ONLY_LIST[@]}"
    printf '      - %s\n' "${KEXT_INTEL_ONLY_LIST[@]}"
fi
if ((${#INERT_INTEL_LIST[@]} > 0)); then
    echo "   ℹ️  Intel-only but inert on arm64 (never loaded, no Rosetta cost): ${#INERT_INTEL_LIST[@]}"
    printf '      - %s\n' "${INERT_INTEL_LIST[@]}"
fi
echo "   Intel-only Mach-O files (dylibs/XPC/helpers): $HELPER_INTEL_ONLY_COUNT"
if ((${#HELPER_INTEL_ONLY_LIST[@]} > 0)); then
    printf '      - %s\n' "${HELPER_INTEL_ONLY_LIST[@]}"
fi

$ANY_ARM64E && echo "   ℹ️  arm64e slice present (Apple pointer-authentication ABI — native on Apple Silicon)"
stage_end
echo ""

# Summary.
echo "═══════════════════════════════════════════════════"
echo "📊 Summary & Recommendations"
echo "═══════════════════════════════════════════════════"

# An Intel-only kext outranks everything else here: no Rosetta advice applies,
# and the affected hardware simply does not work. Lead with it.
if [ ${#KEXT_INTEL_ONLY_LIST[@]} -gt 0 ]; then
    echo "🔴 INTEL-ONLY KERNEL EXTENSION(S) — CANNOT RUN ON APPLE SILICON"
    for k in "${KEXT_INTEL_ONLY_LIST[@]}"; do echo "      - $k"; done
    echo ""
    echo "   Rosetta 2 translates user-space processes only; it does not translate"
    echo "   kernel extensions or DriverKit drivers. Installing Rosetta will NOT help."
    echo "   The associated hardware or feature is unusable on Apple Silicon until the"
    echo "   vendor ships a native arm64 kext or a DriverKit .dext replacement."
    echo ""
fi

# A staged archive we could not open is an unanalyzed corner of the installer.
# Say so up front — the verdict below is silent about whatever is inside it.
if [ ${#STAGED_SKIPPED[@]} -gt 0 ]; then
    echo "⚠️  ${#STAGED_SKIPPED[@]} staged prereq archive(s) were NOT analyzed:"
    for a in "${STAGED_SKIPPED[@]}"; do echo "      - $a"; done
    echo "   The verdict below does not account for their contents."
    echo ""
fi

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
