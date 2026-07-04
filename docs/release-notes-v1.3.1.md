# Turnover v1.3.1 Release Notes

Turnover v1.3.1 is a focused reliability and usability update. Standalone and SpliceKit edition version numbers remain synchronized.

## Standalone UI

- Reordered tools to follow the intended workflow: Conform Prep, VFX Naming, Auto Marker, VFX Pull EDL, VFX Shot List, and VFX Timeline.
- Added concise input and preflight requirements to every tool's Settings panel.
- Added VFX Naming Motion template detection for VFX Naming and Auto Marker.
- Added one-click installation of the bundled VFX Naming Motion template.
- Added a restart reminder after template installation so Final Cut Pro refreshes its Titles browser.

## SpliceKit Edition

- Synchronized the Conform Prep, VFX Naming, and VFX Shot List fixes with the standalone edition.
- Version metadata remains synchronized across both editions.

## VFX Naming

- Made `XXXX` placeholder detection case-insensitive, including lowercase and mixed-case placeholders.

## Conform Prep

- Added automatic video-only output that removes timeline audio and converts source-backed timeline items to native video elements.
- Added stage-level XML checks, DTD diagnostics, and a safe rollback when optional title relocation would produce malformed XML.
- Preserved source asset metadata for downstream Shot List and EDL workflows.

## VFX Shot List

- Restored custom source metadata such as Q, lens, F-stop, and roll in standalone Shot List manifests and Excel output.
- Preserved per-source metadata separation for shots containing multiple visible source layers.
