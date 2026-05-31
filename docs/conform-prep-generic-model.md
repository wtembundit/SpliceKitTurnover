# Conform Prep Generic Model

This note captures the current working model for nested-retime `sync-clip` flattening in `Conform Prep`.

## Proven Scope

The current model has been validated against these `clip-inside-sync` examples:

- `A081C028_250215TP.mov`
- `E007C029_2203130N_CANON.mov`
- `A113C002_250301CA.mov`

It is **not** yet validated for:

- `asset-clip-inside-sync`
- multicam
- arbitrary nested compounds

`SC_22_1_C16_01_A_HS` remains intentionally skipped for now.

## Core Principle

Treat nested retime flattening as a **two-layer rebuild**, not a one-shot direct rewrite.

### Layer 1: Original Clip Base

1. Find the original clip inside the `sync-clip`.
2. Preserve the original clip's own source domain:
   - `start`
   - `duration`
   - `timeMap`
   - source filename / ref
3. Use the original clip as the source-truth for visible source TC.

### Layer 2: Sync Wrapper Timing

1. Read the outer `sync-clip` retime.
2. Preserve its speed-segment topology:
   - number of segments
   - blade/speed points
   - `smooth2`
   - `inTime/outTime`
3. Compose the outer timing layer onto the original clip's source mapping.

## Important Rules

### 1. Checkpoints Are Validation, Not The Solver

Visible source TC checkpoints are for verification only:

- first visible frame
- blade checkpoints
- last visible frame

We should not build the whole `timeMap` by forcing checkpoints directly, because that tends to:

- collapse ramps into constant speed
- distort segment rates
- create wrong blade timing

### 2. Preserve Speed Segments And Ramps

For variable speed clips, correctness means preserving:

- segment rates
- segment boundaries
- transition/ramp handles

`smooth2 + inTime/outTime` must be treated as part of the retime shape, not as decorative metadata.

### 3. Do Not Arbitrarily Move Clip Start

Directly changing `clip.start` often causes:

- black clips
- `0s` durations
- invalid media edits

Use source mapping/value calibration before changing structural timing anchors.

### 4. Metadata Must Survive The Timing Rewrite

Flattening is only acceptable if these survive:

- transform
- effects / filters
- titles
- markers / keywords
- metadata

Timing correctness comes first, but user-visible editorial state must be preserved.

## Current Working Strategy

For `clip-inside-sync` nested retimes:

1. Keep the flattened node as `clip + video ref`.
2. Preserve the outer wrapper's ramp topology as much as possible.
3. Compose inner and outer timing into a single `timeMap`.
4. Use source TC anchors for first/last visible frames.
5. Apply small per-case calibrations only after the shape is correct.

## Practical Outcome

This is currently strong enough for example-driven refinement:

- A081 validates forward ramp behavior
- E007 validates different segment rates on the same inner 200% base
- A113 validates reverse + multi-blade behavior

Once those stay stable together, we can extract a more generic solver with higher confidence.
