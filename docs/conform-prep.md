# Conform Prep Guide

`Conform Prep` converts timelines that contain `sync-clip` items into timelines that reference the original source clips more directly. The goal is to make VFX and online conform easier by preserving source filenames, visible source timecode, retime behavior, titles, markers, transforms, and metadata as closely as possible.

## 🎯 Goals

- Reduce nested `sync-clip` items into source-backed clips where possible.
- Preserve the first and last visible source frames from the original timeline.
- Preserve speed segments, speed ramps/transitions, reverse segments, and blade speed as much as possible.
- Preserve titles, markers, transforms, roles, and metadata attached to the affected clips.
- Generate FCPXML that Final Cut Pro can import without missing clips or avoidable edit-boundary warnings.

## 🧠 Speed Calculation Model

When this is done manually, the workflow is usually two-layered:

1. Break apart or flatten the sync clip so the original source clip inside becomes visible.
2. Multiply the outer sync-clip speed by the inner original-clip speed, then place the speed segments so the visible source timecode matches the original timeline.

Conform Prep follows the same principle:

```text
effective speed = inner source speed x outer sync clip speed
```

Example:

```text
inner clip = 200%
sync clip = 130%
flattened source clip = 260%
```

Reverse example:

```text
inner clip = 200%
sync clip = -115%
flattened source clip = -230%
```

## ⚡ Speed Segments And Speed Ramps

Final Cut Pro does not always store retime as one constant speed value. A clip may contain:

- constant speed
- several blade-speed segments
- speed transitions/ramps that gradually change speed
- reverse segments
- `timeMap` interpolation such as `smooth2`

Conform Prep reads the outer and inner `timeMap` structures and attempts to build a flattened `timeMap` that preserves:

- visible source TC in/out
- important speed-change points
- the real multiplied speed values
- a segment count close to the original, without inventing extra compensation blades when avoidable

## 🧩 What We Mean By Checkpoints

During development, checkpoints were inspected through Final Cut Pro's source timecode display to confirm whether key frames matched. In normal use, the user does not manually enter checkpoints.

The script derives reference points from the FCPXML:

- the outer sync-clip `timeMap`
- the inner original clip `timeMap`
- the source asset start
- the clip offset/start/duration
- the visible source time calculated after flattening

The important rule is that checkpoints must refer to the original source clip inside the sync clip, not the sync clip's own timecode. Sync-clip timecode can be unrelated to the real source timecode.

## 🏷 Titles, Markers, Transforms, And Metadata

Conform Prep tries to move connected elements by their real timeline position instead of relying only on the original parent clip. This matters because Final Cut Pro titles can:

- start a few frames before one clip but mostly cover the next clip
- be longer than the clip they are connected to
- be shorter than the main clip
- overlap with other titles so they appear hidden

The current rule set uses both timeline range and connection point. This area is improving, but unusual title and marker structures should still be checked after import.

## ✅ Cases That Work Better Now

- Simple sync-clip flattening
- Sync clips with only outer speed
- Inner original clips with speed plus additional outer sync-clip speed
- Constant retime where TC in/out must match exactly
- Multi-segment blade-speed examples from test timelines
- Reverse retime examples from test timelines
- Many real-world title, marker, transform, and metadata preservation cases

## ⚠️ Known Limitations

Check the imported timeline carefully when working with:

- Multicam clips. Multicam is not the main target because dedicated tools such as Multicam Flattener handle that class of problem better.
- Very complex retime patterns that have not been tested yet.
- Speed ramps that Final Cut Pro rounds differently in the UI than in FCPXML.
- Titles spanning across multiple clips or using unusual connection points.
- Markers created by older or unusual timeline structures.

Some cases may still drift by 1-2 frames or require a new generic rule.

## 🧪 How To Report A Failing Case

If a timeline imports incorrectly, keep:

- the original `.fcpxmld` or `.fcpxml`
- the generated output `.fcpxmld` or `.fcpxml`
- before/after screenshots
- the affected clip name
- expected source TC in/out, if known
- whether the speed is constant, blade speed, ramp, reverse, or nested retime

These details help improve the generic rules without hardcoding one specific shot.
