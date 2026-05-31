# Turnover Tools Guide

This guide explains the main Turnover workflows for Final Cut Pro VFX turnover through the native SpliceKit plugin.

> Current status: Turnover is usable for the workflows we have tested, but it is still a work in progress. Some FCPXML edge cases still need refinement, especially complex retime/speed-ramp combinations, nested sync clips, titles connected across multiple clips, markers, transforms, and metadata in unusual timelines.

## 🎞 Conform Prep

Prepares a timeline for VFX conform by flattening `sync-clip` items into easier-to-read original source clips where possible.

For the deeper technical guide, see [Conform Prep Guide](./conform-prep.md).

Best for:

- Timelines with many `sync-clip` items that need to become source-backed clips.
- VFX turnovers where source filename, visible source timecode, titles, markers, transforms, and metadata should survive as much as possible.
- Cases where an editor applied retime to the sync clip, the original inner clip, or both.

What it does:

- Flattens simple sync clips into `clip` or `asset-clip` elements that reference the original source.
- Combines outer sync-clip speed with inner original-clip speed when the structure is supported.
- Attempts to preserve speed segments, speed transitions/ramps, reverse segments, blade speed, titles, markers, transforms, and metadata.
- Normalizes offsets and durations so Final Cut Pro can import the generated FCPXML with fewer edit-boundary warnings.
- Writes a report showing which clips were flattened and which clips were skipped.

Important notes:

- Not every FCPXML shape is guaranteed yet, especially multicam and retime patterns we have not tested.
- If a clip disappears or titles/markers drift after import, keep both the original XML and generated XML as a reproducible test case.

## 📝 VFX Auto Naming

Automatically numbers `VFX NAMING` titles.

Best for:

- Timelines with placeholders such as `ABC_SC99_XXXX`.
- Creating running shot numbers such as `0010`, `0020`, `0030`.
- Restarting numbering when the scene prefix changes.

What it does:

- Reads titles that use the bundled `VFX NAMING` Motion template.
- Finds names that end with the `XXXX` placeholder.
- Replaces only the placeholder with a running shot number.
- Imports an updated project back into Final Cut Pro.

Example:

```text
ABC_SC99_XXXX  ->  ABC_SC99_0010
ABC_SC99_XXXX  ->  ABC_SC99_0020
ABC_SC100_XXXX ->  ABC_SC100_0010
```

## 🔁 VFX Reset Naming

Resets numbered `VFX NAMING` titles back to the `XXXX` placeholder.

Best for:

- Renumbering a timeline from scratch.
- Undoing an earlier numbering pass.
- Resetting after editorial order changes.

What it does:

- Reads numbered titles such as `ABC_SC99_0010`.
- Changes only the shot-number portion back to `XXXX`.
- Leaves the prefix and scene name unchanged.

Example:

```text
ABC_SC99_0010 -> ABC_SC99_XXXX
ABC_SC99_0020 -> ABC_SC99_XXXX
```

## 🛠 VFX Auto Marker

Creates Final Cut Pro markers from `VFX NAMING` titles so downstream workflows can read shot positions.

Best for:

- Timelines where VFX naming is already approved.
- Creating marker references for VFX Shot List and VFX Pull EDL.
- Choosing the marker type that best matches the team's workflow.

Marker types:

- `Standard`: regular Final Cut Pro marker.
- `To Do`: follow-up marker.
- `Chapter`: chapter marker.

What it does:

- Lets the user choose marker type from the Turnover menu.
- Reads the VFX number from each naming title.
- Writes the VFX number into the marker name.
- Writes title notes/descriptions into the marker note.
- Places markers at the title positions so other Turnover workflows can use them.

## 📋 VFX Shot List

Builds an Excel shot list with thumbnails from the current timeline.

Best for:

- Sending a VFX shot list to a vendor, online editor, or post supervisor.
- Including thumbnails for each VFX shot.
- Collecting timeline timecode, source timecode, filename, metadata, and remarks in one workbook.

Output:

```text
Desktop/
  VFX Shot List - <Project Name>/
    VFX Shot List - <Project Name>.xlsx
    Thumbnails/
```

Main columns:

- Thumbnail
- VFX Number
- Note
- Timeline TC In
- Duration (Frames)
- Source Filename
- Source TC In
- Source TC Out
- Metadata
- Remark

Thumbnail capture behavior:

- Turnover captures the largest visible Final Cut Pro window through the native plugin.
- For the most reliable thumbnails, open the fullscreen viewer before running the tool.
- macOS Screen Recording permission must be granted for the patched Final Cut Pro/SpliceKit process.

Important notes:

- If Screen Recording permission is missing, thumbnails may be blank or captured from the wrong window.
- Timelines with heavy overlap should be checked after export to confirm the source ranges are correct.

## 🧾 VFX Pull EDL

Creates a source-pull EDL from VFX markers.

Best for:

- Sending source ranges to online/VFX.
- Adding handles to every pulled range.
- Pulling more than one overlapping layer under the same VFX shot.

Handle frames:

- The entered value is applied to both sides of each source range.
- Entering `8` adds 8 frames to the head and 8 frames to the tail.
- The value does not need to be even.

Layer naming:

- The primary source uses `PL01`.
- Additional overlapping sources use `EL01`, `EL02`, and so on.

Output:

```text
VFX Pull EDL - <Project Name>.edl
```

## 📦 VFX Timeline

Places returned VFX renders back into the Final Cut Pro timeline.

Best for:

- Conforming VFX delivery files back into an editorial timeline.
- Placing renders as connected clips, replacements, or auditions.
- Tracking delivery versions such as v1, v2, and v3.

Modes:

- `Connected`: places the render as a connected clip above the timeline.
- `Replace`: replaces an existing VFX item; if no item exists, it falls back to connected mode.
- `Audition`: adds the render as an audition version; if no item exists, it falls back to connected mode.

Output examples:

```text
📦 VFX Deliveries v1 - <Project Name>
📦 VFX Deliveries v2 - <Project Name>
```

Important notes:

- Render filenames should clearly match the VFX shot code.
- Timelines with complex title, marker, or clip overlap should be checked after import.
