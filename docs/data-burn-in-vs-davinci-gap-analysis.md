# Data Burn-In: Current State vs DaVinci Resolve

## Turnover Team Assessment

This document should be treated as a **future plan**, not a current implementation spec. Data Burn-In is parked for now, but the analysis is valuable because it highlights a broader issue: tools that need frame-accurate visible source timecode should eventually reuse the stronger Conform Prep retime resolver instead of lighter helpers from VFX Pull EDL.

What we agree with:

- Data Burn-In should not rely on the current Pull EDL segment helper for per-frame source TC. It needs smooth2, reverse, nested timeMap, and hold-aware resolution.
- The Conform Prep retime/time-domain model is the best knowledge base we currently have for this class of problems.
- A future shared resolver would also benefit verification/debugging tools, and may help avoid repeating the same timecode mistakes across scripts.

What we are not doing yet:

- We are not merging Data Burn-In into Conform Prep right now.
- We are not extracting a shared retime module until Conform Prep has settled further.
- We are not treating Resolve feature parity as a near-term requirement.

Preferred direction when this work resumes:

1. First, define a small shared "visible frame resolver" contract: given timeline time, return visible source layers, source file, source TC, speed state, and metadata.
2. Then back it with the Conform Prep retime model or an extracted module from that model.
3. Only after the resolver is trusted, build UI presets and overlay rendering on top.

This keeps the idea alive without pulling a prototype feature into the current Conform Prep stabilization cycle.

## Current Limitations

Turnover's Data Burn-In is a prototype — it generates a manifest (JSON) and previews values in a UI slider, but **does not render an actual overlay video yet**. It also has accuracy issues with speed-ramped clips.

---

## DaVinci Resolve Data Burn-In vs Turnover

| Feature | DaVinci Resolve | Turnover (current) |
|---------|----------------|-------------------|
| **Timeline TC** | ✅ Frame-accurate at every frame | ✅ Via manifest |
| **Source TC** | ✅ Through retime, reverse, speed ramp | ❌ Breaks on smooth2 ramp, nested retime |
| **Source filename** | ✅ Updates per clip at timeline position | ✅ Updates per video segment |
| **Reel / Scene / Shot / Take** | ✅ Reads from clip metadata | ❌ Not available |
| **Camera metadata** | ✅ ISO, WB, aperture, fps | ❌ Not available |
| **Marker name + note** | ✅ Shows marker at that position | ❌ Not available |
| **Custom metadata key** | ✅ `{metadata:key}` for any field | ❌ Not available |
| **VFX number / note** | ❌ (not a Resolve feature) | ✅ Turnover-specific |
| **Audio role conditional** | ❌ | ✅ Prototype via manifest |
| **Font family** | ✅ Full selection | ❌ System font only |
| **Outline / Shadow** | ✅ | ❌ |
| **Background corner radius** | ✅ | ❌ |
| **Pixel / % coordinates** | ✅ | ❌ Padding only |
| **Drag reposition in preview** | ✅ | ❌ |
| **Multiple layers per field** | ✅ All visible sources | ❌ Only overlapping segment |
| **Opacity / fade in-out** | ✅ | ❌ |
| **Overlay rendering** | ✅ In-app, no external tool | ❌ Not implemented |
| **Logo image overlay** | ✅ | ❌ |
| **Export preset JSON** | ✅ | ✅ Prototype |

---

## Core Problem: Speed / Retime Accuracy

`build_data_burn_in_manifest.mjs` currently imports functions from `build_vfx_pull_edl.mjs`, which has far less capable retime handling than `build_conform_prep_fcpxml.mjs`. This is most visible in Data Burn-In because it needs per-frame source timecode, but the same architectural concern can matter for any future tool that needs precise visible source state through retimes.

### Why VFX Pull EDL is NOT affected

VFX Pull EDL only cares about `sourceIn` and `sourceOut` at the **head and tail** of each VFX shot range. These boundaries align with edit points / `<timept>` keyframes, where linear interpolation gives the same result as cubic Hermite (both pass through the same keyframe value). The intermediate ramp frames are irrelevant — an EDL event represents a contiguous source range, not per-frame values.

**VFX Pull EDL — current impact: usually low.**
Data Burn-In, by contrast, evaluates source TC at **every frame the user scrubs through**, including mid-ramp where linear and smooth2 diverge by multiple frames. That is where the accuracy gap bites.

### What burn-in manifest currently uses

```mjs
import {
  collectGlobalSourceSegments,  // <-- linear interpolation only
  collectGlobalVfxTitles,
  parseAssets, parseFormats, parseSequenceFrameDuration,
} from "./build_vfx_pull_edl.mjs";
```

`collectGlobalSourceSegments` uses `parseTimeMapBounds` + `interpolateTimeMapSource`, which:
- **Only reads** `time` and `value` from `<timept>` — ignores `interp`, `inTime`, `outTime`
- **Always linear interpolation** — smooth2 (cubic Hermite) ramps drift
- **No nested timeMap composition** — clips inside retimed sync-clips get wrong source TC
- **No reverse detection** — sourceIn may be > sourceOut with no flag

### What conform_prep already has (but isn't reused)

```mjs
// build_conform_prep_fcpxml.mjs — internal functions (not exported)
parseTimeMapXML()       // Reads interp, inTime, outTime fully
interpolateTimeMap()    // Handles both linear and cubic Hermite (smooth2)
composeTimeMaps()       // Composes outer + inner timeMap
applyReverseCalibration() // Adjusts epsilon for reverse clips
```

Conform Prep handles retime **correctly**, but these functions are internal — no exports, no shared module.

---

## Required Work for Complete Data Burn-In

### 1. Add metadata tokens to manifest

What Resolve has that we don't:
- `{reel}` — reel number from `<asset>` or `<media-rep>`
- `{scene}`, `{shot}`, `{take}`, `{angle}` — from marker notes or metadata
- `{marker}`, `{marker_note}` — marker at that timeline position
- `{metadata:<key>}` — generic custom metadata
- `cameraName`, `cameraIso`, `cameraAperture`, `cameraFps` — from FCPXML `<camera>` or `<log>`

### 2. Build per-frame resolver

Currently the manifest stores segment intervals, not per-frame resolution. Preview uses:
```
Source TC = linear interpolation between segment.sourceIn -> segment.sourceOut
```

On speed ramps, the source TC drifts mid-ramp.

**Solution:** Either emit per-frame arrays for clips with speed effects, or change the Swift-side resolver to interpolate through the timeMap instead of raw timeline position.

### 3. Overlay rendering

Per the design doc — render transparent ProRes 4444 via AVFoundation:
- Accept manifest + user preset
- Generate `CMSampleBuffer` per frame
- Draw text fields with Core Text / Core Graphics
- Encode with AVAssetWriter + ProRes 4444 codec

---

## Strategy: Reuse Conform Prep's Engine Directly

The retime engine already exists and is tested inside `build_conform_prep_fcpxml.mjs`. The cleanest path is **not** to extract a shared module first, but to make Data Burn-In use the same script directly.

### Option A: Inline burn-in manifest into conform_prep (recommended)

Add `--mode=builder:manifest` to `build_conform_prep_fcpxml.mjs`. When this mode is set, it skips FCPXML transformation and instead emits a `BurnInManifest` JSON using the same retime resolver it already has. No shared module, no refactor — just one more output format in an existing, tested script.

```mjs
// build_conform_prep_fcpxml.mjs already has:
//   - Full timeMap parser (smooth2, nested, reverse)
//   - Source segment collector through retime
//   - Frame-duration and format resolution

// Add:
if (args.mode === "manifest") {
  const manifest = buildBurnInManifest(xml);
  await fs.writeFile(args["output-manifest"], JSON.stringify(manifest, null, 2));
  return;
}
```

Pros:
- Zero code duplication — Data Burn-In gets conform_prep's retime engine implicitly
- The retime accuracy is tested by conform_prep's existing usage
- No shared module to maintain separately
- Easy to add new manifest tokens later (reel, scene, marker, camera metadata)

Cons:
- `build_conform_prep_fcpxml.mjs` gains a second responsibility (could be split later)
- The script is already ~3562 lines; adding ~150 lines for manifest output is proportional

### Option B: Extract shared `fcpxml_retime.mjs` module

Extract retime functions + segment collector into a shared module that both conform_prep and data-burn-in import. More architecturally pure, but higher risk of breaking conform_prep during extraction. Do this only if Option A proves insufficient.

### Priority

| Task | Rationale | Difficulty |
|------|-----------|------------|
| **Add `--mode=builder:manifest` to conform_prep** | Fixes source TC drift on speed clips for Data Burn-In. **No impact on Pull EDL or other tools.** | Low (~150 lines in existing script) |
| **Add metadata tokens** (reel, marker, scene) | Feature parity with Resolve | Low |
| **Overlay rendering** | Makes it actually usable | High |
| **UI drag reposition** | UX improvement | Medium |
| **Multiple visible layers** | Support stacked timelines | Medium |

### Implementation — Option A detail

1. Add `--mode` argument to `build_conform_prep_fcpxml.mjs`:
   - default: `conform` (current behavior)
   - `manifest`: build BurnInManifest JSON and exit

2. The manifest mode reuses existing parsing (full timeMap resolution, segment collection, VFX title collection) then serializes the output as JSON instead of transforming FCPXML.

3. The standalone app calls `build_conform_prep_fcpxml.mjs --mode=manifest` instead of `build_data_burn_in_manifest.mjs`.

4. `build_data_burn_in_manifest.mjs` either stays as-is (for the plugin edition, which doesn't use it directly) or becomes a thin re-export wrapper.

### Conform Prep retime functions to reuse (already internal)

```mjs
// In build_conform_prep_fcpxml.mjs — already correct, no changes needed:
parseTimeMapXML()        // Reads interp, inTime, outTime
interpolateTimeMap()     // smooth2 + linear
composeTimeMaps()        // Nested retime
applyReverseCalibration()
quantizeTimeMapPoints()
```

### Future Work

5. Implement ProRes 4444 overlay renderer with AVFoundation
6. Full field customizer (font, outline, timing, multi-layer)
