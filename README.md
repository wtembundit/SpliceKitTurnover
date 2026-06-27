# Turnover

Native SpliceKit plugin for Final Cut Pro turnover workflows.

Turnover bundles the VFX tools that used to run through the separate SpliceKit Worker app into one native plugin menu. The Worker app is no longer required.

## Current Status

Turnover is usable for the current tested workflows, but it is still a work in progress. Some FCPXML edge cases are known to need more refinement, especially complex retime/speed-ramp combinations, nested sync clips, titles connected across multiple clips, markers, transforms, and metadata preservation in unusual timelines.

If a timeline fails or imports with missing/shifted elements, keep the original project/XML and report the smallest reproducible case so the generic rules can be improved.

**Conform Prep preflight:** duplicate the timeline and clear editorial titles/markers before validating source flattening whenever possible. Title/marker preservation is best-effort; leaving them in can create misleading import-side noise while debugging the actual clip flatten.

## Documentation

- [Turnover Tools Guide](docs/turnover-tools.md): detailed workflow descriptions and usage notes.
- [Conform Prep Guide](docs/conform-prep.md): detailed explanation of sync-clip flattening, retime math, speed ramps, titles, markers, transforms, metadata, and known limits.
- [VFX Row Resolver Contract](docs/vfx-row-resolver-contract.md): implementation note for keeping VFX tools aligned.
- [Visible Timeline Resolver Future Plan](docs/visible-timeline-resolver-future.md): parity-first plan for sharing visible marker logic safely.
- [Release Notes v1.2.0](docs/release-notes-v1.2.0.md): current improvements, installation, and known limitations.

## Tools

- `Conform Prep`: flatten and prepare timelines for VFX conform.
- `VFX Auto Naming`: number `VFX NAMING` titles.
- `VFX Reset Naming`: reset numbered VFX titles back to placeholders.
- `VFX Auto Marker`: create standard, to-do, or chapter markers from VFX titles.
- `VFX Shot List`: capture thumbnails and build an Excel shot list.
- `VFX Pull EDL`: build a source pull EDL with per-side handle frames.
- `VFX Timeline`: place returned VFX renders back into the timeline.

## Requirements

- Final Cut Pro running with SpliceKit plugin support.
- macOS 13 or later.
- Xcode Command Line Tools are required only when building from source. The
  GitHub release bundle includes a prebuilt native plugin.
- Node.js. The installer detects common Homebrew, nvm, Volta, asdf, MacPorts, and shell paths automatically. If Node.js is missing and Homebrew is available, the installer can install it for you.
- Screen Recording permission for the patched Final Cut Pro process if you use `VFX Shot List` thumbnails.

## Install Node.js

Turnover uses Node.js for the FCPXML planners and Excel generation helpers.

Recommended install with Homebrew:

```zsh
brew install node
```

If Homebrew is not installed, install it first from [brew.sh](https://brew.sh), then run the command above.

Alternative install from the official Node.js package:

1. Download the macOS installer from [nodejs.org](https://nodejs.org).
2. Install the current LTS version.
3. Restart Final Cut Pro after installing Node.js.

The Turnover installer searches common Node.js locations automatically, including Homebrew, nvm, Volta, asdf, MacPorts, and shell startup paths.

If Node.js is installed in a custom location, run the installer with:

```zsh
TURNOVER_NODE_PATH=/path/to/node ./plugins/com.turnover.tools/Build\ And\ Install\ Turnover\ Tools\ Plugin.command
```

## Install

Double-click:

```text
Install Turnover.command
```

The installer opens Terminal, installs the bundled native plugin and `VFX Naming`
Motion title template, and copies the plugin to:

```text
~/Library/Application Support/SpliceKit/plugins/com.turnover.tools
```

Then restart the patched Final Cut Pro.

For a GitHub release download, extract `Turnover-v1.2.0.zip`, open the extracted
folder, and double-click `Install Turnover.command`. The release bundle includes
a prebuilt plugin, so Xcode is not required. macOS may ask for confirmation
because the installer was downloaded from the internet.

Advanced terminal install from this repository root:

```zsh
./plugins/com.turnover.tools/Build\ And\ Install\ Turnover\ Tools\ Plugin.command
```

After restart, use the `Turnover` menu in Final Cut Pro. `Open Turnover` opens the plugin panel, and the workflow commands are listed directly under the same menu.

## VFX Shot List Capture

`VFX Shot List` captures the largest visible Final Cut Pro viewer window. For the most reliable thumbnails, open the fullscreen preview window before running the tool.

The output is written to a desktop folder named:

```text
VFX Shot List - <Project Name>
```

It contains the Excel file and a `Thumbnails` folder. Temporary capture folders are cleaned after the workbook is created.

## VFX Pull EDL Handles

The handle value is applied to both sides of each source range.

Example: entering `8` adds 8 frames at the head and 8 frames at the tail.

## Repository Layout

- `plugins/com.turnover.tools/`: native SpliceKit plugin, manifest, and installer.
- `lua/`: Lua workflow controllers copied into the plugin at install time.
- `lua/scripts/`: Node.js planners and Excel generation helpers.
- `motion-templates/`: bundled Final Cut Pro Motion title template used by the naming workflows.
- `docs/`: implementation notes and conform-prep model documentation.

Build output such as `TurnoverToolsPlugin.dylib` is ignored by Git and should be regenerated locally with the install command.

## Notes

- The old SpliceKit Worker app, setup tools, and worker source have been removed.
- The GitHub repository has been renamed from `SpliceKitWorker` to `SpliceKitTurnover`.
