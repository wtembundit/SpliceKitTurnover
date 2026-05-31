# Turnover v1.1.0 Release Notes

Native plugin release for SpliceKit Turnover.

## ✨ Highlights

- Migrated the toolset from the old SpliceKit Worker app to a native SpliceKit plugin named `Turnover`
- Added automatic Node.js detection during install and at plugin runtime
- Added Conform Prep as a native plugin workflow
- Added fullscreen-viewer capture support for VFX Shot List thumbnails
- Added detailed user documentation for every workflow

## 🧰 Included Tools

- 🎞 `Conform Prep`
- 📝 `VFX Auto Naming`
- 🔁 `VFX Reset Naming`
- 🛠 `VFX Auto Marker`
- 📋 `VFX Shot List`
- 🧾 `VFX Pull EDL`
- 📦 `VFX Timeline`

Read the full workflow guide:

- [Turnover Tools Guide](./turnover-tools.md)
- [Conform Prep Guide](./conform-prep.md)

## 🟢 Node.js Install Improvements

The plugin now searches for Node.js from:

- `TURNOVER_NODE_PATH`
- the path detected during install
- Homebrew paths on Apple Silicon and Intel Macs
- MacPorts
- Volta
- asdf
- nvm
- shell startup files through `zsh`

If Node.js is missing and Homebrew is available, the installer offers to install Node.js automatically.

## ⚠️ Known Limitations

Turnover is usable for tested workflows, but still not guaranteed for every FCPXML shape. Known edge cases include:

- complex retime/speed-ramp combinations
- nested sync clips with unusual source timecode
- titles connected across multiple clips
- marker/transform/metadata preservation in unusual timelines
- multicam, which is intentionally not the main target for Conform Prep

Please keep original XML, output XML, and screenshots when reporting a failing case.
