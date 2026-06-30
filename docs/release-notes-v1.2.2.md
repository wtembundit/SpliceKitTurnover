# Turnover v1.2.2 Release Notes

Turnover v1.2.2 is a focused Conform Prep regression fix.

## Conform Prep

- Fixed lane-less spine titles being moved into the preceding flattened clip when the title started exactly at the clip end boundary.
- Restored the original title ownership and spatial conform behavior for affected clips.
- Connection-point ownership now uses half-open timeline ranges: `[clip start, clip end)`.
- Removed frame tolerance from connection-point ownership checks. A title at `clip end` belongs to the following timeline position, not the preceding clip.
- Prevented the cleanup pass from nesting lane-less primary titles inside clips, which could make Final Cut Pro split the clip video around the title.
- Preserved the v1.2.1 behavior for connected titles whose lane and connection point genuinely belong inside the clip, including titles that continue across later clips.

## Validation

- The reported regression fixture now produces output structurally equivalent to the confirmed v1.2.0 result, excluding the intentionally random project UID.
- The earlier connected-title fixture remains valid because both titles have a lane and begin strictly inside their anchor clips.
- FCPXML DTD validation passes.

## Install

1. Install [SpliceKit](https://github.com/elliotttate/SpliceKit/releases/latest) first.
2. Download and extract `Turnover-v1.2.2.zip`.
3. Double-click `Install Turnover.command`.
4. Restart Final Cut Pro.

Turnover is a SpliceKit plugin and cannot run as a standalone application.
