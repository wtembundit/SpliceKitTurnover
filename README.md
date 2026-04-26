# SpliceKit Worker

This package is a small set of practical VFX tools for **Final Cut Pro**, built to run **through [SpliceKit](https://github.com/elliotttate/SpliceKit)**.

It is designed for real editorial work:

- create VFX markers from `VFX NAMING` titles
- build a VFX shot list with thumbnails and Excel
- place returned VFX renders back onto the timeline

The helper app, **SpliceKit Worker.app**, handles setup, permissions, Motion title installation, and the prompts that SpliceKit Lua cannot show by itself.

## Before You Start

You need:

- [SpliceKit](https://github.com/elliotttate/SpliceKit)
- Final Cut Pro
- this package folder kept together on disk

## What This Package Does

### VFX Shot List

Creates:

- `VFX Shot List - <Project Name>.xlsx`
- a `Thumbnails/` folder

The Excel sheet includes:

- Thumbnail
- VFX Number
- Note
- Timeline TC In
- Duration (Frames)
- Source Filename
- Source TC In
- Source TC Out
- Metadata
- Remark

### VFX Timeline

Takes VFX renders from a delivery folder and places them back onto the current timeline as VFX connected clips.

Supports:

- connected
- replace
- audition

If there is no earlier VFX version for a shot, `replace` and `audition` fall back to `connected`.

### VFX Auto Marker

Lets you choose one marker type from the worker:

- standard
- todo
- chapter

## Quick Setup

1. Install [SpliceKit](https://github.com/elliotttate/SpliceKit).
2. Keep this whole package in one folder.
3. Open [SpliceKit Worker.app](</Users/arm/Documents/Splicekit/workers/SpliceKit Worker.app>).
4. In the setup window, let it install:
   - Lua scripts into the SpliceKit menu folder
   - the `VFX Naming` Motion title
   - the macOS permissions it needs
5. If you want it always available, turn on `Start at login`.

After that, leave **SpliceKit Worker.app** running and use the Lua scripts from SpliceKit.

## Main Scripts

- `VFX Auto Naming.lua`
  Renumbers `VFX NAMING` titles automatically.

- `VFX Reset Naming.lua`
  Resets numbered `VFX NAMING` titles back to `XXXX`.

- `VFX Auto Marker.lua`
  Opens one prompt and asks which marker type you want.

- `VFX Shot List.lua`
  Exports the VFX shot list workflow.

- `VFX Timeline.lua`
  Imports VFX deliveries and places them back on the timeline.

## Recommended Order

For a normal VFX prep workflow:

1. Run `VFX Auto Naming.lua`
2. Run `VFX Auto Marker.lua`
3. Run `VFX Shot List.lua`

When VFX renders come back from post:

1. Leave `SpliceKit Worker.app` open
2. Run `VFX Timeline.lua`
3. Choose the delivery folder
4. Review the placed VFX clips in Final Cut Pro

## Package Structure

Keep these together:

- `lua/`
- `motion-templates/`
- `workers/`
- `tools/`

Optional, but useful if you want to rebuild the app:

- `app-src/`
- `assets/`

Important:

- do **not** move `SpliceKit Worker.app` out by itself
- the app looks for its sibling `lua/` and `motion-templates/` folders
- the package root can live anywhere on the Mac, as long as the internal structure stays the same

## Install On Another Mac

1. Copy the whole package to the other Mac.
2. Put it anywhere you like, for example `~/Documents/SpliceKitWorker/`.
3. Open `SpliceKit Worker.app`.
4. Use the setup window to install the scripts and Motion title.
5. Confirm the permissions.
6. Run the Lua scripts from SpliceKit.

## Motion Title

This package includes the `VFX Naming` Motion title source.

The worker installs it to:

- `~/Movies/Motion Templates.localized/Titles.localized/VFX/VFX Naming/`

## Worker Buttons

In the setup window you can:

- install all
- install Lua scripts only
- install the Motion title only
- request Screen Recording permission
- request Accessibility / Automation permission
- launch the patched Final Cut Pro used by SpliceKit
- enable or disable start at login

## Launching Final Cut Pro

The worker first tries to open the **patched Final Cut Pro** that SpliceKit expects:

- `~/Applications/SpliceKit/Final Cut Pro.app`

If that app is not present on a machine, it falls back to:

- `/Applications/Final Cut Pro.app`

## Uninstall

If you want to remove the installed setup from a machine, run:

- `tools/Uninstall SpliceKit Worker Setup.command`

This removes:

- copied SpliceKit menu scripts
- worker state files
- the login item
- the installed `VFX Naming` Motion title

It does **not** delete the source package folder itself.

## Rebuild The App

If you change the Swift worker app and want a fresh build:

1. Run `tools/Build SpliceKit Worker App.command`
2. Re-open `SpliceKit Worker.app`

You do **not** need to rebuild the app every time you add or change Lua scripts.

## Runtime Note

The Excel generator currently depends on the Codex desktop runtime on the machine, because it uses Node.js and `@oai/artifact-tool`.

In practice, the safest setup is:

1. install Codex desktop
2. install SpliceKit
3. copy this package
4. open `SpliceKit Worker.app`

## Local Paths In This Source Package

Useful files in this package:

- [SpliceKit Worker.app](</Users/arm/Documents/Splicekit/workers/SpliceKit Worker.app>)
- [main.swift](/Users/arm/Documents/Splicekit/app-src/VFXShotListWorker/main.swift)
- [VFX Auto Marker.lua](/Users/arm/Documents/Splicekit/lua/VFX%20Auto%20Marker.lua)
- [VFX Shot List.lua](/Users/arm/Documents/Splicekit/lua/VFX%20Shot%20List.lua)
- [VFX Timeline.lua](/Users/arm/Documents/Splicekit/lua/VFX%20Timeline.lua)
- [VFX Naming Motion Template](/Users/arm/Documents/Splicekit/motion-templates/Titles.localized/VFX/VFX%20Naming)
