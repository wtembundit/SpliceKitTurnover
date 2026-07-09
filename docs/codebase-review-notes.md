# Codebase Review Notes

Observations from a holistic review of the Turnover codebase. Each item is written as a suggestion — the team evaluating it may decide to act, defer, or close based on priority and context.

---

## Turnover Team Triage

This review is useful, but not every item should become immediate work. Current priority is to keep the Conform Prep flattening model stable after the v1.3.2 real-project fixes, then improve runtime safety and release discipline without destabilizing FCPXML behavior.

### Should Fix Soon

- **B1 / E1: subprocess timeout and cancellation.** This is the highest-priority engineering safety issue. A stuck Node, `xmllint`, or child process can leave the standalone app in `Processing...` indefinitely. Add timeouts, clearer errors, and eventually a Cancel button.
- **A2: single-source versioning.** Version drift already creates release confusion. Keep `VERSION` as the source of truth and generate plugin/app/package metadata from it.
- **U1 / U2: explain disabled Run state and missing runtime state.** This is important for standalone users because the app should feel self-explanatory.
- **R1: lightweight smoke tests.** Full real-project regression fixtures may be too large or confidential, but a small anonymized/minimized smoke set plus local real-project smoke script would prevent accidental regressions.

### Worth Doing, But Not Urgent

- **A3: shared Lua utilities.** Useful for maintainability, but it should wait until the current plugin/standalone behavior is stable.
- **B3: stricter VFX title detection.** The fallback text-pattern detection is intentional for messy real-world timelines, but it should be tightened only after we preserve the workflows that depend on it.
- **U4 / U6: polish items.** Contrast and quiet cache messages are good cleanup tasks, not release blockers.
- **R2: build artifact ignore audit.** Important hygiene, but quick to verify separately.

### Design Choice / Known Tradeoff

- **B4: non-ASCII Lua case folding.** Accept as a known limitation unless localized template names become an actual user report.
- **B5: Lua RPC error surfacing.** Keep improving when touching plugin runtime paths, but the native plugin already wraps most user-facing tool errors.
- **U5: tool picker layout.** The two-row workflow grouping is intentional for now. Revisit only when adding/removing major tools.

### Parked With Data Burn-In

- **B2 and U3** belong with the Data Burn-In future plan. The prototype needs a larger design pass before we tune dedup keys or preview styling in isolation.

### Future Runtime / App Size Plan

- The standalone app should keep bundling Node.js for now. The current priority is that users can run Turnover without installing or configuring Node themselves.
- The preferred future size optimization is the Bun/self-contained engine plan in `standalone-optimization-plan.md`: compile the existing JavaScript FCPXML scripts into a compact `turnover-engine` while keeping JavaScript as the single source of truth.
- Do not rewrite the FCPXML core in Swift just to reduce app size. That would create two logic paths and increase the chance that the standalone and SpliceKit editions drift apart.
- Treat the Bun engine as a separate release spike after smoke tests cover Conform Prep, Auto Marker, VFX Naming, VFX Pull EDL, VFX Timeline, and VFX Shot List.
- Success criteria: outputs match the current Node runtime byte-for-byte or semantically, the standalone app runs without user-installed Node.js, and the SpliceKit plugin edition remains compatible with the shared scripts.

---

## Architecture & Maintainability

### A1. Node.js search paths differ between standalone app and plugin installer

**Observation:** `NodeRunner.findNode()` in the standalone app searches only:
- `runtime/node` (bundled)
- `TURNOVER_NODE_PATH` env var
- `/opt/homebrew/bin/node`
- `/usr/local/bin/node`
- `/usr/bin/node`

The plugin installer (`resolve_node()`) additionally searches `~/.volta/bin/node`, `~/.asdf/shims/node`, `/opt/local/bin/node`, `/usr/local/opt/node/bin/node`, and `~/.nvm/versions/*/bin/node`.

**Suggestion:** Align the search paths. If a user manages Node.js via Volta or nvm and uses the standalone app without the plugin, they will see "Node.js not found" despite Node.js being fully installed. Consider also adding `command -v node` as a PATH-based fallback (the installer already uses this).

**Team note:** This remains useful only while the standalone app has a Node fallback path. If the future Bun/self-contained engine plan ships, the app should no longer depend on user-installed Node.js at all.

---

### A2. Version string in three locations

**Observation:** The version is hardcoded in `VERSION` (root), `plugin.json`, and `TurnoverToolsPlugin.m:18` (`TTTurnoverVersion`). The build script checks consistency, which is good. If a fourth location is added later (e.g., a Swift Info.plist constant) and the check is not updated, versions will silently drift.

**Suggestion:** Drive all versions from a single source (`VERSION` file) and inject it into `plugin.json` and the Obj-C source at build time via a placeholder token (the same way `Info.plist` already uses `__TURNOVER_VERSION__`).

---

### A3. Duplicate XML parsing and utility functions across Lua scripts

**Observation:** Every Lua script (`VFX Auto Naming.lua`, `VFX Pull EDL.lua`, `VFX Shot List.lua`, etc.) duplicates the same ~50 lines of boilerplate: `trim()`, `parse_fraction()`, `fmt_seconds()`, `file_exists()`, `read_file()`, `write_file()`, `parse_attrs()`, `escape_xml_attr()`. The `vfx-row-resolver-contract.md` already notes this.

**Suggestion:** Extract these into a shared `lib/` module that all Lua scripts load. Low priority, but reduces copy-paste drift over time.

---

## Potential Bugs

### B1. Process termination handler may block on subprocess pipes

**File:** `NodeRunner.swift:110-125`

**Observation:** `stdout.fileHandleForReading.readDataToEndOfFile()` is called inside `terminationHandler`. If the spawned Node.js script spawns its own subprocesses (e.g., `xmllint` via `child_process.execFile`) that inherit stdout, the pipe will not close until *all* descendants exit. If `xmllint` hangs, the Swift caller hangs indefinitely — there is no timeout on `Process`.

**Suggestion:** Add `process.timeout = 30` (or similar) to prevent indefinite hangs. Also consider reading stdout/stderr asynchronously rather than blocking in the termination handler.

---

### B2. Data burn-in manifest uses `toFixed(6)` for dedup key

**File:** `build_data_burn_in_manifest.mjs:88`

```js
const key = `${item.role}|${item.timelineStartSeconds.toFixed(6)}|${item.timelineEndSeconds.toFixed(6)}`;
```

**Observation:** Two intervals identical at the microsecond level but differing at the 7th decimal (from floating-point drift in retime math) will **not** be deduped. Conversely, two genuinely different intervals that happen to round to the same 6-decimal string will be incorrectly collapsed. The probability of collision is low in practice, but the key space is not a reliable identity.

**Suggestion:** Replace with an epsilon-based comparison or use a more robust dedup strategy (e.g., sorted merge or set of tuples with tolerance).

---

### B3. `looks_like_vfx_code()` may produce false positives

**File:** `VFX Auto Naming.lua:142`

```lua
return first_line:match("^[%u%d_%-]+_XXXX$") ~= nil or first_line:match("^[%u%d_%-]+_%d%d%d%d$") ~= nil
```

**Observation:** Any clip or title whose visible text matches this pattern (e.g., a shot named `ABC_0010` that is not a VFX naming title) will be treated as a VFX naming title. The primary guard in `is_vfx_title` checks the title element name first, but if the name doesn't contain "VFX NAMING", it falls through to this text pattern match. A non-VFX element with matching text could be incorrectly renumbered.

**Suggestion:** Consider adding a namespace or attribute check (e.g., the title must have `ref="..."` pointing to the VFX Naming Motion template) before falling through to text pattern matching.

---

### B4. Lua `string.lower` may mishandle non-ASCII titles

**File:** `VFX Auto Naming.lua:146`

```lua
if lower(title_name):find(lower(CONFIG.TITLE_MATCH), 1, true) then return true end
```

**Observation:** Lua's `string.lower` does not handle non-ASCII case folding. If Apple or a third-party localizes the "VFX NAMING" Motion template name to a language with non-ASCII characters, title detection will silently break — no titles are found, and the tool reports "No VFX titles found" with no hint about the cause.

**Suggestion:** Document this as a known limitation. If localization support is needed later, switch to a case-insensitive comparison that handles Unicode.

---

### B5. Lua RPC error may not surface to user in plugin

**Observation:** The Objective-C plugin's `TTRunLuaCompatibilityScript` calls `sk.rpc("lua.execute", ...)`. The Lua scripts check the return value for `res.error`, but if the RPC itself fails (e.g., SpliceKit is not ready, Lua VM initialization error), the error is logged but may not be surfaced to the user in the plugin panel.

**Suggestion:** Ensure all RPC failure paths write a visible error to the plugin status label, not just `gAPI->log()`.

---

## UI & UX

### U1. Disabled Run button has no explanation

**File:** `ContentView.swift:122-124`

```swift
.disabled(!model.canRun)
```

**Observation:** When the Run button is disabled, there is no tooltip or contextual help explaining why. A new user sees a gray button and must infer the reason from the status panel text. Possible causes include: no FCPXML loaded, Node.js not found, or no reference movie selected for Shot List.

**Suggestion:** Add a tooltip or a subtle label below the button showing the first blocking condition (e.g., "Node.js not found" / "Drop an FCPXML to begin").

---

### U2. "Node.js: Not found" is the first thing a new user sees

**File:** `ContentView.swift:337`

```swift
Text(model.nodeStatus)
```

**Observation:** The status bar permanently shows "Node.js: /path/to/node" or "Node.js: Not found". If Node.js is missing, this is the most prominent actionable message — but it's in a dim monospaced font at the bottom of the window, competing with cache size and other status text. For a plug-and-play app, a missing runtime should be more visible.

**Suggestion:** When Node.js is missing, consider showing a prominent inline banner or replacing the drop zone instructions with a setup guide. Or, if the bundled runtime is dropped (per the optimization plan), this message becomes irrelevant anyway.

---

### U3. BurnInCustomizer shows black void when no reference movie

**File:** `BurnInCustomizerView.swift:114-129`

**Observation:** When no video is selected, the preview area shows a dark rectangle with an icon and the text "Transparent ProRes 4444 Preview". This looks like a rendering error or dead space. A checkerboard or grid pattern would better communicate "this is a transparent overlay preview."

**Suggestion:** Replace the solid dark fill with a checkerboard pattern (standard transparency indicator in design tools).

---

### U4. Green success icon has poor contrast on dark background

**File:** `ContentView.swift:361`

```swift
Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
```

**Observation:** Dark green on the dark gradient background (~#1A1F24) has an estimated contrast ratio of ~2.5:1 — below WCAG AA (4.5:1). The orange accent color used elsewhere in the UI (header, button, drop zone highlight) would be more readable and consistent.

**Suggestion:** Replace `.green` with `.orange` for the success indicator, or use a white checkmark with a green badge (system SF Symbol layered).

---

### U5. Five-item segmented picker is visually cramped

**File:** `ContentView.swift:161-175`

**Observation:** The VFX Tools segmented picker contains five items (Naming, Auto Marker, Pull EDL, Shot List, Timeline). Each segment label is necessarily short, and on smaller screens or under localization the labels may truncate or overlap. "Data Burn-In" is also placed outside this picker as a separate button, which is inconsistent.

**Suggestion:** Consider splitting into two rows (3+2) or using a dropdown/popup button for less frequently used tools.

---

### U6. Cache clear always shows a log message even when empty

**File:** `TurnoverModel.swift:1125-1140`

**Observation:** Clicking "Clear Cache" always updates the log with "Turnover cache cleared" even if the cache was already empty. Minor, but unnecessary UI noise.

**Suggestion:** Check if the cache had files before clearing and show a quieter update (or no message) if there was nothing to clear.

---

## Edge Cases

### E1. No subprocess timeout in NodeRunner

**File:** `NodeRunner.swift:97-133`

**Observation:** `Process` is created with no timeout. If the Node.js script deadlocks (e.g., `child_process.execFile` on `xmllint` blocks waiting for stdin), the app hangs on "Processing..." with no way to cancel. Users must force-quit.

**Suggestion:** Add `process.timeout = 30` and handle timeout with a clear error message. Consider also adding a Cancel button to the UI during `state == .running`.

---

## Build & Release

### R1. No automated test fixtures

**Observation:** The `docs/` reference "real-project fixtures" for testing, but no test fixtures are committed to the repo. There is no CI configuration (`.github/workflows/`), no test runner, and no automated verification. The `verify_conform_prep.mjs` script exists but must be run manually.

**Suggestion:** Commit a small set of anonymized FCPXML test fixtures (covering sync-clip, retime, speed ramp, nested timeline, multicam, markers, titles). Add a `npm test` script that runs the planners against these fixtures and checks output structure. Even a basic smoke test is better than none.

---

### R2. No `.gitignore` entry for build artifacts

**File:** `.gitignore` (root)

**Observation:** The `.build/` directory contains release staging files. The `standalone/TurnoverApp/build/` and `standalone/TurnoverApp/.build/` directories contain compiled Swift binaries and cached Node.js runtime downloads. If these are not gitignored, they could be accidentally committed.

**Suggestion:** Verify the `.gitignore` covers all build output directories (`build/`, `.build/`, `*.dylib`, `node_modules/`).
