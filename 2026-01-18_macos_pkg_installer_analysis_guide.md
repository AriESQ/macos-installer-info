# macOS PKG Installer Analysis Guide

A comprehensive guide for analyzing macOS `.pkg` installer files before installation, with focus on architecture compatibility and Rosetta 2 requirements.

## Table of Contents
- [Quick Start](#quick-start)
- [Basic Package Information](#basic-package-information)
- [Architecture Analysis](#architecture-analysis)
- [Distribution XML Inspection](#distribution-xml-inspection)
- [Detailed Binary Analysis](#detailed-binary-analysis)
- [Common Issues and Solutions](#common-issues-and-solutions)

---

## Quick Start

### Prerequisites
All commands use built-in macOS tools:
- `pkgutil` - Package manipulation
- `file` - File type identification
- `lipo` - Architecture inspection
- `plutil` - Property list manipulation

### Basic Workflow
```bash
# 1. Get package info
file YourInstaller.pkg

# 2. Expand for inspection
pkgutil --expand YourInstaller.pkg ~/Desktop/pkg_analysis

# 3. Check Distribution XML
cat ~/Desktop/pkg_analysis/Distribution | grep -i "hostArchitectures"

# 4. Verify app binary architectures
lipo -info YourApp.app/Contents/MacOS/YourAppBinary
```

---

## Basic Package Information

### #001 - Check Package Type and Signature
```bash
# Identify package type
file YourInstaller.pkg

# Verify signature and certificate chain
pkgutil --check-signature YourInstaller.pkg
```

**Expected Output:**
```
YourInstaller.pkg: xar archive compressed TOC: 4389, SHA-1 checksum
```

**Signature Output:**
```
Package "YourInstaller.pkg":
   Status: signed by a certificate trusted by macOS
   Signed with a trusted timestamp on: 2024-01-15 10:30:45 +0000
   Certificate Chain:
    1. Developer ID Installer: Company Name (TEAM123456)
       Expires: 2025-01-15 10:30:45 +0000
       SHA256 Fingerprint: ...
```

### #002 - List Package Contents (Without Installing)
```bash
# View all files that will be installed
pkgutil --payload-files YourInstaller.pkg

# More detailed view with sizes
lsbom -s $(pkgutil --bom YourInstaller.pkg)
```

**Human-Readable Output:**
```
./Applications/YourApp.app
./Applications/YourApp.app/Contents
./Applications/YourApp.app/Contents/MacOS
./Applications/YourApp.app/Contents/MacOS/YourApp
...
```

---

## Architecture Analysis

This section focuses on determining whether the package requires Rosetta 2 on Apple Silicon Macs.

### #003 - Expand Package for Detailed Inspection
```bash
# Extract package structure
pkgutil --expand YourInstaller.pkg ~/Desktop/pkg_analysis

# View expanded structure
tree ~/Desktop/pkg_analysis  # or use 'ls -R'
```

**Typical Structure:**
```
pkg_analysis/
├── Distribution          # ← KEY FILE: Contains hostArchitectures
├── Resources/
│   ├── background.png
│   └── welcome.html
└── YourApp.pkg/          # Component package
    ├── Bom               # Bill of Materials
    ├── PackageInfo       # Component metadata
    └── Payload           # Compressed app files
```

### #004 - Check Distribution XML for Architecture Settings
```bash
# View full Distribution file
cat ~/Desktop/pkg_analysis/Distribution

# Focus on architecture settings
grep -A2 -B2 "hostArchitectures" ~/Desktop/pkg_analysis/Distribution
```

**What to Look For:**

✅ **GOOD - Universal Installer:**
```xml
<options hostArchitectures="x86_64,arm64" />
```

❌ **BAD - Intel Only (Triggers Rosetta Prompt):**
```xml
<options hostArchitectures="x86_64" />
```
or
```xml
<options />  <!-- Missing hostArchitectures entirely -->
```

### #005 - Extract and Check Application Binary
```bash
# Navigate to expanded package
cd ~/Desktop/pkg_analysis

# Extract the payload to access app bundle
# First, decompress the Payload
cd YourApp.pkg
cat Payload | gunzip -dc | cpio -i

# Now check the actual binary architectures
lipo -archs YourApp.app/Contents/MacOS/YourApp
lipo -info YourApp.app/Contents/MacOS/YourApp
file YourApp.app/Contents/MacOS/YourApp
```

**Expected Outputs:**

**Universal Binary (Both Architectures):**
```bash
$ lipo -archs YourApp.app/Contents/MacOS/YourApp
x86_64 arm64

$ lipo -info YourApp.app/Contents/MacOS/YourApp
Architectures in the fat file: YourApp are: x86_64 arm64

$ file YourApp.app/Contents/MacOS/YourApp
YourApp: Mach-O universal binary with 2 architectures: [x86_64:Mach-O 64-bit executable x86_64] [arm64:Mach-O 64-bit executable arm64]
```

**Intel Only (Requires Rosetta):**
```bash
$ lipo -archs YourApp.app/Contents/MacOS/YourApp
x86_64

$ file YourApp.app/Contents/MacOS/YourApp
YourApp: Mach-O 64-bit executable x86_64
```

**Apple Silicon Only:**
```bash
$ lipo -archs YourApp.app/Contents/MacOS/YourApp
arm64

$ file YourApp.app/Contents/MacOS/YourApp
YourApp: Mach-O 64-bit executable arm64
```

---

## Distribution XML Inspection

### #006 - Complete Distribution File Analysis
```bash
# Pretty print XML for readability
xmllint --format ~/Desktop/pkg_analysis/Distribution

# Extract key metadata
cat ~/Desktop/pkg_analysis/Distribution | grep -E "title|hostArchitectures|minSpecVersion|os-version"
```

**Key Elements to Review:**

```xml
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>Your Application</title>
    
    <!-- ⚠️ CRITICAL: Architecture specification -->
    <options hostArchitectures="x86_64,arm64" />
    
    <!-- Minimum macOS version required -->
    <allowed-os-versions>
        <os-version min="12.0"/>
    </allowed-os-versions>
    
    <!-- Installation choices -->
    <choices-outline>
        <line choice="default"/>
    </choices-outline>
</installer-gui-script>
```

---

## Detailed Binary Analysis

### #007 - Check All Binaries in Package
Comprehensive scan for any Intel-only binaries that might trigger Rosetta requirement.

```bash
# Find ALL executable files in the package
cd ~/Desktop/pkg_analysis
find . -type f -perm +111 | while read binary; do
    echo "=== $binary ==="
    file "$binary"
    lipo -archs "$binary" 2>/dev/null || echo "Not a Mach-O binary"
    echo ""
done
```

### #008 - Identify Intel-Only Binaries
```bash
# Find binaries that are Intel-only (no arm64)
cd ~/Desktop/pkg_analysis
find . -type f -perm +111 -exec sh -c '
    file "$1" | grep -q "Mach-O" && \
    file "$1" | grep -q "x86_64" && \
    ! file "$1" | grep -q "arm64" && \
    echo "⚠️  Intel-only: $1"
' _ {} \;
```

**Interpretation:**
- If ANY binary is Intel-only, the installer should specify `hostArchitectures` to avoid false Rosetta prompts
- If ALL binaries are universal or arm64-only, installer should explicitly declare arm64 support

### #009 - Check Info.plist Architecture Settings
```bash
# Extract and view Info.plist
cd ~/Desktop/pkg_analysis/YourApp.pkg
cat Payload | gunzip -dc | cpio -i

# View Info.plist in readable format
plutil -p YourApp.app/Contents/Info.plist

# Check for architecture-specific keys
plutil -p YourApp.app/Contents/Info.plist | grep -E "LSRequiresNativeExecution|LSArchitecturePriority|MinimumOSVersion"
```

**Important Keys:**

```xml
<!-- Forces native execution (no Rosetta translation) -->
<key>LSRequiresNativeExecution</key>
<true/>

<!-- Specifies architecture preference order -->
<key>LSArchitecturePriority</key>
<array>
    <string>arm64</string>
    <string>x86_64</string>
</array>
```

### #010 - Check Code Signature and Entitlements
```bash
# View detailed code signature info
codesign -d -vv YourApp.app/Contents/MacOS/YourApp

# Extract and display entitlements
codesign -d --entitlements - YourApp.app/Contents/MacOS/YourApp

# Or save to file for easier reading
codesign -d --entitlements :- --xml YourApp.app/Contents/MacOS/YourApp > entitlements.plist
plutil -p entitlements.plist
```

**Common Entitlements to Look For:**

```xml
<!-- Hardened Runtime -->
<key>com.apple.security.cs.allow-jit</key>
<true/>
<key>com.apple.security.cs.allow-unsigned-executable-memory</key>
<true/>
<key>com.apple.security.cs.disable-library-validation</key>
<true/>

<!-- App Sandbox -->
<key>com.apple.security.app-sandbox</key>
<true/>

<!-- Network access -->
<key>com.apple.security.network.client</key>
<true/>
<key>com.apple.security.network.server</key>
<true/>

<!-- File access -->
<key>com.apple.security.files.user-selected.read-write</key>
<true/>
<key>com.apple.security.files.downloads.read-write</key>
<true/>
```

### #011 - Check Privacy Permission Requests
```bash
# View all privacy-related usage descriptions
defaults read YourApp.app/Contents/Info.plist | grep "UsageDescription"

# Check specific permissions
defaults read YourApp.app/Contents/Info.plist NSCameraUsageDescription
defaults read YourApp.app/Contents/Info.plist NSMicrophoneUsageDescription
defaults read YourApp.app/Contents/Info.plist NSLocationUsageDescription
```

**Common Privacy Keys:**
- `NSCameraUsageDescription` - Camera access
- `NSMicrophoneUsageDescription` - Microphone access
- `NSLocationWhenInUseUsageDescription` - Location services
- `NSContactsUsageDescription` - Contacts access
- `NSCalendarsUsageDescription` - Calendar access
- `NSPhotoLibraryUsageDescription` - Photos access
- `NSAppleEventsUsageDescription` - Automation/AppleScript

### #012 - Gatekeeper Assessment (spctl)
```bash
# Check if macOS Gatekeeper will allow the app to run
spctl -a -vv YourApp.app

# Or for a PKG installer before extracting
spctl -a -vv -t install YourInstaller.pkg
```

**What this reveals:**
- Will macOS allow this to run without a security warning?
- Notarization status
- Origin (App Store, identified developer, unknown)

**Example outputs:**
```bash
# ✅ Approved and notarized
YourApp.app: accepted
source=Notarized Developer ID
origin=Developer ID Application: Company Name (TEAM123456)

# ⚠️ Not notarized
YourApp.app: rejected
source=no usable signature

# ❌ Unsigned
YourApp.app: rejected
source=unnotarized
```

### #013 - VirusTotal Sandbox Analysis

VirusTotal provides free automated sandbox analysis that shows you what an installer actually does when it runs. This is invaluable for understanding behavior before installing on your own machine.

**What VirusTotal's sandbox reveals (Behavior tab):**
- File system changes the installer makes
- Network connections attempted
- Processes spawned during installation
- Registry/plist modifications
- System calls and API usage
- Screenshots of the installation process

**How to use:**
1. Visit https://www.virustotal.com
2. Upload your PKG or APP file (or provide URL)
3. Wait for analysis to complete (may take a few minutes)
4. Click the **Behavior** tab to see sandbox execution results
5. Check **Relations** tab for bundled files and network activity
6. Read **Community** comments for known issues or warnings

**Important Privacy Note:**
- Uploading makes the file available to VirusTotal's partners
- Don't upload confidential or proprietary software
- Consider this public disclosure

**Tip:** The Behavior tab shows you exactly what the installer does in a controlled environment - what files it touches, what network requests it makes, what processes it spawns. This is far more valuable than just the detection results.

---

## Common Issues and Solutions

### Issue #1: False Rosetta Prompt on Universal Apps

**Symptom:** Installer prompts to install Rosetta even though app is universal binary.

**Diagnosis:**
```bash
# Check Distribution XML
grep "hostArchitectures" ~/Desktop/pkg_analysis/Distribution

# Verify app is actually universal
lipo -info YourApp.app/Contents/MacOS/YourApp
```

**Solution:** Distribution XML missing or incorrect `hostArchitectures` attribute.

**Fix Required:** Add to `<options>` tag:
```xml
<options hostArchitectures="x86_64,arm64" />
```

---

### Issue #2: Intel-Only Component in Universal Package

**Symptom:** Package contains mostly universal binaries but one Intel-only library/plugin.

**Diagnosis:**
```bash
# Scan all binaries
find ~/Desktop/pkg_analysis -type f -perm +111 -exec file {} \; | grep "x86_64" | grep -v "arm64"
```

**Finding Example:**
```
./Helper/plugin.dylib: Mach-O 64-bit dynamically linked shared library x86_64
```

**Assessment:** If Intel-only components are present, Rosetta IS required, and the installer prompt is legitimate.

---

### Issue #3: Script-Based Apps

**Symptom:** App has no compiled binaries (e.g., shell script, Python app).

**Diagnosis:**
```bash
# Check if main executable is a script
file YourApp.app/Contents/MacOS/YourApp
```

**Output:**
```
YourApp: Bourne-Again shell script text executable, ASCII text
```

**Note:** macOS runs script-only apps under Rosetta translation by default as a precautionary measure. To prevent this, add to Info.plist:
```xml
<key>LSArchitecturePriority</key>
<array>
    <string>arm64</string>
</array>
<key>LSRequiresNativeExecution</key>
<true/>
```

---

## Stage 1 Hardening Recipes (added 2026-05-23)

These recipes document the behavior that `analyze_pkg.sh` adopted to handle the variation observed in real-world installers (raw-cpio Payloads, missing `Distribution`, bundle pkgs, stub installers, arm64e binaries). Each recipe maps to a corresponding section of the script.

### #021 - Payload Format Dispatch

The classic `cat Payload | gunzip -dc | cpio -id` pipeline only handles gzip-compressed cpio. Real-world Payloads can be raw cpio (e.g. DaVinci Resolve), xz-compressed (some commercial installers), or pbzx (Apple system pkgs). Dispatch on `file -b` plus the 4-byte magic:

| Format       | `file -b` substring  | First 4 bytes (hex) | Extraction                       |
|--------------|----------------------|---------------------|----------------------------------|
| gzip+cpio    | `gzip compressed`    | `1f 8b ...`         | `gunzip -dc Payload \| cpio -id` |
| raw cpio     | `cpio archive`       | `30 37 30 37 30 37` | `cpio -id < Payload`             |
| xz+cpio      | (varies)             | `fd 37 7a 58`       | requires `xz` (not stock; lazy)  |
| pbzx         | `data`               | `70 62 7a 78` (`pbzx`) | requires Python helper or `uvx` (lazy) |
| nested xar   | `xar archive`        | `78 61 72 21`       | `xar -xf Payload`                |
| raw zip      | `Zip archive`        | `50 4b 03 04`       | `unzip Payload`                  |

Always surface `cpio` and `gunzip` exit codes — do **not** silence them with `2>/dev/null`. A silent extraction failure produces a wrong verdict downstream.

### #022 - Robust `hostArchitectures` Parsing

`grep "hostArchitectures"` is fragile: it can match comments, scripts inside `<![CDATA[...]]>`, or attributes wrapped across lines. Use `xmllint --xpath`:

```bash
ARCH=$(xmllint --xpath 'string(//options/@hostArchitectures)' \
    "$ANALYSIS_DIR/Distribution" 2>/dev/null)
```

- Empty `$ARCH` means either the attribute is missing or there is no `<options>` element — both are interpreted as "Installer.app will prompt for Rosetta on Apple Silicon."
- `xmllint --xpath` on a missing attribute exits 0 with empty output on macOS 12+; check `[ -n "$ARCH" ]`, not the exit code.
- This catches the `hostArchitectures` attribute regardless of which element it lives on (some templates put it on a different element) and ignores false matches in scripts.

Edge case: `hostArchitectures` set via `<choice>` or `pkg-ref` script overrides is *not* parsed — extremely rare in practice.

### #023 - Recursive Mach-O Walk + arm64e Equivalence

The mismatch verdict needs to consider *every* Mach-O file, not just app main executables. Helper dylibs and XPC services inside `.app/Contents/Libraries/` or `.app/Contents/XPCServices/` are routinely Intel-only even when the main app is universal — they're the legitimate-Rosetta signal:

```bash
find "$ANALYSIS_DIR" -type f | while read f; do
    file -b "$f" 2>/dev/null | grep -q "Mach-O" || continue
    archs=$(lipo -archs "$f" 2>/dev/null)
    if echo "$archs" | grep -qE '\bx86_64\b' && ! echo "$archs" | grep -qE '\barm64(e)?\b'; then
        echo "Intel-only: ${f#$ANALYSIS_DIR/}"
    fi
done
```

**arm64e** (Apple's pointer-authentication ABI) is a distinct slice from `arm64`. `lipo -archs` reports them separately (e.g. `x86_64 arm64e` is a legitimate combo). Treat arm64e as native-Apple-Silicon for the mismatch verdict — an arm64e-only binary runs natively on Apple Silicon and does not require Rosetta. Use the regex `arm64(e)?` everywhere the script tests for "has native ARM code". Report arm64e distinctly in per-binary output; it's unusual in third-party apps (mostly Apple system frameworks) and worth surfacing.

### #024 - Component-pkg vs Distribution-pkg Verdict Branching

A single-component `.pkg` has no `Distribution` file. The original mismatch check would compute `DIST_HAS_ARM64=false` for these and falsely tell the user to "fix the Distribution XML" — but there is no Distribution to fix. Branch the verdict logic on `Distribution` presence:

```bash
if [ ! -f "$ANALYSIS_DIR/Distribution" ]; then
    echo "ℹ️  Component package (no Distribution)"
    # ... report main-exec archs only; no mismatch claim ...
else
    # ... canonical mismatch check ...
fi
```

A component pkg installed via `installer -pkg foo.pkg -target /` reads arch from the binaries directly; there is no `hostArchitectures` attribute to misconfigure.

### #025 - Stub / Downloader Installer Detection

Some installers (Microsoft AutoUpdate stubs, Adobe Creative Cloud installers, etc.) contain no real payload — the postflight script downloads the actual installer at install time. Static analysis is fundamentally impossible. Detect:

1. The component contains no Mach-O files after extraction.
2. The component contains no staged `.tgz`/`.zip`/`.pkg`/`.dmg`.
3. The component's `Scripts/postinstall*` invokes network primitives: `curl`, `wget`, `softwareupdate`, `installer -pkg http…`, or hardcoded `https?://` URLs.

```bash
grep -REl --include='postinstall*' --include='postflight*' \
    -e 'curl ' -e 'wget ' -e 'softwareupdate' \
    -e 'installer .* http' -e 'https?://' \
    "$component/Scripts"
```

When any component is classified as a stub, the final summary block must flip into **"RESULT NON-COMPREHENSIVE"** mode rather than rendering a clean verdict. Print what *can* be analyzed (signature, Distribution arch declaration, what the postflight will fetch) but explicitly note that the actual installed binaries are not on disk and cannot be assessed.

---

## Complete Analysis Script

See [`analyze_pkg.sh`](analyze_pkg.sh) — the canonical implementation. It runs through these phases:

1. Input validation (flat xar pkg, Bill of Materials, Installer package, or bundle-pkg directory)
2. Signature check (`pkgutil --check-signature`)
3. Expand (`pkgutil --expand` for flat pkgs; copy-as-is for bundle pkgs)
4. Distribution XML parse (`xmllint --xpath`, recipe #022)
5. Per-component Payload extraction with format dispatch (recipe #021)
6. Stub/downloader scan (recipe #025)
7. Per-app inspection — `lipo -archs`, `codesign`, `Info.plist` (recipes #003-#011)
8. Recursive Mach-O sweep for Intel-only helpers (recipe #023)
9. Summary — branches on stub status, extraction success, Distribution presence (recipe #024), and arm64/arm64e equivalence

Usage:
```bash
chmod +x analyze_pkg.sh
./analyze_pkg.sh YourInstaller.pkg
```

The script writes to `/tmp/pkg_analysis_<epoch>/` and prints a cleanup hint at the end (it does not auto-clean).

---

## Quick Reference Commands

### Essential Commands
```bash
# #011 - Quick architecture check
lipo -archs /path/to/binary

# #012 - Detailed architecture info
lipo -info /path/to/binary

# #013 - File type identification
file /path/to/binary

# #014 - Extract Distribution XML
pkgutil --expand installer.pkg temp_dir && cat temp_dir/Distribution

# #015 - List payload without extracting
pkgutil --payload-files installer.pkg

# #016 - Verify package signature
pkgutil --check-signature installer.pkg

# #017 - Check code signature details
codesign -d -vv /path/to/app

# #018 - Extract entitlements
codesign -d --entitlements - /path/to/binary

# #019 - View Info.plist
plutil -p /path/to/app/Contents/Info.plist

# #020 - Check privacy permissions
defaults read /path/to/app/Contents/Info.plist | grep UsageDescription

# #026 - Gatekeeper assessment
spctl -a -vv /path/to/app
spctl -a -vv -t install /path/to/installer.pkg
```

---

## Additional Resources

- [Apple Developer: Distribution Definition Reference](https://developer.apple.com/library/archive/documentation/DeveloperTools/Reference/DistributionDefinitionRef/)
- [Building Universal macOS Binaries](https://developer.apple.com/documentation/xcode/building-a-universal-macos-binary)
- [Scripting OS X: Platform Support in Installer Packages](https://scriptingosx.com/2020/12/platform-support-in-macos-installer-packages-pkg/)
- [VirusTotal](https://www.virustotal.com) - Free sandbox analysis showing installer behavior (Behavior tab)

---

## Troubleshooting Checklist

- [ ] Package signature is valid (`pkgutil --check-signature`)
- [ ] Gatekeeper will allow execution (`spctl -a -vv`)
- [ ] Distribution XML contains `hostArchitectures="x86_64,arm64"`
- [ ] All binaries are universal or arm64-native (`lipo -archs`)
- [ ] Info.plist doesn't force Intel architecture
- [ ] No Intel-only frameworks or plugins
- [ ] Scripts (if any) have proper `LSArchitecturePriority` set
- [ ] Code signature includes appropriate entitlements (`codesign -d --entitlements`)
- [ ] Privacy permissions are declared and reasonable
- [ ] Notarization status verified (if distributing outside App Store)

---

**Last Updated:** 2026-05-23  
**Version:** 1.2 (Stage 1 hardening: recipes #021–#025; Gatekeeper #012 + VirusTotal #013)
