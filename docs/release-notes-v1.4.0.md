# Turnover v1.4.0 Release Notes

Turnover v1.4.0 is a larger workflow release for both the standalone app and the native SpliceKit plugin. The headline change is Data Burn-In: a customizable preview and export workflow for review overlays, transparent ProRes 4444 burn-ins, metadata, source timecode, and SpliceKit one-click handoff.

## Data Burn-In

- Restored and expanded the Data Burn-In Customizer in the standalone app.
- Added nine burn-in positions: top, middle, and bottom across left, center, and right.
- Added field editing with plain text plus **Insert Data** for timeline, source, metadata, VFX, audio, connected layer, and analysis values.
- Added presets with save, save as, import, export, duplicate, delete, and local JSON sharing.
- Added human-readable metadata selection for scene, shot, take, reel, camera, lens, and custom metadata values.
- Added connected layer display controls for source layer details without mixing in unrelated primary or internal nested clips.
- Added analysis detail controls for transform, position, scale, rotation, crop, distort, spatial conform, stabilize, optical flow, and retime.
- Added global and per-field style controls, including macOS color picker, font size, text opacity, background opacity, and X/Y padding.
- Added preview keyboard controls for playback, frame stepping, and In/Out range marking.

## Export

- Added transparent ProRes 4444 overlay export with alpha and no audio.
- Added burned-in H.264 and HEVC reference export with MP4/MOV container choices.
- Added audio playback in the preview when the selected reference video has audio.
- Added marked range export so users can render only an In/Out section.
- Added export queue, progress, ETA, Stop Current, and Stop All controls.
- Improved disk-space handling by writing export work near the selected destination and cleaning failed/canceled temporary files.
- Calibrated export size estimates for the release-supported codecs.

## SpliceKit Plugin

- Added **Burn-In Transparent...** for one-click transparent overlay export from the current Final Cut Pro timeline.
- Added **Burn-In Customize...** to open the current Final Cut Pro timeline directly in the Turnover standalone Data Burn-In Customizer.
- Added Turnover headless Burn-In commands so SpliceKit can reuse the same parser, presets, and renderer as the standalone app.
- Added Marker Export to the SpliceKit workflow using the shared marker export script.
- Shortened Burn-In menu labels for readability.

## Parser And Resolver

- Improved frame-resolved source filename and source timecode lookup.
- Improved retime labels for no retime, constant speed, reverse, holds, and common speed ramps.
- Improved keyframed transform reporting where FCPXML provides animated transform data.
- Reduced noisy or repeated analysis labels.
- Fixed selected metadata rendering so missing selected keys stay empty instead of falling back to unrelated metadata.
- Fixed custom metadata display so internal `com.apple...` and `kMDItem...` keys are converted to readable names or hidden.

## Release Scope Notes

- Burned-in ProRes reference export is intentionally deferred. Transparent ProRes 4444 overlay export is enabled, but burned-in ProRes with audio still needs more container/audio investigation.
- Multicam `mc-clip` timelines are not supported at release-quality accuracy yet. For multicam projects, flatten multicam clips before running Data Burn-In; Turnover's current resolver should not be used as a reliable source/timecode reference for active multicam angles.
- Preview timecode can still feel slightly less fluid during playback on heavy timelines. Export output remains the accuracy target.
- Complex, previously unseen FCPXML retime and connected-layer shapes should still be reported with reduced reproducible examples.
