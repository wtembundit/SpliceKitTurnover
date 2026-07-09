# Turnover v1.3.2 Release Notes

Turnover v1.3.2 is a focused Conform Prep reliability update for both the standalone app and SpliceKit plugin edition.

## Conform Prep

- Improved sync-clip flattening coverage for real-world timelines with nested retime, repeated source clips, connected secondary storylines, and title bundles.
- Preserved secondary-storyline titles more reliably when they span flattened sync clips.
- Fixed additional cases where flattened clips imported into Final Cut Pro with missing media or wrong source ranges.
- Clarified the preflight policy: duplicate the timeline, detach audio, and delete audio before running Conform Prep when a clean video-only conform check is required.
- Stopped running automatic audio cleanup inside Conform Prep. This keeps the current flattening pass focused on visible picture timing and avoids audio structures masking sync-clip conversion issues.

## Future Plan

- Audio cleanup may return later as a dedicated, better-tested feature once the FCPXML audio model is understood well enough to preserve picture flattening reliability. It is intentionally not part of the current Conform Prep pass.

## Notes

- Multicam flattening remains out of scope.
- Complex FCPXML import warnings can still come from Final Cut Pro semantic validation even when DTD validation passes.
- For best debugging, test flattening on a duplicated timeline with audio removed first, then reintroduce titles/markers/other editorial structure only after the source timing is confirmed.
