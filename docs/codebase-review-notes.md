# Codebase Review Notes

This document tracks cross-project engineering risks for Turnover. Data Burn-In has its own guide and roadmap in `data-burn-in.md`; keep Burn-In-specific parser, export, cache, and UI notes there so this file stays useful for the whole codebase.

## Current Triage

The near-term priority is release discipline: keep Conform Prep stable, keep Data Burn-In scoped, and reduce failure modes where the standalone app appears stuck.

### Should Fix Soon

- **B1 / E1: subprocess timeout and cancellation.** A stuck Node, `xmllint`, or child process can still leave standalone tools in `Processing...` indefinitely. Add timeouts and consistent cancel/error handling for every `Process` path, not only Data Burn-In export.
- **A2: single-source versioning.** Version drift creates release confusion. Keep `VERSION` as the source of truth and generate plugin/app/package metadata from it.
- **U1: explain disabled Run state.** Disabled actions should expose the first blocking condition with a tooltip or nearby status message.
- **R1: lightweight smoke tests.** Add minimized/anonymized FCPXML fixtures and a local smoke command for Conform Prep, VFX tools, and Data Burn-In parser/export regressions.

### Worth Doing, But Not Urgent

- **A3: shared Lua utilities.** Extract repeated Lua helpers once current plugin/standalone behavior is stable.
- **B3: stricter VFX title detection.** Tighten fallback text-pattern detection only after workflows that depend on messy real-world titles are preserved.
- **U4 / U6: polish items.** Improve status contrast and reduce noisy cache messages.

### Known Tradeoffs

- **B4: non-ASCII Lua case folding.** Accept as a known limitation unless localized template names become an actual user report.
- **B5: Lua RPC error surfacing.** Keep improving plugin runtime paths so RPC failures always reach the visible status label.
- **U5: tool picker density.** The two-row workflow grouping is intentional for now. Revisit only when adding or removing major tools.

## Architecture & Maintainability

### A2. Version string in three locations

**Observation:** The version is hardcoded in `VERSION`, `plugin.json`, and `TurnoverToolsPlugin.m` (`TTTurnoverVersion`). The build script checks consistency, which is good, but new version locations can still drift if the check is not updated.

**Suggestion:** Drive all versions from `VERSION` and inject it into generated or templated files during build.

### A3. Duplicate XML parsing and utility functions across Lua scripts

**Observation:** Several Lua scripts duplicate helpers such as `trim()`, `parse_fraction()`, `fmt_seconds()`, `parse_attrs()`, and XML escaping.

**Suggestion:** Extract shared helpers into a Lua `lib/` module after current behavior is stable. This is cleanup, not a release blocker.

## Potential Bugs

### B1. Process termination handler may block on subprocess pipes

**File:** `NodeRunner.swift`

**Observation:** Some process paths read stdout/stderr only after process termination. If a spawned script launches descendants that inherit pipes or hang, the Swift caller can wait indefinitely.

**Suggestion:** Use explicit timeouts, asynchronous pipe draining, and a shared cancellation policy for all tool runners.

### B3. `looks_like_vfx_code()` may produce false positives

**File:** `VFX Auto Naming.lua`

**Observation:** Text matching `ABC_0010` or similar can be interpreted as a VFX naming title if template-name detection does not catch it first.

**Suggestion:** Add a stronger title-template or namespace check before falling back to text-pattern matching.

### B4. Lua `string.lower` may mishandle non-ASCII titles

**Observation:** Lua's `string.lower` does not perform Unicode case folding. Localized Motion template names could fail detection.

**Suggestion:** Document the limitation for now; switch to Unicode-aware comparison only if localization becomes a real requirement.

### B5. Lua RPC error may not surface to user in plugin

**Observation:** RPC-level failures may be logged without a clear plugin panel message.

**Suggestion:** Ensure every RPC failure path writes a visible status-label error, not only `gAPI->log()`.

## UI & UX

### U1. Disabled Run button has no explanation

**File:** `ContentView.swift`

**Observation:** A disabled action can require the user to infer the reason from the status panel.

**Suggestion:** Add help text or a tooltip showing the first blocker, such as missing FCPXML, missing reference video, or unavailable runtime.

### U4. Green success icon has poor contrast on dark background

**Observation:** Dark green on the current dark gradient has low contrast.

**Suggestion:** Use the orange accent, or a higher-contrast success treatment.

### U5. Tool picker layout can get cramped

**Observation:** Five VFX tool segments are dense and may truncate under smaller widths or localization.

**Suggestion:** Keep the current two-row grouping for release, but revisit with a denser menu or adaptive layout if new tools are added.

### U6. Cache clear can be noisy

**Observation:** Clearing an already-empty cache still creates visible status noise.

**Suggestion:** Check whether files existed before reporting a cache-cleared message.

## Build & Release

### R1. No automated regression fixtures

**Observation:** There is no small committed fixture set for parser/export behavior. Manual real-project tests catch issues, but only after the app is built and exercised by hand.

**Suggestion:** Add a minimal fixture suite covering sync clips, speed ramps, reverse, holds, nested timeMaps, keyframed transform, connected layers, metadata, and DTD-safe Conform Prep output.

### Release Cleanup Checklist

- Verify build artifacts remain ignored by `.gitignore`.
- Remove temporary debug files, stale export scratch files, and local cache outputs before packaging.
- Keep release notes focused on user-visible changes; move investigation notes into the relevant design doc or delete them.
