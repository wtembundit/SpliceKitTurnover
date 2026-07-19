# FCPXML Analysis And Style Recheck Report

This note documents the lightweight recheck report pattern used by VFX tools and reserved for future Data Burn-In work.

The goal is to warn users about timeline items that may need visual rechecking after an FCPXML roundtrip while keeping the timeline edits as small and predictable as possible.

## Why This Exists

Some Final Cut Pro states are analysis/effect dependent. They can be fragile when a project is exported, patched, and imported again, especially if the tool changes more XML than necessary.

Examples:

- Magnetic Mask
- Stabilization
- Optical Flow / Optical Flow FRC
- Title text styling and fonts

For VFX tools such as Auto Marker and VFX Naming, the rule is:

- Only change the XML required by the selected tool.
- Keep project `uid` unchanged.
- Project display name may be renamed to make the imported result clear to the user.
- Keep a full recheck report for debugging.
- Add limited visible recheck markers for high-risk items users are unlikely to find from a report alone.

## Current XML Detection Rules

The current scripts detect recheck items with simple XML scans:

```text
Magnetic Mask:
<filter-video ... name="Magnetic Mask" ...>

Object Tracking / analysis sidecar:
<object-tracker>
  <tracking-shape ... dataLocator="r56"/>
</object-tracker>
<locator id="r56" url="Contents/Effects/ObjectTracking/....plist"/>

Stabilization:
<adjust-stabilization ...>

Optical Flow:
<timeMap ... frameSampling="optical-flow..." ...>
```

These checks are intentionally conservative. They do not try to verify that Final Cut Pro will preserve the analyzed result. They only tell the user, "this timeline contains something worth checking after import."

## Visible Recheck Markers

Auto Marker, VFX Naming/Reset, and VFX Timeline can add completed to-do markers for high-risk analysis items:

```text
TURNOVER RECHECK: Magnetic Mask
TURNOVER RECHECK: Object Tracking
TURNOVER RECHECK: Stabilization
```

Optical Flow is still reported, but does not currently create a visible recheck marker because it has been less disruptive in real-world tests and would add too much visual noise.

Conform Prep is the exception: it also creates visible `TURNOVER RECHECK: Optical Flow` markers. Conform Prep output is usually handed to another application or an online conform workflow, so Optical Flow / Optical Flow FRC should be easy to spot even if Final Cut Pro itself preserves the setting.

Placement rule:

- Prefer near the head of the owning clip, starting one frame after the head.
- If that position collides with an existing top-level marker/keyword/rating, step forward frame by frame.
- If the head area is full, fall back to the tail area.
- Avoid the clip midpoint because Auto Marker uses the midpoint as the intentional capture/shot marker.
- Keep the detailed XML owner and reason in the report for debugging.

This marker layer is intentionally a user-facing recheck aid, not a reconstruction strategy. It marks clips that need human review after import; it does not guarantee that Final Cut Pro preserved or rebuilt the analysis state.

## Magnetic Mask Limitations

Magnetic Mask may appear in exported FCPXML as only:

```text
<filter-video ref="..." name="Magnetic Mask"/>
```

When this happens, the XML contains the effect shell but not the mask analysis data. If Final Cut Pro does not preserve the mask after import, the script cannot reconstruct it because the required mask payload was never serialized in the XML.

Other projects may contain an `object-tracker` node with a `dataLocator` that points at a sidecar plist inside:

```text
Contents/Effects/ObjectTracking/*.plist
```

For these cases, the report should say whether the sidecar exists in the source bundle. If the output workflow exports a flat `.fcpxml` without the sidecar bundle, Final Cut Pro may warn about the locator or lose the analyzed state.

## Owner Label Heuristic

For each matched XML node, the report finds the nearest previous timeline owner tag:

```text
asset-clip
clip
sync-clip
ref-clip
video
title
```

The report then prints a human-readable owner label using `name`, or `ref` when `name` is missing.

Example report rows:

```text
recheck items: 11
- recheck Magnetic Mask: video M_0002C007_260410_161651_h1DJN - v1 (effect shell only; mask analysis is not serialized in FCPXML)
- recheck Object Tracking: sync-clip sc68_15_01_CAM B (locator r56; Contents/Effects/ObjectTracking/421CD6B1086B245E9A09F4B5BD738988.plist; sidecar present)
- recheck Stabilization: video F044C013_260429LF_CANON - v1 (stabilization settings in XML)
- recheck Optical Flow: clip sc07_01_03_CAM A (optical-flow-frc)
```

This is not a frame-accurate resolver. It is a fast warning/reporting layer.

## Title Font / Style Safety

When a script edits title text or adds markers, it should preserve title style definitions byte-for-byte unless the tool explicitly edits styling.

The current guard records a signature made from all:

```text
<text-style-def ...>...</text-style-def>
```

If the signature changes unexpectedly, the report should say:

```text
text style definitions: changed
```

Otherwise:

```text
text style definitions: preserved
```

If fonts still change in Final Cut Pro while this report says `preserved`, the likely cause is Final Cut Pro import/template/font resolution rather than the script rewriting the title style definitions.

## Project Identity Policy

For VFX tools that roundtrip back into Final Cut Pro:

- Preserve project `uid`.
- Rename only the project display name when needed, for example `🛠 Project Name`, `📝 Project Name`, or `🔁 Project Name`.
- Never regenerate the project `uid` by default.

Reason:

- A new `uid` can make Final Cut Pro treat the project as a different identity and may disturb analysis/effect state.
- A renamed display name helps prevent users from accidentally treating the imported copy as the original.

## Why Recheck Markers Are Limited

Adding to-do markers such as `RECHECK: Magnetic Mask` is useful, but it also modifies the timeline and can introduce new FCPXML ordering/DTD edge cases.

Preferred behavior:

- Report every detected risk.
- Add visible markers only for high-risk items users need to recheck inside Final Cut Pro.
- Do not add markers for lower-risk/report-only items unless testing shows users need them.
- For Conform Prep only, mark Optical Flow because it is a cross-application handoff concern rather than only a Final Cut Pro roundtrip concern.

## Data Burn-In Relevance

Data Burn-In will need to read many of the same timeline signals, but with stricter timing requirements.

This report pattern is useful for:

- Listing effect/analysis-dependent regions that may need human review.
- Showing warnings in the app UI before rendering burn-in output.
- Flagging clips where source timecode or visible-layer metadata may need the stronger Conform Prep resolver.

It is not enough for:

- Frame-accurate visible source timecode.
- Speed-ramp interpolation.
- Nested sync-clip retime composition.
- Resolving all visible layers per frame.

For Burn-In, use this as a warning/report layer only. The actual per-frame metadata should come from the future shared visible-frame resolver.
