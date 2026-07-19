# Turnover

Final Cut Pro turnover workflows available as a standalone macOS app and a native SpliceKit plugin.

Both editions share the same FCPXML planning core. The standalone app does not require SpliceKit; the plugin edition requires [SpliceKit](https://github.com/elliotttate/SpliceKit).

## Choose An Edition

- **Turnover Standalone**: drag/drop FCPXML or a Final Cut Pro project into a compact native macOS app. VFX Shot List thumbnails are extracted from a reference movie.
- **Turnover for SpliceKit**: run tools from inside Final Cut Pro. VFX Shot List can drive and capture the Final Cut Pro viewer.

Download both editions from the same [Turnover release page](https://github.com/wtembundit/SpliceKitTurnover/releases/latest). Their version numbers are intentionally synchronized.

## Current Status

Turnover is usable for the current tested workflows, but it is still a work in progress. Some FCPXML edge cases are known to need more refinement, especially complex retime/speed-ramp combinations, nested sync clips, titles connected across multiple clips, markers, transforms, and metadata preservation in unusual timelines.

If a timeline fails or imports with missing/shifted elements, keep the original project/XML and report the smallest reproducible case so the generic rules can be improved.

**Conform Prep preflight:** work on a duplicate timeline. Detach and delete audio from that duplicate, then clear titles/markers before validating source flattening whenever possible. Audio, title, and marker structures can create misleading import-side noise while debugging the actual clip flatten. Keep the original timeline unchanged.

## Documentation

- [Turnover Tools Guide](docs/turnover-tools.md): detailed workflow descriptions and usage notes.
- [Data Burn-In Guide](docs/data-burn-in.md): standalone and SpliceKit Burn-In workflows, presets, export modes, implementation map, and release checklist.
- [Conform Prep Guide](docs/conform-prep.md): detailed explanation of sync-clip flattening, retime math, speed ramps, titles, markers, transforms, metadata, and known limits.
- [VFX Row Resolver Contract](docs/vfx-row-resolver-contract.md): implementation note for keeping VFX tools aligned.
- [Visible Timeline Resolver Future Plan](docs/visible-timeline-resolver-future.md): parity-first plan for sharing visible marker logic safely.
- [Standalone Guide](standalone/TurnoverApp/README.md): standalone installation, input methods, Shot List reference-movie workflow, cache, and limitations.
- [Release Notes v1.4.0](docs/release-notes-v1.4.0.md): Data Burn-In Customizer, transparent overlay export, Marker Export, and SpliceKit Burn-In integration.
- [Release Notes v1.3.2](docs/release-notes-v1.3.2.md): Conform Prep reliability and preflight policy update.
- [Release Notes v1.3.0](docs/release-notes-v1.3.0.md): standalone application and synchronized dual-edition release.
- [Release Notes v1.2.2](docs/release-notes-v1.2.2.md): current Conform Prep title-anchor and spatial-conform regression fix.
- [Release Notes v1.2.1](docs/release-notes-v1.2.1.md): update checker, portable Shot List runtime, and thumbnail layout improvements.
- [Release Notes v1.2.0](docs/release-notes-v1.2.0.md): previous workflow improvements and known limitations.

## Tools

- `Conform Prep`: flatten and prepare timelines for online conform.
- `Data Burn-In`: build customizable burn-ins, export transparent overlays, or export H.264/HEVC burned-in review movies.
- `VFX Auto Naming`: number `VFX NAMING` titles.
- `VFX Reset Naming`: reset numbered VFX titles back to placeholders.
- `VFX Auto Marker`: create standard, to-do, or chapter markers from VFX titles.
- `VFX Shot List`: capture thumbnails and build an Excel shot list.
- `VFX Pull EDL`: build a source pull EDL with per-side handle frames.
- `VFX Timeline`: place returned VFX renders back into the timeline.
- `Marker Export`: export Final Cut Pro markers as EDL, CSV, or TXT.

## SpliceKit Plugin Requirements

- [SpliceKit](https://github.com/elliotttate/SpliceKit) installed and working with Final Cut Pro.
- macOS 13 or later.
- Xcode Command Line Tools are required only when building from source. The
  GitHub release bundle includes a prebuilt native plugin.
- Node.js. The installer detects common Homebrew, nvm, Volta, asdf, MacPorts, and shell paths automatically. If Node.js is missing and Homebrew is available, the installer can install it for you.
- Screen Recording permission for the patched Final Cut Pro process if you use `VFX Shot List` thumbnails.

The release plugin also bundles `Turnover.app` for Data Burn-In headless export, so **Burn-In Transparent** and **Burn-In Customize** use the matching app/parser version that shipped with the plugin. Node.js is still used by other SpliceKit planner/export tools.

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

## Install The SpliceKit Plugin

1. Install SpliceKit from the official [SpliceKit releases page](https://github.com/elliotttate/SpliceKit/releases/latest) and confirm its menu appears in Final Cut Pro.
2. Download and extract the latest [Turnover release](https://github.com/wtembundit/SpliceKitTurnover/releases/latest).
3. Double-click:

```text
Install Turnover.command
```

4. Let the installer configure Turnover's Node.js dependencies automatically.
5. Restart Final Cut Pro and open the `Turnover` menu.

The installer opens Terminal, installs the bundled native plugin, the matching `Turnover.app` used by Burn-In headless export, its private spreadsheet runtime, and the `VFX Naming` Motion title template. The plugin is copied to:

```text
~/Library/Application Support/SpliceKit/plugins/com.turnover.tools
```

The release bundle includes a prebuilt plugin, so Xcode is not required. macOS may ask for confirmation because the installer was downloaded from the internet.

Advanced terminal install from this repository root:

```zsh
./plugins/com.turnover.tools/Build\ And\ Install\ Turnover\ Tools\ Plugin.command
```

After restart, use the `Turnover` menu in Final Cut Pro. `Open Turnover` opens the plugin panel, and the workflow commands are listed directly under the same menu.

## VFX Shot List Capture

`VFX Shot List` captures the largest visible Final Cut Pro viewer window. For the most reliable thumbnails, open the fullscreen preview window before running the tool.

### Screen Recording Preflight

Grant Screen Recording permission before the first capture:

1. In Final Cut Pro, choose `Turnover > Open Turnover`.
2. Click `Request Screen Recording`.
3. Approve Final Cut Pro/SpliceKit in macOS System Settings when prompted.
4. Quit and reopen Final Cut Pro.
5. Open the Turnover panel again and confirm `Screen Recording: OK` before running `VFX Shot List`.

Turnover may display the macOS permission request when `VFX Shot List` is run for the first time, but granting permission after capture has already started can interrupt that run. Request permission in advance and restart Final Cut Pro instead.

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
