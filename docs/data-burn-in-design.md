# Data Burn-In Design And Future Plan

Data Burn-In is currently parked. This document keeps the useful design decisions and gap analysis in one place so the feature can resume later without pulling prototype work into the current Conform Prep stabilization cycle.

## Goal

Build a customizable metadata burn-in system for Turnover that can render timeline/source metadata without making existing FCPXML tools depend on a new parser or forcing the standalone and SpliceKit editions to use unrelated metadata rules.

## Current Status

- The prototype can build a `BurnInManifest` and preview resolved values.
- It does not yet render a final transparent overlay or composited movie.
- Source timecode through speed ramps, reverse, holds, and nested retimes is not reliable enough yet.
- The feature should stay hidden/parked until its visible-frame resolver is trustworthy.

## Key Lesson From The Current Prototype

The current prototype leans on helpers from `build_vfx_pull_edl.mjs`. That is acceptable for EDL-style workflows that mostly care about shot in/out boundaries, but it is not enough for burn-in because burn-in must evaluate source state on every frame.

For future Burn-In work, tools that need frame-accurate visible source timecode should reuse the stronger Conform Prep retime/time-domain model rather than the lighter Pull EDL segment resolver.

Needed resolver behavior:

- Read `timept` `interp`, `inTime`, and `outTime`, not only `time` and `value`.
- Support smooth2/speed-ramp interpolation.
- Compose nested timeMaps from sync clips and source clips.
- Handle reverse, hold, one-frame hold edges, and conform-rate clips.
- Return all visible layers at a timeline frame, not just one source interval.

## Reference Behavior

DaVinci Resolve is the useful UX reference: users add fields, mix typed text with metadata variables, enable fields independently, and control font, alignment, color, opacity, background, placement, and X/Y position.

Turnover does not need full Resolve parity at first. The important parts are:

- timeline timecode
- source filename
- source timecode
- project/event name
- marker name/note
- VFX number/note
- selected metadata keys
- predictable placement presets
- JSON presets that work in both editions

## Recommended Architecture

Use one shared metadata and timing core with host adapters for standalone and SpliceKit:

1. Parse FCPXML into a `BurnInManifest` containing timeline intervals, visible source clips, source/timeline timecode mapping, markers, roles, and metadata.
2. Store user layout as a portable JSON preset.
3. Render one transparent ProRes 4444 overlay movie using AVFoundation/Core Graphics or Metal.
4. Generate FCPXML that imports the overlay and connects it above the timeline.

This avoids hundreds of generated title clips, title ownership/connection-point bugs, and Motion-template limitations.

## Output Modes

- **Reference video selected:** composite burn-in fields over the selected video and encode a new movie. Match resolution, frame rate, and color metadata where possible. Because the video must be decoded and re-encoded, do not imply bit-for-bit passthrough.
- **No video selected:** render a transparent ProRes 4444 overlay at the timeline resolution and frame rate. Width, height, frame duration/FPS, and color space come from the sequence `<format>`. If dimensions are missing, ask the user instead of guessing.

## UI Direction

Keep the main Turnover window focused on tool selection. Data Burn-In should open a dedicated editor with:

- **Canvas Preview:** resizable preview with title/action safe guides; fields can be selected and dragged.
- **Fields List:** ordered layers with enable, duplicate, rename, reorder, and delete controls.
- **Field Inspector:** content, conditions, typography, background, placement, and timing controls.

The first preset should be simple: timeline TC, source filename, source TC, and project name. Additional fields should come from an `Add Field` menu instead of exposing every possible checkbox at once.

## Field Model

Each field is a text template that can combine literal text and tokens:

```text
SOURCE: {source_file}
TC: {source_tc}
```

Initial tokens:

- `{project}`
- `{event}`
- `{timeline_tc}`
- `{timeline_frame}`
- `{source_tc}`
- `{source_file}`
- `{reel}`
- `{scene}`
- `{shot}`
- `{angle}`
- `{role}`
- `{marker}`
- `{marker_note}`
- `{vfx_number}`
- `{metadata:key}`

Each field should support enable/disable, template text, anchor, X/Y offset, font, size, alignment, text/background color and opacity, padding, outline/shadow, and first/last-frame display limits.

## Conditions

Fields may have simple condition rows instead of requiring expressions:

```text
Show when  Audio Role  contains  Dialogue
Display    INTERVIEW AUDIO
```

Initial condition properties:

- Video role and subrole
- Audio role and subrole
- Source filename
- Reel, scene, shot, angle, and camera name
- Marker name, note, and marker type
- VFX number
- Project or event name
- Timeline range
- Metadata key

Initial operators:

- is / is not
- contains / does not contain
- starts with / ends with
- exists / is empty
- matches regular expression (advanced)

For audio conditions, `active` should mean enabled audio components overlapping the current frame and matching the requested role. Muted or disabled components should not trigger a field when that state is represented in FCPXML.

## Multiple Visible Video Layers

Clip-derived fields use Primary Storyline as the base. Connected video layers follow Final Cut Pro lane/stack order and can be added upward.

Layer policies:

- **Primary Storyline + Connected Layers:** resolve Primary Storyline first, then connected layers upward.
- **Primary Storyline Only:** resolve only the primary storyline source.
- **Top Visible:** resolve tokens from the highest enabled visible video layer.
- **All Visible:** repeat the field once for every visible source layer.
- **Selected Role/Lane:** resolve only sources matching the chosen video role or lane.

Project-level fields render once per frame. Clip-level fields can repeat according to the selected layer policy.

## Proposed Delivery Stages

1. Define a shared visible-frame resolver contract: timeline time in, visible source layers/source TC/speed state/metadata out.
2. Back that resolver with the Conform Prep retime model or an extracted module from it.
3. Build a manifest prototype with timeline TC, source TC, source filename, project, and VFX number.
4. Add static preview canvas and JSON preset editing.
5. Add transparent ProRes 4444 overlay rendering.
6. Add optional reference-movie compositing and SpliceKit automatic import.

## Important Rules

- Data Burn-In should remain separate from Conform Prep output generation so it cannot regress flattening behavior.
- Shared resolver extraction should happen only after Conform Prep remains stable across more real-world cases.
- Missing values should resolve to an empty string or user-defined fallback, never a literal undefined token.
- Avoid FFmpeg at first; prefer AVFoundation to keep the app compact and reduce runtime/license surface.

## References

- [Metaburner](https://metaburner.fcp.cafe/)
- [DaVinci Resolve 21 New Features Guide](https://documents.blackmagicdesign.com/SupportNotes/DaVinci_Resolve_21_New_Features_Guide.pdf)
- [Create a title template in Motion](https://support.apple.com/guide/motion/create-a-title-template-motn141bb14b/mac)
- [Publishing template text controls in Motion](https://support.apple.com/guide/motion/publish-template-text-controls-motn141bd5fe/mac)
