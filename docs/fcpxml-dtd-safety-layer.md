# FCPXML DTD Safety Layer Notes

Turnover tools should treat FCPXML DTD validation as a shared safety layer, not as a one-off Conform Prep fix.

The goal is to improve import reliability without changing working editorial workflows unexpectedly.

## Source Of Truth

Prefer the DTD files bundled inside the user's installed Final Cut Pro app:

```text
/Applications/Final Cut Pro.app/Contents/Frameworks/Interchange.framework/Versions/A/Resources/FCPXMLv1_14.dtd
```

Final Cut Pro can include multiple DTD versions, such as `FCPXMLv1_0.dtd` through `FCPXMLv1_14.dtd`. The validator should pick the DTD that matches the XML root version:

```xml
<fcpxml version="1.12">
```

For `version="1.12"`, validate with `FCPXMLv1_12.dtd`.

## Conservative Rollout

Do not force every Turnover tool through a new validator at once.

Recommended rollout:

1. Add standalone validation and reporting utilities.
2. Keep existing working tools unchanged.
3. Enable validation only for tools that already generate/import patched FCPXML.
4. Start with warning/report mode for older tools.
5. Move to hard-fail before import only after a tool's output has passed real timeline testing.

This avoids breaking workflows that currently succeed even if their XML is unusual.

## Shared Pipeline

Every FCPXML-generating tool should eventually follow this shape:

```text
export source XML
generate patched XML
normalize DTD-sensitive structure
validate patched XML
write report
import only if validation passes
```

If validation fails, the tool must write a report even if no patched XML is created. Silent failure is not acceptable.

## Common DTD Failure Classes

Most DTD failures we have seen fall into these classes:

- Child elements are emitted in the wrong order, such as `adjust-transform` before `adjust-conform`.
- A valid element is emitted under the wrong parent.
- Story elements are emitted as siblings where only clip children are allowed.
- Markers or keywords are emitted as top-level spine siblings instead of clip children.
- Duplicate IDs, especially `text-style-def` IDs.
- Unsupported or newly introduced FCP elements are treated as generic story elements.

## DTD-Sensitive Parent Elements

Prioritize shared normalizers for these parent elements:

- `clip`
- `asset-clip`
- `video`
- `title`
- `spine`
- `sync-clip`
- `gap`

The normalizer should bucket child elements and emit them in DTD order. Scripts should not append children in whatever order they were discovered.

## Current Conform Prep Rules Worth Reusing

These rules should become shared utilities where possible:

- Preserve `object-tracker` before adjustment elements.
- Sort intrinsic adjustments in DTD order.
- Keep meaningful markers attached to clips; do not emit markers as top-level spine siblings.
- Remove only default unnamed source markers such as `Marker 1` with no note.
- Keep `metadata` last inside DTD-sensitive clip-like elements.
- Normalize duplicate `text-style-def` IDs.

## Hold/Freeze Segmentation

Conform Prep handles normal hold/freeze sections and longer clips with hold tails. Final Cut Pro rejects some flattened single-clip `timeMap` structures when a one-frame live segment transitions immediately into a hold.

For this shape, Conform Prep emits two adjacent clips: one normal one-frame segment followed by one pure-hold segment. This preserves the visible frame sequence and total timeline duration, but increases the structural clip count by one. Verification should treat this reported split as expected retime segmentation rather than an added or duplicated shot.

## External Reference

Pipeline Neo is a useful architecture reference:

```text
https://github.com/TheAcharya/pipeline-neo
```

Notable design ideas:

- Typed FCPXML model layer.
- Dedicated parsing layer.
- Dedicated validation layer.
- Embedded DTD provider.
- Structural validation in addition to DTD validation.
- Large FCPXML sample test suite.

Turnover does not need to migrate all at once, but the long-term direction should be a shared FCPXML safety layer rather than script-local string patching.
