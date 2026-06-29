# Turnover v1.2.1 Release Notes

Turnover v1.2.1 is a compatibility and onboarding update for the native SpliceKit plugin.

## Updates

- Added the installed version number and an automatic GitHub release check to the Turnover panel.
- Added a direct download-page button when a newer Turnover release is available.
- Replaced the Codex-only `@oai/artifact-tool` dependency with a private ExcelJS runtime installed automatically with Turnover.
- Fixed `VFX Shot List` on user machines that do not have a Codex runtime cache.
- Updated installation instructions to make the SpliceKit prerequisite explicit.
- Simplified the install flow to: install SpliceKit, download Turnover, double-click the installer, and restart Final Cut Pro.

## Conform Prep

- Fixed connected titles that disappeared during Final Cut Pro import after sync-clip flattening.
- Title ownership now follows the connection point rather than requiring the entire title duration to fit inside one primary clip.
- Titles can continue across later primary-storyline clips without being shortened or detached from their original anchor.

## Install

1. Install [SpliceKit](https://github.com/elliotttate/SpliceKit/releases/latest).
2. Download and extract the latest [Turnover release](https://github.com/wtembundit/SpliceKitTurnover/releases/latest).
3. Double-click `Install Turnover.command`.
4. Restart Final Cut Pro.

Turnover is a SpliceKit plugin and cannot run as a standalone application.

### VFX Shot List permission preflight

Before the first Shot List capture, open `Turnover > Open Turnover`, click `Request Screen Recording`, approve Final Cut Pro/SpliceKit in macOS System Settings, and restart Final Cut Pro. Confirm that the panel shows `Screen Recording: OK` before running `VFX Shot List`.

Do not wait for the permission prompt during the first capture run. Granting Screen Recording permission after the fullscreen/capture sequence has started can interrupt that run.

## Known Limitations

Turnover remains under active development. Keep the original project or FCPXML when testing complex nested retimes, unusual one-frame holds, connected editorial elements, or unsupported multicam structures.
