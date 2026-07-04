# Data Burn-In Design Study

## Goal

Build a customizable metadata burn-in system for Turnover without making existing FCPXML tools depend on a new parser or forcing the SpliceKit and standalone editions to use unrelated metadata rules.

## Reference Behavior

DaVinci Resolve's Data Burn-In model is the useful UX reference: users add fields, combine typed text with metadata variables, enable fields independently, and control font, alignment, color, opacity, background, placement, and X/Y position. Resolve also supports logos and clip/timeline-aware values.

Metaburner demonstrates what is possible inside Final Cut Pro: a title can receive a dragged FCPXML project, expose many metadata text layers, and use Lua for custom expressions. This is powerful, but it keeps the workflow tied to a specialized title and Final Cut Pro's title/template lifecycle.

Apple Motion templates can publish text and styling parameters to Final Cut Pro. They are suitable for editable static overlays, but they do not provide Turnover's full timeline/source resolver or automatically evaluate arbitrary FCPXML metadata at every frame.

## Recommended Architecture

Use one shared metadata and timing core with two host adapters:

1. Parse FCPXML into a `BurnInManifest` containing timeline intervals, resolved visible source clips, source/timeline timecode mapping, markers, roles, and custom metadata.
2. Store user layout as a portable JSON preset.
3. Render one transparent ProRes 4444 overlay movie using AVFoundation/Core Graphics or Metal.
4. Generate FCPXML that imports the overlay and connects it above the timeline.

This avoids hundreds of generated title clips, title ownership/connection-point bugs, and Motion-template limitations. The overlay is non-destructive and can be disabled or removed as one item.

### Standalone

- Accept FCPXML/FCPXMLD and a burn-in preset.
- Render a transparent overlay movie without requiring source media.
- Optionally composite the overlay into a user-selected reference movie.
- Export overlay media plus an importable FCPXML result.

### Output Modes

The main Data Burn-In settings expose a preset and an optional video input:

1. **Video selected**: composite burn-in fields over the selected video and encode a new movie. Match the source resolution, frame rate, color metadata, and audio layout where supported. Compositing necessarily decodes and re-encodes video, so codec passthrough is not possible. Offer `Match Source` as a quality/container policy with explicit ProRes, H.264, and HEVC alternatives rather than implying bit-for-bit source passthrough.
2. **No video selected**: render a transparent ProRes 4444 overlay at the timeline resolution and frame rate. This can be imported above the Final Cut Pro timeline or composited elsewhere.

Transparent output derives width, height, frame duration/FPS, and color space from the sequence's referenced FCPXML `<format>`. If dimensions are absent, Turnover must ask for an explicit output size instead of silently guessing.

The customizer uses the selected video as its preview background. Without a video it uses a transparent/checkerboard canvas.

### SpliceKit

- Export the current project FCPXML.
- Run the same manifest builder and renderer.
- Import the overlay media and generated FCPXML automatically.
- Keep live viewer automation optional; it is not required for burn-in rendering.

## Custom Fields

The customizer exposes six independent fields: Top Left, Top Center, Top Right, Bottom Left, Bottom Center, and Bottom Right. Each field owns its enabled state, text/template, font size, color, background, and padding. Literal custom text can be typed directly; tokens are optional and can be mixed with that text.

Initial tokens should include:

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

Each field should support enable/disable, template text, anchor, X/Y offset, font, size, alignment, text/background color and opacity, padding, outline/shadow, and first/last-frame display limits. Presets should be saved as JSON and work in both editions.

## Proposed User Interface

Keep the main Turnover window focused on tool selection. Opening Data Burn-In should present a dedicated editor with three areas:

1. **Canvas Preview**: a resizable 16:9 preview with title/action safe guides. Fields can be selected and dragged; exact X/Y controls remain available in the inspector.
2. **Fields List**: ordered overlay layers with enable, duplicate, rename, reorder, and delete controls. Built-in fields and custom fields use the same model.
3. **Field Inspector**: content, condition, typography, background, placement, and timing controls for the selected field.

The first-run preset should contain only timeline timecode, source filename, source timecode, and project name. Additional fields are added from an `Add Field` menu rather than exposing every possible checkbox at once.

### Field Content

Every field is a text template that can combine literal text and tokens, for example:

```text
SOURCE: {source_file}
TC: {source_tc}
```

The editor should provide a token picker, token search, live resolved preview, fallback text, and a choice between hiding the field or showing the fallback when a value is unavailable.

### Conditions

Each field may have zero or more conditions. Conditions should be assembled using simple rows rather than requiring users to write expressions:

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

Multiple conditions support `All` and `Any`. A field can either hide when its condition fails or use alternate text. This covers workflows such as showing `TEMP VO`, `MUSIC CUE`, or another custom message whenever a matching audio role is active.

For audio conditions, the manifest must define what `active` means. The first implementation should use enabled audio components that overlap the current timeline frame and match the requested role. Muted or disabled components should not trigger a field when that state is represented in FCPXML. If multiple matching roles overlap, the field remains visible and token values are joined using a user-selected policy (`first`, `all`, or `highest subrole priority`).

### Style and Placement

- Font family, weight, size, line spacing, and alignment
- Text color and opacity
- Optional background color, opacity, padding, and corner radius
- Optional outline and shadow
- Nine-point anchor grid plus X/Y position
- Pixel or percentage coordinates
- Title-safe and action-safe snapping
- Layer order

### Timing

- Entire timeline
- Only while token data exists
- Only while conditions match
- Marker range
- Custom timeline in/out
- Optional fade in/out

Time-varying tokens such as timeline TC, source TC, source filename, roles, and markers are evaluated for every output frame. They therefore update during playback even though the overlay movie is rendered in advance.

### Multiple Visible Video Layers

Clip-derived fields use Primary Storyline as the base. Connected video layers follow Final Cut Pro lane/stack order and are added upward. Project-level fields render once; clip-level fields can add one row per visible layer, beginning with Primary Storyline.

- `Primary Storyline + Connected Layers` (default): resolve Primary Storyline first, then repeat connected layers upward in lane/stack order.
- `Primary Storyline Only`: resolve only the primary storyline source.
- `Top Visible`: resolve tokens from the highest enabled visible video layer.
- `All Visible`: repeat the field once for every visible source layer.
- `Selected Role/Lane`: resolve only sources matching the chosen video role or lane.

For `All Visible`, repeated rows stack inward from the selected anchor. Top anchors grow downward; bottom anchors grow upward; left/right/center alignment follows the anchor. Field controls include row spacing, maximum rows, and overflow behavior (`+N more`, truncate, or wrap). Layer ordering follows visual compositing order, topmost first, and each row may expose `{layer_index}`, `{lane}`, `{video_role}`, `{source_file}`, and `{source_tc}`.

Project-level fields and clip-level fields remain separate groups. Project fields render once per frame, while clip fields apply the selected layer policy. This prevents project/timecode labels from being duplicated merely because several clips overlap.

### Presets

- Save, duplicate, rename, import, and export JSON presets
- Presets remain portable between standalone and SpliceKit editions
- A preset stores layout and rules, never project-specific resolved values
- Ship a small set of defaults: `Editorial Review`, `VFX Review`, `Source QC`, and `Audio Review`

## Scope for v1.3.2

The first implementation should prove the data and interaction model without committing to the final renderer:

1. Build `BurnInManifest` for timeline TC, source TC, source filename, project, VFX number, video role, and audio roles.
2. Add a standalone Data Burn-In editor with field list, custom text/tokens, basic style, nine-point placement, and simple conditions.
3. Add a frame scrubber that previews resolved values and verifies retime/reverse/hold behavior.
4. Save and load portable JSON presets.
5. Export a diagnostic manifest and preview image sequence before implementing the transparent ProRes renderer.

Defer logos, arbitrary expressions, animation, reference-movie compositing, and automatic SpliceKit import until the manifest and condition results pass real-project fixtures.

## Important Rules

- Timeline and source timecode must be evaluated per frame through the same visible-timeline and retime resolver used by Turnover's tested workflows.
- Stacked clips need an explicit policy: top visible source, all visible sources, or selected role/lane.
- Missing values should resolve to an empty string or a user-defined fallback, never a literal undefined token.
- Rendering should remain separate from FCPXML transformation so it cannot regress Conform Prep, Shot List, EDL, or Auto Marker.
- The first implementation should use AVFoundation rather than bundling FFmpeg, keeping the application compact and avoiding another runtime/license surface.

## Proposed Delivery Stages

1. Manifest prototype with timeline TC, source TC, source filename, project, and VFX number.
2. Static preview canvas and JSON preset editor.
3. Transparent ProRes 4444 overlay rendering.
4. Standalone FCPXML export and SpliceKit automatic import.
5. Optional reference-movie composite and logo fields.

## References

- [Metaburner](https://metaburner.fcp.cafe/)
- [DaVinci Resolve 21 New Features Guide](https://documents.blackmagicdesign.com/SupportNotes/DaVinci_Resolve_21_New_Features_Guide.pdf)
- [Create a title template in Motion](https://support.apple.com/guide/motion/create-a-title-template-motn141bb14b/mac)
- [Publishing template text controls in Motion](https://support.apple.com/guide/motion/publish-template-text-controls-motn141bd5fe/mac)
