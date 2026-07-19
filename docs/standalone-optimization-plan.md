# Standalone App Optimization Plan

## Turnover Team Decision

This plan is intentionally parked until the Data Burn-In work is stable. Do **not** re-open the app-size decision during normal bugfix work.

The Bun-compiled engine path is the preferred future direction, but it should **not** be folded into a bugfix release. It changes the standalone runtime architecture even if the FCPXML scripts remain the same.

Current recommendation:

- Keep the bundled Node.js runtime for current releases so Turnover remains low-risk and plug-and-play.
- Finish Data Burn-In first; do not mix the runtime-size work with Burn-In feature development.
- Treat the Bun engine as a dedicated optimization spike for a later release.
- Do the spike only after we have a lightweight smoke suite for Conform Prep, Marker, VFX Naming, Auto Marker, VFX Pull EDL, VFX Timeline, VFX Shot List, and Data Burn-In preview-cache generation.
- Compare outputs byte-for-byte or semantically against the current Node runtime before switching users over.

Why this is attractive:

- It could reduce the standalone app bundle dramatically while preserving the JavaScript/FCPXML source of truth.
- It avoids rewriting the FCPXML core in Swift, which would create a second implementation and increase divergence risk.
- It keeps the standalone app independent from user-installed Node.js.

Main concerns:

- Bun compatibility must be tested with `exceljs`, `child_process`, file dialogs/output paths, FCPXML validation, and all scripts.
- A compiled single binary can make runtime debugging less transparent than shipping readable `.mjs` scripts plus Node.
- Any architecture switch should happen only when the current tool behavior is already well covered by smoke tests.

## Goal
Reduce the Turnover standalone app bundle size while preserving **single source of truth** for FCPXML logic and maintaining **plug and play** (zero external setup for end users).

---

## Current Standalone Bundle Breakdown

| Component | Size | Purpose |
|-----------|------|---------|
| Component | Current Size | Purpose |
|-----------|--------------|---------|
| `runtime/node` (Node.js v24.18.0) | ~115MB | Runs the `.mjs` scripts |
| `node_modules/` (exceljs + deps) | ~12-13MB | Only needed for Excel workbook generation |
| `.mjs` scripts | < 1MB | FCPXML planning logic (shared with plugin) |
| Swift binary + resources | Small compared with Node | App UI, capture, helpers |
| **Total app bundle** | **~132MB** | Latest observed standalone build |

The `.mjs` scripts are the **critical shared asset** -- identical files used by both the standalone app (via bundled Node.js) and the plugin edition (via system Node.js). **Any approach must keep these untouched.**

---

## Constraint: No Changes to Original Source Code

Plan is limited to:
- `standalone/TurnoverApp/` directory only (Swift files, Package.swift, build_app.sh)
- New `engine/` directory within the standalone app
- A single non-behavioral change to `prepare_turnover_import_fcpxml.mjs` (xmllint guard)

The plugin edition (`plugins/com.turnover.tools/`, `lua/`, `motion-templates/`) is **not touched**.

---

## Paths Compared

### Path A: Drop bundled Node.js, use system Node.js
| Pro | Con |
|-----|-----|
| Saves ~45MB instantly | Breaks plug and play -- user must install Node.js |
| Zero code changes | `node_modules` still bundled (~6MB) |
| Full single-source-of-truth | |

**Result: ~10MB but NOT plug and play. Rejected.**

### Path B: Drop everything -> port Excel to Swift, use system Node.js
| Pro | Con |
|-----|-----|
| Saves ~51MB total | Breaks plug and play -- user must install Node.js |
| Single-source-of-truth for core logic | Must maintain Excel generation in 2 places |

**Result: ~4MB but NOT plug and play. Rejected.**

### Path C: Port FCPXML core to Swift
| Pro | Con |
|-----|-----|
| Saves ~51MB total | **Single source of truth lost** -- dual maintenance |
| Fastest execution (in-process) | High effort (~7000 lines to port) |
| Plug and play | Risk of divergence between Swift and Node.js versions |

**Result: ~4MB, plug and play, but violates single-source-of-truth constraint.**

### Path D: Bun compile .mjs into single binary *[RECOMMENDED]*
| Pro | Con |
|-----|-----|
| Saves ~43MB | New build dependency (Bun) |
| **Full single source of truth** -- same .mjs files | One script needs xmllint guard |
| Plug and play -- self-contained binary | Single arch (arm64) |
| No logic changes to .mjs files | |

**Result: ~12MB, plug and play, single source of truth preserved.**

### Path E: Keep current approach (do nothing)
- Zero risk, zero effort, but still ~132MB based on the latest observed build.

---

## Recommended Path: Bun Compile (Path D)

### How it works

`bun build --compile` produces a **single native binary** from a JavaScript entry point. It bundles the Bun runtime + all imported modules into one file. No external Node.js, no `node_modules` to ship.

**Plan:** Create a thin `engine.mjs` dispatcher that maps `--tool` flags to existing `.mjs` scripts, then compile into `turnover-engine` binary (~8MB). Ship this binary instead of `runtime/node` + `node_modules` + 9 individual `.mjs` files.

### Architecture (before vs after)

```
BEFORE  (55MB)                           AFTER  (12MB)
+-- Turnover.app                         +-- Turnover.app
    +-- MacOS/Turnover (Swift, 3MB)          +-- MacOS/Turnover (Swift)
    +-- Resources/                           +-- Resources/
        +-- scripts/*.mjs (9 files)              +-- turnover-engine (8MB)
        +-- runtime/node (45MB)                  +-- scripts/*.mjs (copies
        +-- node_modules/ (6MB)                       for parity)
        +-- Motion Templates (<1MB)              +-- Motion Templates
        +-- icon + Info.plist                    +-- icon + Info.plist
```

### Implementation Steps

All changes are in `standalone/TurnoverApp/` only.

#### Step 1: Install Bun (build machine only)

```zsh
brew install oven-sh/bun/bun
```

Not shipped to end users.

#### Step 2: Create engine dispatcher

**New file:** `standalone/TurnoverApp/engine/engine.mjs`

Thin ~50-line file that maps `--tool` argument names to the existing `.mjs` scripts:

```
--tool=conform-prep     -> build_conform_prep_fcpxml.mjs
--tool=auto-marker      -> build_vfx_auto_marker_fcpxml.mjs
--tool=naming           -> build_vfx_naming_fcpxml.mjs
--tool=pull-edl         -> build_vfx_pull_edl.mjs
--tool=timeline         -> build_vfx_deliveries_fcpxml.mjs
--tool=shot-list-manifest -> build_vfx_shot_list_manifest.mjs
--tool=shot-list-excel  -> generate_vfx_shot_list_excel.mjs
--tool=burn-in-manifest -> build_data_burn_in_manifest.mjs
--tool=prepare-import   -> prepare_turnover_import_fcpxml.mjs
```

The Bun compiler follows `import` statements, so all referenced `.mjs` files are bundled into the binary automatically. `exceljs` gets bundled too.

#### Step 3: Guard xmllint calls in two scripts

Two scripts call `execFile("xmllint", ...)`:
- `prepare_turnover_import_fcpxml.mjs` (lines 53-83, `validateFCPXML`)
- `build_vfx_deliveries_fcpxml.mjs` (lines 10-41, `validateGeneratedFCPXML`)

**Change:** Wrap each validation in a try/catch that silently skips when `xmllint` is not found. DTD validation is advisory -- the generated FCPXML already works without it.

This is the **only** change to a `.mjs` file and is backward-compatible (plugin edition has `xmllint` via FCP).

#### Step 4: Update build_app.sh

After `swift build -c release`, add Bun compile step:

```zsh
bun build --compile \
  --target=bun-darwin-arm64 \
  --outfile="$CONTENTS/Resources/turnover-engine" \
  "$SCRIPT_DIR/engine/engine.mjs"
```

**Remove:**
- Node.js download + SHA verification (lines 26-40)
- npm install step (lines 42-48)
- Script copy lines (lines 54-62 -- bundled into engine)
- node_modules copy (line 64)
- Runtime binary copy (lines 67-68)

**Keep:**
- Motion template copy (line 63)
- Icon generation (lines 70-78)
- Info.plist (lines 79-110)
- Code signing (line 112)

#### Step 5: Rewrite NodeRunner.swift -> EngineRunner.swift

Replace the entire file (~134 lines) with a simple runner:

```swift
import Foundation

enum EngineRunner {
    struct ProcessFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func findEngine() -> URL? {
        Bundle.main.resourceURL?
            .appendingPathComponent("turnover-engine")
    }

    static func run(tool: String, arguments: [String] = []) async throws -> String {
        guard let engineURL = findEngine() else {
            throw ProcessFailure(message: "Turnover engine is missing from the app bundle.")
        }
        // ... Process call with --tool <name> + forwarded arguments
    }
}
```

All tool-specific methods (`conformPrepScript()`, `autoMarkerScript()`, etc.) are replaced by the single `run(tool:arguments:)` method.

#### Step 6: Update TurnoverModel.swift

Replace all `NodeRunner.findNode()` calls with `EngineRunner.findEngine()`.

Replace each invocation like:
```swift
try await NodeRunner.run(executable: nodeURL, arguments: [scriptURL.path, ...])
```

With:
```swift
try await EngineRunner.run(tool: "conform-prep", arguments: ["--source-xml", ...])
```

Remove `prepareForFinalCutImport` calls -- this is now `--tool=prepare-import` on the engine.

#### Step 7: Update Package.swift (if needed)

Only if `NodeRunner.swift` is renamed or its API changes significantly. Likely no change needed -- file rename is handled by the build system.

#### Step 8: Update scripts/build_release.sh (if needed)

If the release script has any references to standalone Node.js bundling, update them to call `build_app.sh` which now handles everything.

---

## Files Touched (Summary)

| File | Change Type | Risk |
|------|-------------|------|
| `standalone/TurnoverApp/engine/engine.mjs` | **New file** -- dispatcher | Low |
| `standalone/TurnoverApp/build_app.sh` | **Modified** -- Bun compile instead of Node.js download | Low |
| `standalone/TurnoverApp/Sources/Turnover/NodeRunner.swift` | **Modified** -- simplified to EngineRunner | Low |
| `standalone/TurnoverApp/Sources/Turnover/TurnoverModel.swift` | **Modified** -- use engine binary | Low |
| `standalone/TurnoverApp/Package.swift` | Maybe no change | Low |
| `lua/scripts/prepare_turnover_import_fcpxml.mjs` | **Modified** -- xmllint guard (non-behavioral) | Low |
| `lua/scripts/build_vfx_deliveries_fcpxml.mjs` | **Modified** -- xmllint guard (non-behavioral) | Low |
| `scripts/build_release.sh` | Maybe update if references runtime/node | Low |

## Files NOT Touched

- `plugins/com.turnover.tools/*` -- Plugin edition unchanged
- `lua/*.lua` -- Plugin controllers unchanged
- `motion-templates/*` -- No changes
- Other `.mjs` files -- No changes (only the two xmllint guards above)
- `docs/*` -- No changes

---

## Risks & Mitigations

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| Bun doesn't support some Node.js API used in scripts | Low | Test `bun lua/scripts/<script>.mjs` with real FCPXML before committing |
| ExcelJS compatibility with Bun | Low | ExcelJS is pure JS, no native addons. Should work |
| xmllint missing leads to confusing errors | Medium | Make validation non-fatal. DTD check is advisory |
| Bun compile only supports arm64 | Low | Target is Apple Silicon. Add x64 later if needed via `--target=bun-darwin-x64` |
| Bun version drift | Low | Pin version in CI. Use `bun upgrade --stable` in build script |
| Engine binary 8-15MB larger than expected | Low | Even 15MB is still a huge improvement over 55MB |

---

## Bundle Size Projection

| Before | After |
|--------|-------|
| `runtime/node`: ~115MB | `turnover-engine`: target ~8-20MB |
| `node_modules/`: ~12-13MB | (bundled into engine) |
| `.mjs` scripts: <1MB | (bundled into engine) |
| Swift + rest: ~3MB | Swift + rest: ~3MB |
| Motion Templates: <1MB | Motion Templates: <1MB |
| **Total: ~132MB** | **Target: ~15-30MB, to be proven by spike** |

---

## Verification

1. Build standalone app with `standalone/TurnoverApp/build_app.sh`
2. Run each tool (Conform Prep, VFX Naming, Auto Marker, Pull EDL, Shot List, Timeline) with a test FCPXML input
3. Verify output XML/EDL/Excel is identical to pre-optimization version
4. Verify plugin edition still works (`Install Turnover.command` still succeeds, tools still run in FCP)
5. Confirm app opens and runs on a Mac without Node.js installed (true plug and play test)

---

## Future Work (Not Now)

If the plugin edition also needs to shed Node.js later:
- Extract FCPXML parsing into a shared Swift package (`FCPXMLKit`)
- The Swift `.dylib` can be linked by the Obj-C plugin via `@import FCPXMLKit`
- This requires Swift runtime in the FCP process -- needs investigation
- The `.mjs` files become archives at that point
