# Visible Timeline Resolver: Future Plan

Turnover should eventually share one resolver for marker visibility and
timeline identity across Auto Marker, VFX Shot List, VFX Pull EDL, and Conform
Prep. This is intentionally a future refactor, not part of the v1.2.0 runtime.

## Why It Is Deferred

The current tools have been tuned against different real-world Final Cut Pro
edge cases. Replacing all implementations at once could regress workflows that
already pass, especially nested clips, connected storylines, retimes, and
source clips with `conform-rate`.

## Shared Rules To Preserve

- The visible Final Cut Pro timeline is the source of truth.
- XML elements hidden inside sync clips, nested spines, or source media must not
  override the marker/title relationship visible to the editor.
- A marker directly owned by the same parent as its matching `VFX NAMING` title
  has priority during relabeling.
- Otherwise, compare ancestor-resolved absolute timeline positions.
- Marker local `start` can be in source-time space. Apply `conform-rate` and
  `timeMap` before comparing it with project-time positions.
- Keep meaningful user markers; filter unnamed source markers conservatively.

## Safe Migration Strategy

1. Freeze the current R1/R4 and other real-project fixtures as behavioral
   baselines.
2. Extract only marker visibility and identity into a shared resolver first.
3. Run the new resolver in shadow mode and compare it with current output.
4. Migrate one tool at a time after parity is proven.
5. Expand to title/source-range resolution only after marker parity is stable.

## Required Regression Cases

- Direct clips at the project frame rate.
- Direct clips with `conform-rate`.
- Retimed clips with `timeMap`, blade speed, reverse, and hold segments.
- Markers in connected and secondary storylines.
- Duplicate XML marker representations at the same visible position.
- Titles spanning adjacent clips or connected to a neighboring clip.
- Nested sync-clip/source markers that are not visible in Timeline Index.

The objective is shared behavior without rewriting proven workflows merely for
code reuse.
