# macos-installer-info

A reference toolkit for inspecting macOS distributables **before** you install or
run them, focused on one recurring headache: **diagnosing architecture
compatibility and unexpected Rosetta 2 prompts on Apple Silicon.**

It answers questions like:

- Will this installer/app run natively on my M-series Mac, or fall back to Rosetta?
- I got a Rosetta prompt — is it *real* (the code really is Intel) or a *false*
  prompt from a packaging mistake?
- If it's a false prompt, *what exactly* is causing it, and how is it fixed?

Everything uses **stock macOS tools** (`pkgutil`, `lipo`, `codesign`, `defaults`,
`file`, `xmllint`, `cpio`, `hdiutil`, `spctl`, `lsregister`). There is nothing to
install.

---

## What's in the repo

| File | Purpose |
|------|---------|
| **`analyze_pkg.sh`** | End-to-end analyzer for `.pkg` **installers**. |
| **`analyze_app.sh`** | End-to-end analyzer for `.app` **bundles** (e.g. the app inside a drag-to-install `.dmg`). |
| **`macos_pkg_installer_analysis_guide.md`** | The long-form guide. Numbered recipes (`#001`…`#031`) document the underlying commands; the scripts automate what the guide explains. |
| `CLAUDE.md` | Repo guidance for AI agents working in this codebase. |

The scripts and the guide are meant to **stay in sync** — each script phase has a
counterpart recipe in the guide.

---

## Quick start

```bash
# A .pkg installer
./analyze_pkg.sh path/to/Installer.pkg

# A .app bundle
./analyze_app.sh /Applications/Some.app

# A .dmg — mount it first, then point analyze_app.sh at the .app inside
hdiutil attach path/to/Some.dmg
./analyze_app.sh "/Volumes/Some/Some.app"
```

Both scripts print a sectioned report ending in a **Summary & Recommendations**
verdict. Neither auto-cleans its scratch files; each prints a cleanup hint at the
end (`/tmp/pkg_analysis_<epoch>/` for pkg, `/tmp/app_analysis_<epoch>.txt` for app).

There is **no build, lint, or test tooling.** Sanity-check changes by running the
relevant script against a real `.pkg` / `.app`.

---

## Background: why Rosetta prompts happen

On Apple Silicon, code runs natively only if it has an **arm64** (or **arm64e**)
slice. Intel-only (`x86_64`) code runs under **Rosetta 2** translation. A Rosetta
prompt is *correct* when code really is Intel-only — but several packaging
mistakes produce a **false** prompt on code that is actually native. The two
scripts exist to tell those cases apart and pinpoint the cause.

Key facts the toolkit encodes:

- **`arm64e` ≈ native.** It's Apple's pointer-authentication ABI, a *distinct*
  slice from `arm64` (`lipo` reports them separately). An arm64e-only binary runs
  natively and needs no Rosetta. Everywhere "has native ARM code" is tested, the
  scripts use the regex `arm64(e)?`.
- **The main binary being native is not sufficient.** An app can still be dragged
  into Rosetta by a single Intel-only dependency it loads (framework, vendored
  `.dylib`, native Node addon `.node`, Python C-extension `.so`, XPC service,
  plug-in `.bundle`). Both scripts sweep **every** Mach-O in the tree, not just the
  main executable.

---

## `analyze_pkg.sh` — installer analysis

Diagnoses the canonical installer-level false prompt: an installer whose payload
contains arm64 binaries but whose **`Distribution` XML doesn't declare arm64**, so
`Installer.app` itself prompts for Rosetta. The fix it recommends:

```xml
<options hostArchitectures="x86_64,arm64" />
```

Phases (top-to-bottom; the summary depends on state from earlier phases):

1. **Validate input** — accepts flat `.pkg` (xar archive), bundle `.pkg`
   (directory with `Distribution`/`PackageInfo`), Bill of Materials, or Installer
   package.
2. **Signature** — `pkgutil --check-signature`.
3. **Expand** — `pkgutil --expand` for flat pkgs; copy-as-is for bundle pkgs.
4. **Distribution XML** — parses `hostArchitectures` with `xmllint --xpath`
   (not fragile grep). Component pkgs (no `Distribution`) are handled separately.
5. **Payload extraction** — per-component, dispatching on format (gzip+cpio, raw
   cpio, xz, pbzx, nested xar, zip). Extraction exit codes are surfaced, never
   silenced — a silent failure would produce a wrong verdict.
6. **Stub/downloader detection** — flags installers whose real payload is fetched
   at install time (postflight runs `curl`/`wget`/`softwareupdate`/URLs and there
   are no on-disk binaries). These are marked **RESULT NON-COMPREHENSIVE**.
7. **Per-app + recursive Mach-O sweep** — `lipo -archs`, `codesign`, `Info.plist`
   on apps; Intel-only count across all Mach-O helpers.
8. **Summary** — branches on stub status, extraction success, `Distribution`
   presence, and arm64/arm64e equivalence to produce the verdict.

Hardening recipes behind this: **#021–#025** (payload dispatch, robust
`hostArchitectures` parsing, recursive Mach-O walk + arm64e, component-vs-distribution
branching, stub detection).

---

## `analyze_app.sh` — app bundle analysis

Companion for drag-to-install `.app` bundles. Same goal, bundle level. Phases:

1. **Input validation + dispatch** — recognizes `.app`; redirects `.pkg` to
   `analyze_pkg.sh` and tells you to mount a `.dmg` first.
2. **Bundle identity & arch hints** — `Info.plist`: bundle ID/version, plus the
   arch-influencing keys `LSArchitecturePriority` and `LSRequiresNativeExecution`.
3. **Main executable resolution** — reads `CFBundleExecutable`. If it's a real
   Mach-O, `lipo`s it. If it's a **launcher stub** (a shell script), resolves the
   `exec` target and `lipo`s the *real* binary instead.
4. **Code signature + entitlements** — `codesign -d -vv --entitlements -`.
5. **Deep Mach-O sweep** — every Mach-O in the bundle; classifies each Intel-only
   offender by kind (helper app / framework / dylib / native node addon / python
   ext / xpc / plug-in).
6. **Runtime Rosetta triggers** — scans for explicit `arch -x86_64` forcing in
   bundled scripts, checks for a per-user **"Open using Rosetta"** override in
   LaunchServices (`lsregister -dump`), and reports whether Rosetta is installed.
7. **Summary** — branches on launcher-stub vs Mach-O main, native vs Intel-only,
   and the script-as-exec root cause.

Recipes behind this: **#027–#031** (detect/dispatch, resolve launcher stub,
script-as-exec trigger, deep Mach-O sweep, runtime triggers).

### The non-obvious finding: a script as `CFBundleExecutable` is itself a Rosetta trigger

The case that motivated this script: an app that was **100% arm64** (real binary
and all 84 Mach-O dependencies native, zero Intel-only) still produced a "you need
to install Rosetta" prompt. Cause: its `CFBundleExecutable` was a **bash launcher
stub**, not a Mach-O — the real binary lived one directory over in
`Resources/bin/`.

Before launch, macOS/LaunchServices inspects **only**
`Contents/MacOS/<CFBundleExecutable>` for a native slice. A script has none, so
LaunchServices concludes the app can't run natively and offers Rosetta — never
consulting the real arm64 binary. **Fix (developer):** `CFBundleExecutable` must
be a real arm64/universal Mach-O — point it at the binary directly, or ship a
*compiled* trampoline. A shell script there will always trip the prompt.

### Decision flow for a Rosetta prompt on an `.app`

1. **Main exec is a script (not Mach-O)?** → false prompt; root cause is the stub
   (see above), even if everything else is native.
2. **Main exec is Intel-only?** → real prompt; app needs a universal2 build.
3. **Main exec arm64 but Intel-only dependencies exist?** → false prompt from a
   loaded dependency; rebuild those as universal2/arm64.
4. **All arm64, no static trigger?** → check runtime causes: `arch -x86_64`
   forcing, a stale "Open using Rosetta" Get Info flag, or a runtime-downloaded
   Intel helper / `dlopen` relaunch.

---

## Limitations worth knowing

- **Launcher-target resolution is heuristic.** `analyze_app.sh` resolves a simple
  `exec ./Foo` stub, but will *not* resolve targets chosen by a shell variable,
  `uname -m`-branched wrappers that exec different binaries per arch, or
  interpreter launchers (`python`/`node`/`java`). In those cases it degrades
  gracefully to "could not resolve target; rely on the Mach-O sweep" — the verdict
  still holds via the sweep + stub flag.
- **Static analysis can't see runtime behavior.** Intel helpers downloaded at
  install/run time, or a `dlopen` that relaunches under Rosetta when an
  arch-matched library is missing, are out of scope by definition.
- **Stub installers** (Adobe CC, MS AutoUpdate, etc.) carry no real payload;
  `analyze_pkg.sh` flags them as non-comprehensive rather than guessing.
- `hostArchitectures` set via `<choice>`/`pkg-ref` script overrides is not parsed
  (extremely rare).

---

## Outstanding TODOs

From `CLAUDE.md` and the work so far:

- **`.dmg` first-class handling in `analyze_pkg.sh`.** Today it rejects `.dmg`
  with a generic error. It should detect `.dmg` and instruct the user to
  `hdiutil attach` and target the `.pkg`/`.app` inside. (`analyze_app.sh` already
  gives the mount hint for `.app` purposes.)
- **A single input-type dispatcher** covering pkg / app / dmg, so one entry point
  routes to the right analyzer.
- **Robuster launcher resolution in `analyze_app.sh`** (the limitation above):
  report the arch of *each* candidate a `uname -m`-branched wrapper could exec;
  when resolution fails but exactly one executable Mach-O matches the bundle name,
  prefer it.
- **Broader real-world testing** — exercise the Electron/Chromium helper-app path
  (e.g. VS Code) and Python/`.so` C-extension layouts against the sweep.

---

## See also

- `macos_pkg_installer_analysis_guide.md` — full recipe reference (`#001`–`#031`),
  quick-reference command card, and a troubleshooting checklist.
- [Apple: Distribution Definition Reference](https://developer.apple.com/library/archive/documentation/DeveloperTools/Reference/DistributionDefinitionRef/)
- [Apple: Building a Universal macOS Binary](https://developer.apple.com/documentation/xcode/building-a-universal-macos-binary)
