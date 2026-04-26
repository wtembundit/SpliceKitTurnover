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

### 1. `📝 VFX Auto Naming.lua`

Use this when you want to turn placeholder `VFX NAMING` titles into real shot numbers automatically.

What it does:

- finds `VFX NAMING` titles in the current timeline
- looks for titles that end in a placeholder like `XXXX`
- replaces that placeholder with running shot numbers such as `0010`, `0020`, `0030`
- writes the updated naming back into Final Cut Pro

What you will see after it runs:

- the imported updated project is prefixed with `📝`

Example:

- if your title is `ABC_SC99_XXXX`
- the script will turn it into:
  - `ABC_SC99_0010`
  - `ABC_SC99_0020`
  - `ABC_SC99_0030`

If the scene prefix changes, the numbering starts again for that new scene.

Example:

- `ABC_SC99_0010`
- `ABC_SC99_0020`
- `ABC_SC100_0010`
- `ABC_SC100_0020`

### 2. `🔁 VFX Reset Naming.lua`

Use this when you want to clear the numbering and go back to placeholders.

What it does:

- finds numbered `VFX NAMING` titles such as `ABC_SC99_0010`
- resets only the shot-number part back to `XXXX`
- helps when you want to rebuild the sequence naming from scratch

What you will see after it runs:

- the imported reset project is prefixed with `🔁`

Example:

- `ABC_SC99_0010` becomes `ABC_SC99_XXXX`
- `ABC_SC99_0020` becomes `ABC_SC99_XXXX`

### 3. `🛠 VFX Auto Marker.lua`

Use this after naming is ready and you want markers generated from the `VFX NAMING` titles.

What it does:

- opens one prompt from the worker
- lets you choose `standard`, `todo`, or `chapter`
- runs the matching marker workflow automatically
- copies the VFX number into the marker name
- copies the shot description into the marker note
- creates the marker positions that `VFX Shot List.lua` later uses to capture thumbnails and build the shot list

In practice, this is the step that turns the title text into usable marker data for the shot-list workflow.

What you will see after it runs:

- the imported marker-updated project is prefixed with `🛠`

### 4. `📋 VFX Shot List.lua`

Use this when you want the final VFX shot list package.

What it does:

- reads the VFX markers from the current project
- captures thumbnails
- builds the Excel shot list

Final result:

- `VFX Shot List - <Project Name>.xlsx`
- `Thumbnails/`

What you will see after it runs:

- a desktop folder named `VFX Shot List - <Project Name>/`
- inside it: the Excel file and the thumbnail folder

### 5. `📦 VFX Timeline.lua`

Use this when VFX renders come back from post and you want to place them onto the timeline.

What it does:

- asks for the delivery folder
- matches returned renders to the VFX shots
- places them back as VFX connected clips
- supports `connected`, `replace`, and `audition`

What you will see after it runs:

- a helper project imported with a name like `📦 VFX Deliveries v1 - <Project Name>`
- later runs continue as `v2`, `v3`, and so on

## Recommended Order

Typical order in this package:

1. `VFX Auto Naming.lua`
2. `VFX Reset Naming.lua`
3. `VFX Auto Marker.lua`
4. `VFX Shot List.lua`
5. `VFX Timeline.lua`

How that normally works in practice:

1. Run `VFX Auto Naming.lua` when you want to number the shots
2. Run `VFX Reset Naming.lua` only if you want to clear the numbering and start over
3. Run `VFX Auto Marker.lua` when the naming is ready
4. Run `VFX Shot List.lua` when you want thumbnails and Excel
5. Run `VFX Timeline.lua` later, when VFX renders come back from post

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

It does **not** remove:

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
