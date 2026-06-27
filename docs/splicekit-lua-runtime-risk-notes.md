# SpliceKit Lua Runtime Risk Notes

Turnover should treat Lua as a short controller layer, not as the engine for long-running workflows.

## Root Cause Found

SpliceKit's embedded Lua runtime has safety limits:

- Execution timeout around 30 seconds.
- Memory cap around 256 MB.
- Standard shell execution is intentionally disabled.

This made VFX Shot List fragile when Lua performed a long seek/capture loop. Fast capture could finish but produced stale/duplicate viewer frames; slower capture allowed FCP to redraw correctly but hit Lua runtime limits around 60-72 captures.

## Current Fix Pattern

VFX Shot List now uses a two-stage model:

- Lua exports/parses FCPXML and writes `VFX_Shot_List_Manifest.tsv` only.
- Native Turnover plugin reads the manifest, seeks the FCP playhead, captures viewer frames, crops thumbnails, and generates Excel.

This keeps heavy or long UI work outside Lua while preserving the existing Lua XML parser for shot-list data extraction.

## Rule Of Thumb

Use Lua for:

- Short FCP commands.
- XML export/import orchestration.
- Lightweight parsing for small/medium timelines.
- Compatibility wrappers for older scripts.

Prefer native plugin or Node.js for:

- Long loops over many shots/clips.
- Repeated `sk.seek`, `sk.sleep`, capture, or UI actions.
- Heavy XML transforms on real production timelines.
- Workflows that need reliable progress/cancellation.
- Anything likely to run longer than 10-15 seconds in Lua.

## Scripts To Watch

- `VFX Shot List.lua`: long capture loop has been moved to native; remaining Lua parsing should still be watched on very large timelines.
- `VFX Auto Marker - Standard/To Do/Chapter.lua`: still loops over events and may perform repeated seek/action work. Marker rename is optional because FCPXML marker rewrites can be brittle.
- `VFX Pull EDL`: native Turnover now calls the Node planner `build_vfx_pull_edl.mjs`; keep the legacy Lua script only as a compatibility reference.
- `VFX Auto Naming.lua` and `VFX Reset Naming.lua`: mostly export/patch/import workflows; safer than capture loops, but heavy XML parsing should eventually move to Node for consistency.
- `Conform Prep`: already follows the better pattern: native orchestrates, Node performs heavy FCPXML transformation.

## Marker Lesson

Marker over-creation was reduced by avoiding blind timeline marker recreation and by relying on existing structured title/manifest data where possible. The same principle should be applied to Auto Marker: create markers only as anchors, keep rename/note mutation optional, and let downstream tools read title data directly when marker text is unreliable.

## VFX Row Resolver Coupling

`VFX Shot List` and `VFX Pull EDL` are coupled by design. Both should resolve VFX rows from the same title/marker/source-selection contract:

- markers are anchors;
- `VFX NAMING` titles provide VFX number, note, and visible range;
- source ranges are collected from that visible range and filtered by context/source keys.

If one workflow changes how it matches titles, markers, source keys, stacked layers, or retimed source ranges, the other workflow must be regression-tested on the same fixtures. The long-term fix is a shared Node module for VFX row resolution.
