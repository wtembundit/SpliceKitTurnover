# Data Burn-In User Guide And Roadmap

Data Burn-In lets editors preview and export customizable burn-in overlays from an FCPXML timeline. It is designed for review, turnover, source checking, VFX communication, and editorial QC without requiring users to inspect internal cache or manifest files.

This document is both the user-facing working guide and the internal roadmap. Keep finished items out of the roadmap section so the file stays useful for release preparation.

## What Data Burn-In Does

Data Burn-In reads an FCPXML timeline, builds an internal frame-resolved preview cache, and lets the user place live timeline/source data on top of a reference video or a transparent overlay.

Typical use cases:

- Show project, timeline timecode, source filename, and source timecode for editorial review.
- Add VFX notes or metadata such as scene, take, reel, camera name, lens, or custom metadata.
- Show analysis details such as retime, transform, scale, position, crop, stabilize, and optical flow.
- Add conditional messages, such as temporary audio warnings, when timeline data matches a condition.
- Export a burned-in reference video or a transparent ProRes 4444 overlay.

The preview cache is internal. Users should not need to choose, move, or edit cache files.

## Basic Workflow

### Standalone Customizer

1. Open Turnover standalone app.
2. Drop or choose an FCPXML/FCPXMLD file.
3. Switch to **Data Burn-In**.
4. Choose a reference video if exporting a burned-in reference.
5. Build the Data Burn-In cache.
6. Open **Customize**.
7. Choose a preset or edit the Custom preset.
8. Select a field position, type plain text, or use **Insert Data**.
9. Adjust display, metadata, analysis details, and style settings.
10. Optionally mark an export range with In/Out.
11. Export a burned-in reference or transparent overlay.

### SpliceKit One-Click Workflow

1. Open the Final Cut Pro project/timeline.
2. Choose **Turnover > Burn-In Transparent...**.
3. Choose a saved Data Burn-In preset from Turnover standalone.
4. Choose the output `.mov` path.
5. SpliceKit exports a temporary FCPXML snapshot, calls Turnover headless export, and reveals the transparent ProRes 4444 overlay when complete.

### SpliceKit Customize Workflow

1. Open the Final Cut Pro project/timeline.
2. Choose **Turnover > Burn-In Customize...**.
3. SpliceKit exports a temporary FCPXML snapshot.
4. Turnover standalone opens directly into the Data Burn-In Customizer with that FCPXML loaded.
5. Choose a video only if the user wants preview playback or burned-in reference export. Transparent overlay export can run without a reference video.

## Field Builder

Each burn-in field has:

- **Position:** Top, Middle, or Bottom across Left, Center, and Right.
- **Content:** plain text plus inserted dynamic data.
- **Show this field:** enables or disables that field.
- **Conditions:** optional append text when timeline data matches.

Plain text stays exactly as typed. Dynamic values use tokens inserted from **Insert Data**, but users should not need to memorize token names.

Useful examples:

```text
{project}
{source_file}
{source_tc} {metadata_custom}
TEMP AUDIO
```

## Dynamic Data

Supported user-facing data groups:

- Project and timeline values.
- Timeline timecode and timeline frame rate.
- Source filename and source timecode.
- Source layers and source layer timecode.
- Selected metadata.
- VFX title text or notes.
- Audio-role data for condition workflows.
- Analysis details such as retime, transform, scale, position, crop, stabilization, and optical flow.

Data that is missing for a frame should render as empty, not as `undefined`, raw internal metadata keys, or unrelated fallback values.

## Metadata

Metadata display is user-selected.

- Metadata names should be human-readable.
- Internal keys such as `com.apple...` or `kMDItem...` should be hidden or converted to readable names.
- If the user selects specific metadata keys, only those keys should render.
- If a selected key is missing on the current clip, render nothing for that key.
- If no metadata keys are selected, Turnover may use a sensible default metadata summary.

This avoids accidental noisy burn-ins where one token expands into every metadata key in the file.

## Source Layers

Source-derived fields follow Final Cut Pro's visible timeline model:

- **Primary source:** the Primary Storyline source at the timeline frame.
- **Layer 1, Layer 2, ...:** connected visible clips above the Primary Storyline.
- **Source layers setting:** limits how many connected layers are displayed.
- **Layer display:** Compact shows one short connected-clip line; Detailed uses selected source, metadata, and retime values.
- **Detail layout:** One Line keeps each layer compact; Two Lines separates the layer name from the selected values when a corner needs more readable spacing.
- **No fallback:** if no connected layer exists, show nothing for that layer.

Internal nested items inside a primary clip are not connected layers. Connected layers should come from clips visibly stacked above the sequence timeline.

Detailed layer labels follow the global **Show labels** rule and the Source Layers/Source Layer Details label override. Turning labels off should leave readable values separated by spacing, not noisy repeated prefixes.

## Analysis Details

Analysis Details are controlled by checkboxes so users can choose what appears:

- Transform
- Position
- Scale
- Rotation
- Crop
- Distort
- Spatial Conform
- Stabilize
- Optical Flow
- Retime

The displayed label should include only data relevant to the field and current frame. Repeated or default-only values should be avoided where possible.

## Preview Player

The Customizer preview supports:

- Space: play/pause
- J/K/L: shuttle-style playback controls
- Step backward/forward one frame
- I: mark In
- O: mark Out
- X: clear marked range

Keyboard shortcuts should work when the player or preview area is active, but should not steal typing while a text field is being edited.

If the selected reference video has audio, preview playback should play audio.

## Mark In/Out Export Range

Users can mark a shorter export range instead of exporting the full video.

- Marked range appears inside the scrub bar.
- The playhead/current-frame indicator should remain visible above the range.
- Export uses the marked range when both In and Out are set.
- Clearing the range returns export to full duration.

## Presets

Presets store reusable burn-in layouts.

Preset data should include:

- Field text and positions.
- Show/hide state per field.
- Labels and label overrides.
- File extension preference.
- Metadata selections.
- Conditions.
- Global and per-field style.
- Analysis detail options.
- Export settings.

Expected preset actions:

- **Save:** update the selected local preset.
- **Save As:** create a new named preset.
- **Import:** load a JSON preset from another machine.
- **Export:** save a JSON preset for sharing.
- **Delete:** remove a local preset when it is not protected.

The default state should feel like a Custom preset that users can immediately edit.

## Style Settings

Users can adjust:

- Font size.
- Text opacity.
- Text color with the macOS color picker.
- Background opacity.
- X/Y padding.
- Global style or per-field overrides.

Preview and export must match for font, size, opacity, color, padding, and anchor position.

## Export Modes

### Transparent Overlay

- Codec: ProRes 4444.
- Container: `.mov`.
- Includes alpha.
- Does not include audio.
- Used as an overlay in another editing or review workflow.

### Burned-In Reference

- Codec: H.264 or HEVC for this release.
- Container: MP4 or MOV.
- Includes audio when the selected reference video has audio.
- Uses the current layout, selected preset, and marked range.

Burned-in ProRes reference export is not enabled for this release because ProRes with audio still needs more investigation.

## SpliceKit Integration

The shared scripts should remain usable from both Turnover standalone and SpliceKit, but the product surface should be different.

### Data Burn-In In SpliceKit

Data Burn-In in SpliceKit has two entry points:

- **Burn-In Transparent...** exports the current Final Cut Pro project as temporary FCPXML, asks the user to choose one of the Data Burn-In presets saved in Turnover standalone, then calls the same Turnover headless export engine to render a transparent ProRes 4444 overlay.
- **Burn-In Customize...** exports the current Final Cut Pro project as temporary FCPXML and opens it in Turnover standalone for full preview, preset editing, range export, and custom layout work.

This keeps the renderer, parser, and preset library in one place. SpliceKit does not maintain its own hardcoded burn-in presets; it reads the preset list from the bundled or installed Turnover app. Rebuilding the full Burn-In UI inside Final Cut Pro would duplicate too much behavior and make it easy for standalone and plugin workflows to drift apart.

The first headless command surface is intentionally narrow:

- `--list-burn-in-presets` returns the presets currently available to Turnover standalone.
- `--burn-in-transparent --source-xml <path> --preset-id <id> --output <path>` builds the frame-resolved cache and renders a transparent ProRes 4444 overlay.

Live progress and cancellation inside the SpliceKit panel are still future polish. The current plugin waits for the headless export command to finish and then reveals the completed overlay file.

## Implementation Map

This section records the working paths so future changes do not require rediscovering the Burn-In flow from scratch.

### Source Files

- Standalone customizer UI: `standalone/TurnoverApp/Sources/Turnover/BurnInCustomizerView.swift`
- Standalone app/model/export orchestration: `standalone/TurnoverApp/Sources/Turnover/TurnoverModel.swift`
- Headless Burn-In CLI entry point: `standalone/TurnoverApp/Sources/Turnover/TurnoverHeadlessCommand.swift`
- Cache cleanup and cache size policy: `standalone/TurnoverApp/Sources/Turnover/CacheManager.swift`
- Build script that bundles resources into the app: `standalone/TurnoverApp/build_app.sh`
- Shared Burn-In manifest parser/resolver: `lua/scripts/build_data_burn_in_manifest.mjs`
- Shared FCPXML time model and parser helpers: `lua/scripts/lib/`
- SpliceKit native menu/panel integration: `plugins/com.turnover.tools/native/TurnoverToolsPlugin.m`
- SpliceKit plugin manifest/menu metadata: `plugins/com.turnover.tools/plugin.json`
- Plugin build/install helper: `plugins/com.turnover.tools/Build And Install Turnover Tools Plugin.command`

### Bundled Runtime Paths

The source manifest script is not copied directly into the SpliceKit plugin. It is bundled into Turnover.app, and SpliceKit calls Turnover.app for Burn-In work.

After running `./standalone/TurnoverApp/build_app.sh`, the active bundled script should exist at:

```text
standalone/TurnoverApp/build/Turnover.app/Contents/Resources/scripts/build_data_burn_in_manifest.mjs
```

The bundled shared library folder should exist at:

```text
standalone/TurnoverApp/build/Turnover.app/Contents/Resources/scripts/lib/
```

SpliceKit Burn-In currently resolves Turnover.app in this order:

1. `plugins/com.turnover.tools/Turnover.app`
2. `/Applications/Turnover.app`
3. `~/Applications/Turnover.app`
4. `standalone/TurnoverApp/build/Turnover.app`

The release package should include the matching `Turnover.app` at `plugins/com.turnover.tools/Turnover.app`. That keeps SpliceKit Burn-In tied to the parser, presets, and headless export command shipped in the same release. For local development, the fourth path is useful; before debugging a SpliceKit Burn-In issue, confirm which app path the plugin resolved.

### SpliceKit Burn-In Commands

SpliceKit should not reimplement the Burn-In parser. It exports the active Final Cut Pro project as an FCPXML snapshot and delegates to Turnover.

Preset listing:

```text
Turnover --list-burn-in-presets
```

Transparent overlay export:

```text
Turnover --burn-in-transparent \
  --source-xml <exported-fcpxml> \
  --preset-id <preset-id> \
  --output <output.mov>
```

Open in standalone customizer:

```text
Turnover --open-burn-in-customize <exported-fcpxml>
```

### Update Checklist For Burn-In Script Changes

When `lua/scripts/build_data_burn_in_manifest.mjs` or `lua/scripts/lib/` changes:

1. Run `swiftc -parse standalone/TurnoverApp/Sources/Turnover/*.swift`.
2. Run `git diff --check`.
3. Run `./standalone/TurnoverApp/build_app.sh`.
4. Confirm the changed script was copied into `standalone/TurnoverApp/build/Turnover.app/Contents/Resources/scripts/`.
5. If SpliceKit menu/native code changed, run `./plugins/com.turnover.tools/Build And Install Turnover Tools Plugin.command`.
6. If building a release, run `./scripts/build_release.sh` and confirm the SpliceKit zip contains `plugins/com.turnover.tools/Turnover.app`.
7. If testing SpliceKit Burn-In, make sure the plugin is resolving the intended Turnover.app version, not an older app in `/Applications`.

### Manual Smoke Test Matrix

Use these checks before saying Burn-In is release-ready:

- Standalone cache build reads the latest FCPXML without JavaScript exceptions.
- SpliceKit **Burn-In Customize...** opens Turnover with the exported FCPXML already loaded.
- SpliceKit **Burn-In Transparent...** lists standalone presets and exports a ProRes 4444 alpha `.mov`.
- Release SpliceKit package bundles the matching `Turnover.app` used for Burn-In headless commands.
- Transparent export has alpha, has no audio, and its source timecode matches known visual burn-in frames.
- Standalone burned-in H.264/HEVC export includes audio when the selected reference video has audio.
- Preview and export match font, opacity, color, padding, and position.
- Metadata only renders selected human-readable values.
- Connected layers show only real connected video layers above the visible sequence timeline.
- Retime labels distinguish no retime, constant speed, reverse, hold, and speed ramps.
- Mark In/Out export uses the selected range and keeps audio in sync.

### Marker Export In SpliceKit

Marker Export maps directly to SpliceKit:

- The plugin shows a compact prompt for marker filter, output format, and destination.
- Supported filters are all markers, standard, to-do, chapter, and Turnover recheck markers.
- Supported formats are EDL, CSV, and TXT.
- The plugin exports the current Final Cut Pro project to FCPXML, then calls the same shared marker export script used by standalone.
- The exported file is revealed in Finder when complete.

### Shared Script Contract

Scripts used by both environments should:

- Accept stable file/path/options arguments.
- Return structured JSON status and errors.
- Avoid UI assumptions.
- Keep shared libraries such as the FCPXML time model bundled with both standalone and SpliceKit runtimes.
- Have smoke tests that run the same script path from standalone packaging and SpliceKit packaging.

## Export Queue

Exports can be queued.

- **Now Exporting:** shows the current job.
- **Queued:** shows pending jobs.
- **Stop Current:** cancels the current export and continues with the next queued job.
- **Stop All:** cancels the current export and clears the queue.
- Completed jobs may reveal in Finder if enabled.

The main window should show enough status to reassure the user that export is progressing, while the Customizer sidebar can show more detailed export context.

## Disk Space And Temporary Files

Turnover should write export output near the final destination using a temporary name, then rename it at completion. This avoids requiring twice the local system disk space when users export to external drives.

Expected behavior:

- Estimate output size before export when possible.
- Warn clearly if free space is likely insufficient.
- Clean up failed or canceled temporary files.
- Avoid showing confusing "needed space" numbers that imply double usage unless double usage is actually required.

## Technical Model

Burn-In evaluates values per frame, so EDL-style head/tail math is not enough.

The resolver should:

- Use rational time math instead of accumulated floating-point frame math.
- Read `timept` `time`, `value`, `interp`, `inTime`, and `outTime`.
- Support smooth2/speed-ramp interpolation.
- Compose nested timeMaps from clips, sync clips, and source clips.
- Handle reverse, hold, one-frame hold edges, and conform-rate clips.
- Resolve keyframed transform values per frame where FCPXML provides keyframes.
- Return only visible sources at a timeline frame.

Long-term direction: share the stronger Conform Prep retime/time-domain model instead of maintaining parallel resolver rules.

## Release Scope

For the next release, Data Burn-In should include:

- Customizer window with preview, field builder, sidebar settings, presets, and import/export preset support.
- Nine placement anchors.
- Plain text plus Insert Data.
- Human-readable metadata selections.
- Source layer and source layer TC support.
- Analysis detail toggles.
- Mark In/Out export range.
- Export queue with progress, ETA, Stop Current, and Stop All.
- Transparent ProRes 4444 overlay.
- Burned-in H.264/HEVC reference export with audio.

Out of scope for this release:

- Burned-in ProRes 422 Proxy/LT/422/HQ/4444 with audio.
- Perfect audio channel-layout parity for every source shape.
- Metal/Core Image compositor.
- Full background render architecture equal to Final Cut Pro.

## Known Gaps

- Preview timecode may still lag slightly during playback; export output is the accuracy target for release.
- Retime and keyframed transform parsing needs fixture-backed regression coverage.
- Conditions are still mostly audio-role oriented; future conditions should support source, metadata, and analysis fields generically.
- ProRes burned-in export remains deferred until audio/container behavior is reliable.
- Export size estimates need calibration per codec, container, duration, and alpha/burned-in mode.

## Export Benchmarking

Use app-reported export metrics and `ExportBenchmarks.tsv` when comparing renderer changes. Record:

- source project/video
- selected mode, codec, container, and range duration
- whether the Customizer window was open and playing
- elapsed time
- rendered frames
- render fps
- realtime multiple
- output file size
- audio present or no audio

Known early benchmark:

- `Prasert_R2_D6-BurnIn.mp4`
- MP4, H.264, 1920x1080, 24 fps
- duration: 1518.166667 seconds
- size: about 1.19 GB
- video: about 6 Mbps
- audio: AAC, about 253 kbps
- early observed export time: about 12-13 minutes

Benchmarks are only comparable when the same project, range, codec/container, and UI state are used.

## Release Test Checklist

- Build cache succeeds on the latest real FCPXML without `ReferenceError`, DTD issues, or missing bundled scripts.
- Preview opens with and without a selected reference video.
- Keyboard playback works without focusing text fields.
- Preview audio plays when the selected video has audio.
- Preview and export match style and placement.
- Transparent ProRes 4444 exports real alpha, has no audio, and reports a realistic estimate.
- Burned-in H.264 exports with audio in MP4 and MOV.
- Burned-in HEVC exports with audio in MP4 and MOV.
- Mark In/Out exports only the selected range and keeps audio in sync.
- Export queue runs jobs in order.
- Presets preserve layout, labels, conditions, style, metadata selections, export settings, and analysis options.
- Metadata renders only selected human-readable keys.
- Source layer and layer TC do not show connected clips when no connected layer exists.
- Retime display covers no-retime, constant speed, reverse, hold, and speed-ramp examples.
- Keyframed transform display updates dynamically where FCPXML contains keyframes.

## Fixture And Regression Plan

Create minimized, non-confidential fixtures before release candidates:

- no retime
- constant speed 50%, 90%, 100%, 120%, 200%, 2000%
- reverse speed
- hold/freeze frame
- speed ramp 100 -> 200 -> 100
- speed ramp 200 -> 100
- nested sync clip with retime
- keyframed scale/position/rotation
- primary-only shot with no connected layers
- primary plus one connected video layer
- primary plus multiple connected layers
- selected custom metadata keys present/missing
- audio-role condition present/missing
- transparent export range
- H.264/HEVC export range with audio

The first useful automation does not need to render full movies. It can build the manifest and assert expected values at specific timeline timecodes.

## Pre-Release Cleanup

- Clear local Data Burn-In cache outputs used during manual testing.
- Remove stale temporary export files left by canceled or failed exports.
- Confirm docs do not keep duplicate completed TODOs.
- Confirm `.gitignore` covers standalone builds, release staging, logs, dylibs, and local node modules.
- Keep ProRes burned-in investigation notes out of user-facing release notes unless it is enabled again.

## References

- [Metaburner](https://metaburner.fcp.cafe/)
- [FCPXML Analysis And Style Recheck Report](fcpxml-analysis-recheck-report.md)
- [DaVinci Resolve 21 New Features Guide](https://documents.blackmagicdesign.com/SupportNotes/DaVinci_Resolve_21_New_Features_Guide.pdf)
- [Create a title template in Motion](https://support.apple.com/guide/motion/create-a-title-template-motn141bb14b/mac)
- [Publishing template text controls in Motion](https://support.apple.com/guide/motion/publish-template-text-controls-motn141bd5fe/mac)
