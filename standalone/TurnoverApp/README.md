# Turnover Standalone

Turnover is a native macOS application for Final Cut Pro turnover workflows. It shares the same FCPXML planners as the Turnover SpliceKit plugin, but it runs independently and does not require SpliceKit.

## Requirements

- Apple Silicon Mac with macOS 14 or later.
- Final Cut Pro for importing generated FCPXML results.
- Node.js and required spreadsheet packages are bundled inside the application. No separate runtime installation is required.

## Install

1. Download `Turnover-Standalone-v1.3.0.zip` from the latest GitHub release.
2. Extract the archive.
3. Move `Turnover.app` to the Applications folder.
4. Open Turnover. If macOS blocks the first launch, Control-click the app, choose **Open**, then confirm.

Turnover is currently distributed with an ad-hoc signature and is not notarized.

## Input

- Drag a `.fcpxml` file or `.fcpxmld` bundle into the app.
- Drag a project directly from Final Cut Pro into Turnover.
- Use **Choose File** to select an FCPXML file or bundle.

The source is never overwritten. Bundle inputs are read from `Info.fcpxml`; generated XML is exported as a flat `.fcpxml` file.

## Tools

- **Conform Prep**: flatten supported sync clips and prepare timelines for online conform.
- **Auto Marker**: create Standard, To Do, or Chapter markers from VFX naming titles.
- **VFX Pull EDL**: create source pull EDL/TSV files with per-side handles.
- **VFX Naming**: auto-number VFX naming titles or reset them to `XXXX`.
- **VFX Timeline**: place returned VFX renders and add the `VFX Deliveries` keyword.
- **VFX Shot List**: extract marker-anchored thumbnails from a user-exported reference movie and generate an Excel workbook.
## VFX Shot List

VFX Shot List requires:

1. VFX naming titles in the timeline.
2. User marker anchors identifying the exact thumbnail frames.
3. A reference movie exported from the same timeline with matching start timecode.

Choose the reference movie in the VFX Shot List settings. Turnover extracts frames from the movie; it does not automate or screen-record Final Cut Pro.

## Cache And Updates

Debug XML, reports, and manifests are kept under:

```text
~/Library/Application Support/Turnover/Inbox/Debug
```

Old cache data is cleaned automatically and can also be removed with **Clear Cache**. Turnover checks GitHub Releases when it opens; use **Check for Updates** in the header to check manually.

## Known Limitations

- FCPXML can represent visually identical timelines through different nesting and timing structures. Keep the original timeline and verify generated results before turnover.
- Conform Prep works best on a duplicate timeline with audio detached and removed. Titles and markers should be cleared when validating flattening behavior.
- Very short one-frame hold transitions may be represented as an additional flattened clip segment.
- Complex or previously unseen nested retime structures may still require a reduced reproducible case.

## Build From Source

```zsh
./standalone/TurnoverApp/build_app.sh
open ./standalone/TurnoverApp/build/Turnover.app
```

The build copies the canonical planners from `lua/scripts`; standalone does not maintain a second FCPXML implementation.
