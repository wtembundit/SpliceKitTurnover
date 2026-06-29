# Turnover v1.2.0 Release Notes

Turnover v1.2.0 focuses on repeatable native workflows, safer FCPXML handling,
and fixes validated against real Final Cut Pro projects.

## ✨ Highlights

- Added a double-click `Install Turnover.command` installer and a prebuilt
  release plugin, so users do not need Xcode Command Line Tools.
- Added automatic Node.js discovery for Homebrew, nvm, Volta, asdf, MacPorts,
  common system paths, and shell environments.
- Added centralized Lua VM reset around every Turnover Lua script to prevent
  memory exhaustion across consecutive projects.
- Added a single-run guard so repeated menu clicks cannot start overlapping
  Turnover jobs.

## 🎬 Conform Prep

- Improved sync-clip flattening across nested source timing, constant speed,
  blade speed, speed ramps, reverse segments, and source clips that already
  contain retiming.
- Preserved retime frame-sampling modes such as Frame Blending, Optical Flow,
  and Machine Learning when represented in FCPXML.
- Improved preservation of titles, meaningful markers, transforms, effects,
  roles, and metadata.
- Filters unnamed source markers conservatively while retaining editorial/VFX
  markers.
- Added DTD validation using the matching Final Cut Pro FCPXML DTD.
- Added `Verify Conform Prep` in the Turnover panel for before/after XML checks.
- Verified real-project fixtures with unchanged top-level edit geometry, title
  identity/position, meaningful marker identity, keywords, retime structures,
  transforms, effects, and resolved media references.

## 🛠 VFX Auto Marker

- Added marker type selection for Standard, To Do, and Chapter markers.
- Marker rename/note import is optional; downstream tools do not require renamed
  markers.
- Improved visible marker relabeling by using direct title ownership first and
  ancestor-resolved timeline position as fallback.
- Fixed relabeling for direct source clips with `conform-rate`, where marker
  local time and project timeline time are not 1:1.
- Reduced incorrect edits to marker representations hidden inside nested XML.

## 📋 VFX Shot List

- Moved seeking, fullscreen capture, image processing, and Excel generation into
  the native Turnover workflow.
- Added progress stages and automatic fullscreen exit.
- Added per-image autorelease cleanup and Lua VM lifecycle protection for
  consecutive projects.
- Improved source row resolution for stacked clips and retimed media.
- Improved workbook thumbnail sizing and field readability.
- Added `Generate VFX Shot List` in the Turnover panel to rebuild a workbook
  from existing thumbnails without capturing again.
- Thumbnail filenames now use the VFX number directly. A numeric suffix such as
  `_01` or `_02` is added only when a VFX number is genuinely duplicated.

## 🧾 VFX Pull EDL

- Rebuilt VFX row detection around VFX titles plus marker anchors.
- Preserves multiple real source layers under one VFX shot without expanding
  every timeline element into a separate shot.
- Applies the entered handle count independently to both the head and tail.
- Keeps VFX Shot List and VFX Pull EDL behavior under one documented resolver
  contract.

## 📦 Installation

1. Download and extract `Turnover-v1.2.0.zip` from the GitHub release.
2. Double-click `Install Turnover.command`.
3. Follow any Terminal prompt for Node.js if it is not already installed.
4. Restart the patched Final Cut Pro.
5. Open the `Turnover` menu.

The installer builds and installs the native plugin and bundled Motion title
template.

## ⚠️ Known Limitations

Turnover is still a work in progress and is not guaranteed for every possible
FCPXML structure. Keep original XML and the smallest reproducible failing case
when reporting an issue.

Known areas that may need further refinement:

- one-frame hold/freeze tails in unusual retime layouts
- complex nested retime combinations not represented by current fixtures
- title/marker preservation in uncommon connected-storyline structures
- multicam flattening, which remains outside the main Conform Prep target

The visible timeline resolver is documented for a future parity-first shared
module. v1.2.0 intentionally keeps proven tool implementations in place rather
than performing a risky cross-tool rewrite.
