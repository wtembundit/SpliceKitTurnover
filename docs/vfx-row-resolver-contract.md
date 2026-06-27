# VFX Row Resolver Contract

This note records the shared VFX row model used by Turnover tools that derive VFX shots from Final Cut Pro timelines.

## Core Rule

`VFX Shot List` and `VFX Pull EDL` must resolve VFX shots from the same conceptual row model.

The resolver contract is:

- `VFX NAMING` titles are the source of truth for VFX number, note/description, and visible shot range.
- Markers are anchors that identify where the VFX shot should be sampled or pulled from.
- Marker names do not need to be renamed to the VFX number.
- A marker should be matched to the VFX title whose visible range contains the marker, or whose VFX number matches the marker value when renamed markers are enabled.
- Source information should be collected from the title visible range, then filtered by the marker/context source keys to avoid sweeping unrelated clips.
- Multiple overlapping source layers under one VFX title should be preserved as separate layers when they are genuinely part of the VFX shot.
- Duplicate anchors for the same title should be deduped conservatively without deleting real stacked layers.

## Why This Exists

Earlier versions let each tool infer VFX rows independently. That caused drift:

- `VFX Shot List` correctly used markers as capture anchors and titles as shot metadata.
- `VFX Pull EDL` briefly used title-only global overlap, which over-collected unrelated source segments and produced many extra EDL rows.

The correct relationship is:

```text
VFX Auto Marker -> marker anchors
VFX NAMING titles -> VFX number, note, visible range
VFX Shot List -> thumbnails and Excel rows from the shared row model
VFX Pull EDL -> source pull EDL events from the same shared row model
```

## Regression Requirement

Any future change to VFX row detection in one tool must be checked against the other tool.

When changing `VFX Shot List`, recheck:

- Does `VFX Pull EDL` still produce the same VFX shot count?
- Are VFX numbers and notes still derived from titles rather than marker rename text?
- Are multi-layer shots preserved without row explosion?
- Are default markers such as `Marker 1` still usable as anchors?

When changing `VFX Pull EDL`, recheck:

- Does `VFX Shot List` still capture the same VFX shot set?
- Are marker anchors still matched to the same VFX titles?
- Are source filenames and source TC ranges still consistent with shot-list source fields?
- Are speed/retime-heavy shots represented without losing the intended source range?

## Important Edge Cases

Use real-project fixtures for these cases:

- A VFX title covering a single retimed clip.
- A VFX title covering one clip with multiple blade-speed/speed-ramp segments.
- A VFX title covering multiple stacked visible source clips.
- A VFX title connected to one clip but visually spanning adjacent clips.
- Markers that are intentionally not renamed and still read as `Marker N`.
- Optional renamed markers whose values match the VFX number.
- Default unnamed source markers that should be ignored by cleanup logic.

## Implementation Direction

The long-term direction is to extract a shared JavaScript module, for example:

```text
lua/scripts/lib/vfx_row_resolver.mjs
```

That module should expose one resolver used by both tools:

```text
resolveVfxRows(xml, assetMap, effectMap, options)
```

Until the shared module exists, keep the selection logic in `VFX Shot List` and `VFX Pull EDL` intentionally mirrored.

