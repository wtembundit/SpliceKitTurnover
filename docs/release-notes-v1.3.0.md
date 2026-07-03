# Turnover v1.3.0 Release Notes

Turnover v1.3.0 is the first synchronized release of the standalone macOS application and the native SpliceKit plugin. Both editions share the same FCPXML planners and use the same version number.

## Turnover Standalone

- Added a native macOS 14 application that runs independently of SpliceKit.
- Added drag and drop for `.fcpxml`, `.fcpxmld`, and projects dragged directly from Final Cut Pro.
- Added Conform Prep, Auto Marker, VFX Pull EDL, VFX Naming, VFX Timeline, and VFX Shot List.
- Added safe flat-FCPXML output without overwriting source files or bundles.
- Added direct import of generated results into Final Cut Pro or explicit Save dialogs.
- Added automatic cache maintenance and debug artifacts for troubleshooting.
- Added automatic and manual GitHub update checks.
- Added the Turnover package application icon.
- Bundled Node.js 24 LTS and the required spreadsheet packages so standalone users do not need to install Node.js or npm.
- The v1.3.0 standalone build supports Apple Silicon Macs on macOS 14 or later.

## VFX Shot List

- Added fast thumbnail extraction from a user-exported reference movie instead of live Final Cut Pro screen capture.
- User markers remain the authoritative thumbnail frame anchors.
- Naming titles provide the VFX number and description.
- Fixed half-frame movie seeking and duplicate captured frames.
- Fixed false multi-source rows caused by clips crossing the full naming-title duration; Shot List source resolution now evaluates the marker frame.
- Consolidated repeated instances of the same source filename while preserving the overall source range.
- Generates formatted Excel workbooks with thumbnail folders.

## Shared FCPXML Core

- Added standalone-safe FCPXML import preparation and event wrapping.
- Added pure-FCPXML Auto Marker and VFX Naming workflows.
- Improved visible source resolution for conform-rate media and nested structures.
- Improved VFX Pull EDL handling for secondary storylines, transitions, stacked clips, and title-driven VFX rows.
- Preserved VFX delivery keywords during VFX Timeline generation.
- Preserved multiline title text when projects are dragged directly from Final Cut Pro.
- Added support for one-frame hold segments in Conform Prep; these may appear as an additional flattened clip segment.

## SpliceKit Plugin

- Updated the plugin to the shared v1.3.0 planner core.
- Retained the existing in-Final-Cut-Pro viewer capture workflow and plugin-only verification/recovery tools.
- The plugin and standalone app remain separate distributions so each can use the workflow best suited to its host environment.

## Install

### Standalone

1. Download `Turnover-Standalone-v1.3.0.zip`.
2. Move `Turnover.app` to Applications.
3. Open Turnover. The required Node.js runtime is included.

### SpliceKit Plugin

1. Install [SpliceKit](https://github.com/elliotttate/SpliceKit/releases/latest).
2. Download `Turnover-SpliceKit-v1.3.0.zip`.
3. Double-click `Install Turnover.command`.
4. Restart Final Cut Pro.

## Known Limitations

Turnover is production-usable for tested workflows but cannot guarantee every FCPXML structure. Verify generated timelines before turnover, retain the original project, and report reduced reproducible files for unhandled nested retime, title, marker, metadata, or hold-frame cases.
