import fs from "node:fs/promises";
import path from "node:path";
import os from "node:os";
import { fileURLToPath } from "node:url";

const CONFIG = {
  markerPrefixPattern: /^[A-Z0-9_]+_\d{4}$/,
  recordStartTC: "01:00:00:00",
  defaultFrameDuration: 1 / 24,
};

function printUsage() {
  console.log(`Usage:
  node lua/scripts/build_vfx_pull_edl.mjs \\
    --source-xml <path> \\
    --config <path> \\
    --output-dir <path> \\
    --report <path>
`);
}

function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--source-xml") args.sourceXml = path.resolve(argv[++i]);
    else if (arg === "--config") args.config = path.resolve(argv[++i]);
    else if (arg === "--output-dir") args.outputDir = path.resolve(argv[++i]);
    else if (arg === "--report") args.report = path.resolve(argv[++i]);
    else if (arg === "--help" || arg === "-h") {
      printUsage();
      process.exit(0);
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }
  if (!args.sourceXml || !args.config || !args.outputDir || !args.report) {
    printUsage();
    throw new Error("Missing required arguments.");
  }
  return args;
}

function trim(value) {
  return String(value ?? "").trim();
}

function parseFraction(str) {
  if (!str) return null;
  const frac = /^([-\d.]+)\/([-\d.]+)s$/.exec(str);
  if (frac) {
    const num = Number(frac[1]);
    const den = Number(frac[2]);
    if (Number.isFinite(num) && Number.isFinite(den) && den !== 0) return num / den;
  }
  const seconds = /^([-\d.]+)s$/.exec(str);
  if (seconds) return Number(seconds[1]);
  return null;
}

function parseAttrs(attrStr = "") {
  const attrs = {};
  const regex = /([\w:_-]+)\s*=\s*"([^"]*)"/g;
  let match;
  while ((match = regex.exec(attrStr))) attrs[match[1]] = match[2];
  return attrs;
}

function parseKeyValueTSV(text) {
  const out = {};
  for (const line of text.split(/\r?\n/)) {
    if (!line.trim()) continue;
    const [key, value = ""] = line.split("\t");
    out[key] = value;
  }
  return out;
}

function decodeUriComponentSafe(value) {
  try {
    return decodeURIComponent(value);
  } catch {
    return value;
  }
}

function sourcePathFromSrc(src) {
  let value = trim(src);
  if (!value) return "";
  value = value
    .replace(/^file:\/\/localhost/, "")
    .replace(/^file:\/\//, "")
    .replace(/^file:/, "")
    .replace(/\?.*$/, "");
  return decodeUriComponentSafe(value);
}

function basenameFromSrc(src) {
  const sourcePath = sourcePathFromSrc(src);
  return sourcePath ? path.basename(sourcePath) : "";
}

function basenameWithoutExtension(name) {
  const parsed = path.parse(trim(name));
  return parsed.name || trim(name);
}

function decodeXML(value = "") {
  return String(value)
    .replace(/&quot;/g, "\"")
    .replace(/&apos;/g, "'")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&amp;/g, "&");
}

function stripXmlTags(value = "") {
  return String(value).replace(/<[^>]+>/g, "");
}

function splitNonEmptyLines(value = "") {
  return String(value)
    .replace(/\r/g, "\n")
    .split(/\n+/)
    .map((line) => trim(line))
    .filter(Boolean);
}

function extractTitleText(body = "") {
  const parts = [];
  for (const match of body.matchAll(/<text-style\b[^>]*>(.*?)<\/text-style>/gs)) {
    const text = trim(decodeXML(stripXmlTags(match[1])));
    if (text) parts.push(text);
  }
  if (parts.length > 0) return parts.join("\n");
  const text = trim(decodeXML(stripXmlTags(body)));
  return text;
}

function titleNameWithoutBasicSuffix(name = "") {
  return trim(String(name).replace(/\s+-\s+Basic Title$/i, ""));
}

function deriveVfxTitleInfo(titleName = "", titleText = "") {
  const cleanName = titleNameWithoutBasicSuffix(trim(titleName));
  const namingMatch = cleanName.match(/^(.*?)\s+-\s+VFX NAMING$/i);
  if (namingMatch) {
    const lines = splitNonEmptyLines(titleText);
    return { vfxNumber: trim(namingMatch[1]), note: trim(lines[1] || lines[0] || "") };
  }

  const lines = splitNonEmptyLines(titleText);
  if (lines.length > 0 && CONFIG.markerPrefixPattern.test(lines[0])) {
    return { vfxNumber: lines[0], note: trim(lines.slice(1).join(" / ")) };
  }

  if (CONFIG.markerPrefixPattern.test(cleanName)) return { vfxNumber: cleanName, note: "" };
  return { vfxNumber: "", note: "" };
}

function isVfxTitle(titleName = "", titleText = "") {
  const info = deriveVfxTitleInfo(titleName, titleText);
  return CONFIG.markerPrefixPattern.test(info.vfxNumber);
}

function parseFormats(xml) {
  const formats = {};
  const remember = (attrs) => {
    const id = trim(attrs.id);
    if (!id) return;
    formats[id] = { id, frameDuration: parseFraction(attrs.frameDuration) };
  };
  for (const match of xml.matchAll(/<format\s+([^>]*?)\/>/gs)) remember(parseAttrs(match[1]));
  for (const match of xml.matchAll(/<format\s+([^>]*?)>.*?<\/format>/gs)) remember(parseAttrs(match[1]));
  return formats;
}

function parseAssets(xml, formatMap) {
  const assets = {};
  const firstMediaRepSrc = (body = "") => {
    const original = /<media-rep[^>]*kind="original-media"[^>]*src="([^"]+)"/s.exec(body);
    if (original) return original[1];
    const any = /<media-rep[^>]*src="([^"]+)"/s.exec(body);
    return any?.[1] || "";
  };
  const remember = (attrs, body = "") => {
    const id = trim(attrs.id);
    if (!id) return;
    const src = trim(firstMediaRepSrc(body) || attrs.src || "");
    const formatInfo = formatMap[trim(attrs.format)] || {};
    assets[id] = {
      id,
      src,
      sourcePath: sourcePathFromSrc(src),
      filename: basenameFromSrc(src),
      name: trim(attrs.name),
      start: parseFraction(attrs.start) ?? 0,
      hasVideo: trim(attrs.hasVideo),
      frameDuration: formatInfo.frameDuration || CONFIG.defaultFrameDuration,
    };
  };
  for (const match of xml.matchAll(/<asset\s+([^>]*?)\/>/gs)) remember(parseAttrs(match[1]));
  for (const match of xml.matchAll(/<asset\s+([^>]*?)>(.*?)<\/asset>/gs)) remember(parseAttrs(match[1]), match[2]);
  return assets;
}

function parseSequenceFrameDuration(xml, formatMap) {
  const formatId = /<sequence\s+[^>]*format="([^"]+)"/s.exec(xml)?.[1];
  const frameDuration = formatMap[trim(formatId)]?.frameDuration;
  return frameDuration && frameDuration > 0 ? frameDuration : CONFIG.defaultFrameDuration;
}

function contextTimelineStart(parentCtx, attrs) {
  const parentTl = parentCtx?.timelineStart ?? 0;
  const myOffset = parseFraction(attrs.offset);
  if (myOffset == null) return parentTl;
  if (parentCtx?.tag === "spine" && trim(parentCtx?.attrs?.lane) && myOffset < (parentCtx?.start ?? 0)) {
    return parentTl + myOffset;
  }
  const parentStart = parentCtx?.start ?? 0;
  return parentTl + myOffset - parentStart;
}

function findFirstChildRef(blob = "") {
  return /<video[^>]*ref="([^"]+)"/s.exec(blob)?.[1]
    || /<audio[^>]*ref="([^"]+)"/s.exec(blob)?.[1]
    || /<asset-clip[^>]*ref="([^"]+)"/s.exec(blob)?.[1]
    || /<ref-clip[^>]*ref="([^"]+)"/s.exec(blob)?.[1]
    || "";
}

function resolveSourceInfo(node, assetMap, body = "") {
  let ref = trim(node?.attrs?.ref);
  if (!ref) ref = trim(findFirstChildRef(body));
  const asset = ref ? assetMap[ref] : null;
  const sourceFilename = asset?.filename || asset?.name || trim(node?.attrs?.name);
  let sourceTcSeconds = node?.start ?? 0;
  if (!node?.attrs?.start && asset?.start != null) sourceTcSeconds = asset.start;
  return {
    ref,
    asset,
    sourceFilename,
    sourcePath: trim(asset?.sourcePath || ""),
    sourceTcSeconds,
    sourceFrameDuration: asset?.frameDuration || CONFIG.defaultFrameDuration,
    sourceTcFormat: trim(node?.attrs?.tcFormat || node?.attrs?._effective_tcFormat || ""),
  };
}

function isRealMediaSource(source) {
  const asset = source?.asset;
  if (!asset) return false;
  if (trim(asset.hasVideo) !== "1") return false;
  return trim(source?.sourceFilename) !== "";
}

function isOriginalVideoSegment(segmentNode, source) {
  const tag = trim(segmentNode?.tag).toLowerCase();
  const attrs = segmentNode?.attrs || {};
  const role = trim(attrs._effective_role || attrs.role).toLowerCase();
  if (tag === "audio") return false;
  if (role && !role.startsWith("video")) return false;
  if (["sync-clip", "mc-clip", "audition", "spine", "gap"].includes(tag)) return false;
  return isRealMediaSource(source);
}

function hasNestedContainerChildren(body = "") {
  return /<(asset-clip|clip|ref-clip|sync-clip|mc-clip)[\s>]/.test(body);
}

function directMediaChildUsesNonVideoRole(body = "") {
  let depth = 0;
  const tagRegex = /<(\/?)([\w:_-]+)(.*?)(\/?)>/gs;
  let match;
  while ((match = tagRegex.exec(body))) {
    const [, closing, tagName, attrStr, selfClose] = match;
    if (closing !== "/") {
      if (depth === 0 && MEDIA_SEGMENT_LIKE.has(tagName)) {
        const role = trim(parseAttrs(attrStr).role).toLowerCase();
        if (role && !role.startsWith("video")) return true;
      }
      if (selfClose !== "/") depth += 1;
    } else if (depth > 0) {
      depth -= 1;
    }
  }
  return false;
}

const CLIP_LIKE = new Set(["audio", "video", "clip", "title", "mc-clip", "ref-clip", "sync-clip", "asset-clip", "audition", "gap", "spine"]);
const MEDIA_SEGMENT_LIKE = new Set(["audio", "video", "clip", "mc-clip", "ref-clip", "sync-clip", "asset-clip"]);

function parseTimeMapBounds(body = "") {
  const timeMapBody = /<timeMap[^>]*>(.*?)<\/timeMap>/s.exec(body)?.[1];
  if (!timeMapBody) return null;
  const points = [];
  for (const match of timeMapBody.matchAll(/<timept\s+([^>]*?)\/>/gs)) {
    const attrs = parseAttrs(match[1]);
    const timelineTime = parseFraction(attrs.time);
    const sourceTime = parseFraction(attrs.value);
    if (timelineTime != null && sourceTime != null) points.push({ timelineTime, sourceTime });
  }
  if (points.length < 2) return null;
  points.sort((a, b) => a.timelineTime - b.timelineTime);
  return { points };
}

function interpolateTimeMapSource(timeMap, timelineTime) {
  if (!timeMap?.points || timeMap.points.length < 2 || timelineTime == null) return null;
  const points = timeMap.points;
  const interpolate = (a, b, t) => {
    const span = (b.timelineTime || 0) - (a.timelineTime || 0);
    if (span === 0) return a.sourceTime || 0;
    const ratio = (t - (a.timelineTime || 0)) / span;
    return (a.sourceTime || 0) + (((b.sourceTime || 0) - (a.sourceTime || 0)) * ratio);
  };
  if (timelineTime <= (points[0].timelineTime || 0)) return interpolate(points[0], points[1], timelineTime);
  for (let i = 0; i < points.length - 1; i += 1) {
    const a = points[i];
    const b = points[i + 1];
    if (timelineTime >= (a.timelineTime || 0) && timelineTime <= (b.timelineTime || 0)) return interpolate(a, b, timelineTime);
  }
  return interpolate(points[points.length - 2], points[points.length - 1], timelineTime);
}

function canonicalSourceGroupKey(sourceKey, sourceFilename) {
  const filename = trim(sourceFilename);
  return (filename || trim(sourceKey)).toLowerCase();
}

function collectTitleRanges(node, body = "") {
  const titles = [];
  const stack = [];
  const tagRegex = /<(\/?)([\w:_-]+)(.*?)(\/?)>/gs;
  let match;
  while ((match = tagRegex.exec(body))) {
    const [, closing, tagName, attrStr, selfClose] = match;
    if (closing !== "/") {
      const attrs = parseAttrs(attrStr);
      const parent = stack.at(-1);
      const timelineStart = contextTimelineStart(parent || node, attrs);
      const child = {
        tag: tagName,
        attrs,
        timelineStart,
        start: parseFraction(attrs.start),
        duration: parseFraction(attrs.duration) || 0,
        openEnd: tagRegex.lastIndex,
      };
      if (child.start == null) child.start = parent?.start ?? node?.start ?? 0;
      if (selfClose !== "/") stack.push(child);
      else if (tagName === "title") {
        const titleName = trim(attrs.name);
        if (isVfxTitle(titleName, "")) {
          const { vfxNumber, note } = deriveVfxTitleInfo(titleName, "");
          titles.push({ name: titleName, vfxNumber, note, timelineStart, duration: child.duration, timelineEnd: timelineStart + child.duration });
        }
      }
    } else {
      const child = stack.pop();
      if (child?.tag === "title") {
        const titleName = trim(child.attrs?.name);
        const inner = body.slice(child.openEnd, match.index);
        const titleText = extractTitleText(inner);
        if (isVfxTitle(titleName, titleText)) {
          const { vfxNumber, note } = deriveVfxTitleInfo(titleName, titleText);
          titles.push({ name: titleName, vfxNumber, note, timelineStart: child.timelineStart || 0, duration: child.duration || 0, timelineEnd: (child.timelineStart || 0) + (child.duration || 0) });
        }
      }
    }
  }
  return titles;
}

function collectGlobalVfxTitles(xml) {
  const titles = [];
  const stack = [];
  const tagRegex = /<(\/?)([\w:_-]+)(.*?)(\/?)>/gs;
  let match;
  while ((match = tagRegex.exec(xml))) {
    const [, closing, tagName, attrStr, selfClose] = match;
    if (closing !== "/") {
      const attrs = parseAttrs(attrStr);
      const parent = stack.at(-1);
      const timelineStart = contextTimelineStart(parent, attrs);
      const child = {
        tag: tagName,
        attrs,
        timelineStart,
        start: parseFraction(attrs.start),
        duration: parseFraction(attrs.duration) || 0,
        openEnd: tagRegex.lastIndex,
      };
      if (child.start == null) child.start = parent?.start ?? 0;
      if (selfClose !== "/") stack.push(child);
      else if (tagName === "title") {
        const titleName = trim(attrs.name);
        if (isVfxTitle(titleName, "")) {
          const { vfxNumber, note } = deriveVfxTitleInfo(titleName, "");
          titles.push({ name: titleName, vfxNumber, note, timelineStart, duration: child.duration, timelineEnd: timelineStart + child.duration });
        }
      }
    } else {
      const child = stack.pop();
      if (child?.tag === "title") {
        const titleName = trim(child.attrs?.name);
        const inner = xml.slice(child.openEnd, match.index);
        const titleText = extractTitleText(inner);
        if (isVfxTitle(titleName, titleText)) {
          const { vfxNumber, note } = deriveVfxTitleInfo(titleName, titleText);
          titles.push({ name: titleName, vfxNumber, note, timelineStart: child.timelineStart || 0, duration: child.duration || 0, timelineEnd: (child.timelineStart || 0) + (child.duration || 0) });
        }
      }
    }
  }
  titles.sort((a, b) => {
    if ((a.timelineStart || 0) === (b.timelineStart || 0)) return (a.timelineEnd || 0) - (b.timelineEnd || 0);
    return (a.timelineStart || 0) - (b.timelineStart || 0);
  });
  return titles;
}

function buildSegmentRecord(segmentNode, segmentBody, assetMap) {
  const source = resolveSourceInfo(segmentNode, assetMap, segmentBody || "");
  const tag = trim(segmentNode?.tag).toLowerCase();
  const hasOwnRef = trim(segmentNode?.attrs?.ref) !== "";
  if (!isOriginalVideoSegment(segmentNode, source)) return null;
  if (["clip", "asset-clip", "ref-clip"].includes(tag) && !hasOwnRef && hasNestedContainerChildren(segmentBody || "")) return null;
  if (directMediaChildUsesNonVideoRole(segmentBody || "")) return null;

  const segmentTimelineStart = Number(segmentNode.timelineStart) || 0;
  const segmentDuration = Number(segmentNode.duration) || 0;
  const localSourceInTime = segmentNode.start ?? source.sourceTcSeconds ?? 0;
  const localSourceOutTime = localSourceInTime + segmentDuration;
  let sourceIn = source.sourceTcSeconds || 0;
  let sourceOut = sourceIn + segmentDuration;
  const timeMap = parseTimeMapBounds(segmentBody || "");
  if (timeMap) {
    sourceIn = interpolateTimeMapSource(timeMap, localSourceInTime) ?? sourceIn;
    sourceOut = interpolateTimeMapSource(timeMap, localSourceOutTime) ?? sourceOut;
  } else {
    sourceIn = source.sourceTcSeconds || 0;
    sourceOut = (source.sourceTcSeconds || 0) + segmentDuration;
  }
  return {
    sourceKey: trim(source.ref) || trim(source.sourceFilename),
    timelineStart: segmentTimelineStart,
    timelineEnd: segmentTimelineStart + segmentDuration,
    sourceFilename: source.sourceFilename || "",
    sourcePath: source.sourcePath || "",
    sourceInSeconds: sourceIn,
    sourceOutSeconds: sourceOut,
    sourceFrameDuration: source.sourceFrameDuration || CONFIG.defaultFrameDuration,
    sourceTcFormat: source.sourceTcFormat || "",
  };
}

function collectGlobalSourceSegments(xml, assetMap) {
  const segments = [];
  const stack = [];
  const tagRegex = /<(\/?)([\w:_-]+)(.*?)(\/?)>/gs;
  let match;
  while ((match = tagRegex.exec(xml))) {
    const [, closing, tagName, attrStr, selfClose] = match;
    if (closing !== "/") {
      const attrs = parseAttrs(attrStr);
      const parent = stack.at(-1);
      const timelineStart = contextTimelineStart(parent, attrs);
      const explicitRole = trim(attrs.role);
      const parentRole = trim(parent?.attrs?._effective_role || parent?.effectiveRole);
      const effectiveRole = explicitRole || parentRole;
      const explicitTcFormat = trim(attrs.tcFormat);
      const parentTcFormat = trim(parent?.attrs?._effective_tcFormat || parent?.effectiveTcFormat);
      const effectiveTcFormat = explicitTcFormat || parentTcFormat;
      attrs._effective_role = effectiveRole;
      attrs._effective_tcFormat = effectiveTcFormat;
      const node = {
        tag: tagName,
        attrs,
        effectiveRole,
        effectiveTcFormat,
        isPrimarySpine: tagName === "spine" && parent && ["sequence", "project"].includes(parent.tag),
        insideNestedMediaContainer: parent?.insideNestedMediaContainer || ["sync-clip", "mc-clip", "audition"].includes(tagName),
        timelineStart,
        start: parseFraction(attrs.start),
        duration: parseFraction(attrs.duration) || 0,
        openEnd: tagRegex.lastIndex,
      };
      if (node.start == null) node.start = parent?.start ?? 0;
      const includeHere = MEDIA_SEGMENT_LIKE.has(tagName) && parent?.tag === "spine" && !parent?.insideNestedMediaContainer;
      if (selfClose !== "/") stack.push(node);
      else if (includeHere) {
        const segment = buildSegmentRecord(node, "", assetMap);
        if (segment) segments.push(segment);
      }
    } else {
      const node = stack.pop();
      const parent = stack.at(-1);
      if (node && node.tag !== "title" && node.tag !== "marker" && node.tag !== "chapter-marker" && node.tag !== "keyword" && MEDIA_SEGMENT_LIKE.has(node.tag) && parent?.tag === "spine" && !parent?.insideNestedMediaContainer) {
        const body = xml.slice(node.openEnd, match.index);
        const segment = buildSegmentRecord(node, body, assetMap);
        if (segment) segments.push(segment);
      }
    }
  }
  return segments;
}

function mergeSourceDetails(...detailsList) {
  const merged = [];
  const seen = new Set();
  for (const details of detailsList) {
    for (const group of details?.groups || []) {
      const key = [
        canonicalSourceGroupKey(group.sourceKey, group.sourceFilename),
        (Number(group.firstInSeconds) || 0).toFixed(6),
        (Number(group.lastOutSeconds) || 0).toFixed(6),
      ].join("|");
      if (seen.has(key)) continue;
      seen.add(key);
      merged.push(group);
    }
  }
  merged.sort((a, b) => {
    const at = Number(a.firstTimelineStart) || 0;
    const bt = Number(b.firstTimelineStart) || 0;
    if (at === bt) return String(a.sourceFilename || "").localeCompare(String(b.sourceFilename || ""));
    return at - bt;
  });
  return { hasDisplayableSegments: merged.length > 0, groups: merged };
}

function removeForeignBoundarySlivers(details, preferredDetails, timelineFrameDuration) {
  if (!details?.hasDisplayableSegments
      || !preferredDetails?.hasDisplayableSegments
      || !preferredDetails?.usedContainerTimeMapFallback) return details;
  const preferredKeys = new Set((preferredDetails.groups || [])
    .map((group) => canonicalSourceGroupKey(group.sourceKey, group.sourceFilename))
    .filter(Boolean));
  if (preferredKeys.size === 0) return details;
  const frameDuration = Number(timelineFrameDuration) || CONFIG.defaultFrameDuration;
  const groups = (details.groups || []).filter((group) => {
    const key = canonicalSourceGroupKey(group.sourceKey, group.sourceFilename);
    if (preferredKeys.has(key)) return true;
    const duration = Math.abs((Number(group.lastOutSeconds) || 0) - (Number(group.firstInSeconds) || 0));
    return duration > (frameDuration * 1.01);
  });
  return { hasDisplayableSegments: groups.length > 0, groups };
}

function summarizeSegmentsForWindow(segments, visibleStart, visibleEnd) {
  const clipped = [];
  for (const segment of segments || []) {
    const segmentStart = Number(segment.timelineStart) || 0;
    const segmentEnd = Number(segment.timelineEnd) || segmentStart;
    const overlapStart = Math.max(segmentStart, visibleStart);
    const overlapEnd = Math.min(segmentEnd, visibleEnd);
    if (overlapEnd <= overlapStart) continue;

    const timelineSpan = Math.max(segmentEnd - segmentStart, 0);
    const sourceSpan = (Number(segment.sourceOutSeconds) || 0) - (Number(segment.sourceInSeconds) || 0);
    const ratioAt = (timelineTime) => (timelineSpan > 0 ? (timelineTime - segmentStart) / timelineSpan : 0);
    const sourceInSeconds = (Number(segment.sourceInSeconds) || 0) + (sourceSpan * ratioAt(overlapStart));
    const sourceOutSeconds = (Number(segment.sourceInSeconds) || 0) + (sourceSpan * ratioAt(overlapEnd));

    clipped.push({
      ...segment,
      timelineStart: overlapStart,
      timelineEnd: overlapEnd,
      sourceInSeconds,
      sourceOutSeconds,
    });
  }

  const sourceGroups = {};
  const sourceOrder = [];
  for (const segment of clipped) {
    const key = canonicalSourceGroupKey(segment.sourceKey, segment.sourceFilename);
    if (!key) continue;
    let group = sourceGroups[key];
    if (!group) {
      group = {
        sourceKey: segment.sourceKey,
        sourceFilename: trim(segment.sourceFilename),
        sourcePath: trim(segment.sourcePath),
        firstInSeconds: segment.sourceInSeconds || 0,
        lastOutSeconds: segment.sourceOutSeconds || 0,
        firstTimelineStart: segment.timelineStart || 0,
        sourceFrameDuration: segment.sourceFrameDuration || CONFIG.defaultFrameDuration,
        sourceTcFormat: segment.sourceTcFormat || "",
      };
      sourceGroups[key] = group;
      sourceOrder.push(key);
    } else {
      if ((segment.timelineStart || 0) < (group.firstTimelineStart || 0)) {
        group.firstTimelineStart = segment.timelineStart || 0;
        group.firstInSeconds = segment.sourceInSeconds ?? group.firstInSeconds;
        if (trim(segment.sourceFilename)) group.sourceFilename = trim(segment.sourceFilename);
        if (trim(segment.sourcePath)) group.sourcePath = trim(segment.sourcePath);
        if (trim(segment.sourceTcFormat)) group.sourceTcFormat = trim(segment.sourceTcFormat);
      }
      if ((segment.sourceInSeconds || 0) < (group.firstInSeconds || 0)) {
        group.firstInSeconds = segment.sourceInSeconds;
      }
      if ((segment.sourceOutSeconds || 0) > (group.lastOutSeconds || 0)) group.lastOutSeconds = segment.sourceOutSeconds;
    }
  }

  sourceOrder.sort((a, b) => {
    const ga = sourceGroups[a];
    const gb = sourceGroups[b];
    if ((ga?.firstTimelineStart || 0) === (gb?.firstTimelineStart || 0)) return String(ga?.sourceFilename || a).localeCompare(String(gb?.sourceFilename || b));
    return (ga?.firstTimelineStart || 0) - (gb?.firstTimelineStart || 0);
  });
  return { hasDisplayableSegments: sourceOrder.length > 0, groups: sourceOrder.map((key) => sourceGroups[key]).filter(Boolean) };
}

function markerMatchesTitle(markerAbsTime, markerValue, title) {
  if (!CONFIG.markerPrefixPattern.test(trim(markerValue))) return false;
  return trim(title?.vfxNumber) === trim(markerValue);
}

function chooseTitleForMarker(markerAbsTime, markerValue, localTitles, globalTitles) {
  const candidates = [];
  for (const title of localTitles || []) {
    if (markerMatchesTitle(markerAbsTime, markerValue, title)) candidates.push(title);
  }
  for (const title of globalTitles || []) {
    if (markerMatchesTitle(markerAbsTime, markerValue, title)) candidates.push(title);
  }
  if (candidates.length === 0) return null;
  candidates.sort((a, b) => {
    const amid = ((Number(a.timelineStart) || 0) + (Number(a.timelineEnd ?? a.timelineStart) || 0)) / 2;
    const bmid = ((Number(b.timelineStart) || 0) + (Number(b.timelineEnd ?? b.timelineStart) || 0)) / 2;
    const ad = Math.abs(markerAbsTime - amid);
    const bd = Math.abs(markerAbsTime - bmid);
    if (ad === bd) return (Number(a.duration) || 0) - (Number(b.duration) || 0);
    return ad - bd;
  });
  return candidates[0];
}

function dedupeRowsByTitle(rows) {
  const out = [];
  const byKey = new Map();
  for (const row of rows || []) {
    const titleStart = Number(row.titleStartSeconds) || 0;
    const key = [
      trim(row.vfxNumber),
      titleStart.toFixed(6),
      trim(row.layer),
      trim(row.sourceFilename).toLowerCase(),
      (Number(row.sourceInSeconds) || 0).toFixed(6),
      (Number(row.sourceOutSeconds) || 0).toFixed(6),
    ].join("|");
    const existingIndex = byKey.get(key);
    if (existingIndex == null) {
      byKey.set(key, out.length);
      out.push(row);
      continue;
    }
    const existing = out[existingIndex];
    const target = titleStart + ((Number(row.titleDurationSeconds) || 0) / 2);
    const currentDistance = Math.abs((Number(existing.markerAbsSeconds) || titleStart) - target);
    const candidateDistance = Math.abs((Number(row.markerAbsSeconds) || titleStart) - target);
    if (candidateDistance < currentDistance) out[existingIndex] = row;
  }
  out.sort((a, b) => {
    const at = Number(a.titleStartSeconds) || 0;
    const bt = Number(b.titleStartSeconds) || 0;
    if (at === bt) return String(a.vfxNumber).localeCompare(String(b.vfxNumber)) || String(a.layer).localeCompare(String(b.layer));
    return at - bt;
  });
  return out;
}

function collectBodyDetailsForRange(node, body = "", assetMap, visibleStartOverride = null, visibleEndOverride = null) {
  const segments = [];
  const stack = [];
  let usedContainerTimeMapFallback = false;
  const bodyVisibleStart = visibleStartOverride ?? node?.timelineStart ?? 0;
  const bodyVisibleEnd = visibleEndOverride ?? (bodyVisibleStart + (Number(node?.duration) || 0));
  const containerTimeMap = ["sync-clip", "clip", "asset-clip", "ref-clip"].includes(trim(node?.tag).toLowerCase())
    ? parseTimeMapBounds(body)
    : null;
  const addSegmentFromNode = (segmentNode, segmentBody = "") => {
    const source = resolveSourceInfo(segmentNode, assetMap, segmentBody);
    const tag = trim(segmentNode?.tag).toLowerCase();
    const hasOwnRef = trim(segmentNode?.attrs?.ref) !== "";
    if (!isOriginalVideoSegment(segmentNode, source)) return;
    if (["clip", "asset-clip", "ref-clip"].includes(tag) && !hasOwnRef && hasNestedContainerChildren(segmentBody)) return;
    if (directMediaChildUsesNonVideoRole(segmentBody)) return;
    const segmentTimelineStart = Number(segmentNode.timelineStart) || 0;
    const segmentTimelineEnd = segmentTimelineStart + (Number(segmentNode.duration) || 0);
    let overlapStart = Math.max(segmentTimelineStart, bodyVisibleStart);
    let overlapEnd = Math.min(segmentTimelineEnd, bodyVisibleEnd);
    let overlapInDelta = overlapStart - segmentTimelineStart;
    let overlapOutDelta = overlapEnd - segmentTimelineStart;

    // A retimed container maps its visible outer window into the nested
    // storyline's clock. Child offsets cannot be compared to outer timeline
    // coordinates directly (common with retimed sync clips).
    if (overlapEnd <= overlapStart && containerTimeMap && segmentNode !== node) {
      const outerStart = (Number(node?.start) || 0) + (bodyVisibleStart - (Number(node?.timelineStart) || 0));
      const outerEnd = (Number(node?.start) || 0) + (bodyVisibleEnd - (Number(node?.timelineStart) || 0));
      const mappedA = interpolateTimeMapSource(containerTimeMap, outerStart);
      const mappedB = interpolateTimeMapSource(containerTimeMap, outerEnd);
      if (mappedA != null && mappedB != null) {
        const nestedVisibleStart = Math.min(mappedA, mappedB);
        const nestedVisibleEnd = Math.max(mappedA, mappedB);
        const childOffset = parseFraction(segmentNode?.attrs?.offset) ?? segmentTimelineStart;
        const childEnd = childOffset + (Number(segmentNode.duration) || 0);
        const nestedOverlapStart = Math.max(childOffset, nestedVisibleStart);
        const nestedOverlapEnd = Math.min(childEnd, nestedVisibleEnd);
        if (nestedOverlapEnd > nestedOverlapStart) {
          usedContainerTimeMapFallback = true;
          overlapStart = bodyVisibleStart;
          overlapEnd = bodyVisibleEnd;
          overlapInDelta = nestedOverlapStart - childOffset;
          overlapOutDelta = nestedOverlapEnd - childOffset;
        }
      }
    }
    if (overlapEnd <= overlapStart) return;
    const localSourceInTime = (segmentNode.start ?? source.sourceTcSeconds ?? 0) + overlapInDelta;
    const localSourceOutTime = (segmentNode.start ?? source.sourceTcSeconds ?? 0) + overlapOutDelta;
    let sourceIn = source.sourceTcSeconds || 0;
    let sourceOut = sourceIn + (overlapEnd - overlapStart);
    const timeMap = parseTimeMapBounds(segmentBody);
    if (timeMap) {
      sourceIn = interpolateTimeMapSource(timeMap, localSourceInTime) ?? sourceIn;
      sourceOut = interpolateTimeMapSource(timeMap, localSourceOutTime) ?? sourceOut;
    } else {
      sourceIn = (source.sourceTcSeconds || 0) + overlapInDelta;
      sourceOut = (source.sourceTcSeconds || 0) + overlapOutDelta;
    }
    segments.push({
      sourceKey: trim(source.ref) || trim(source.sourceFilename),
      timelineStart: overlapStart,
      timelineEnd: overlapEnd,
      sourceFilename: source.sourceFilename || "",
      sourcePath: source.sourcePath || "",
      sourceInSeconds: sourceIn,
      sourceOutSeconds: sourceOut,
      sourceFrameDuration: source.sourceFrameDuration || CONFIG.defaultFrameDuration,
      sourceTcFormat: source.sourceTcFormat || "",
    });
  };
  if (MEDIA_SEGMENT_LIKE.has(node?.tag)) addSegmentFromNode(node, body);

  const tagRegex = /<(\/?)([\w:_-]+)(.*?)(\/?)>/gs;
  let match;
  while ((match = tagRegex.exec(body))) {
    const [, closing, tagName, attrStr, selfClose] = match;
    if (closing !== "/") {
      const attrs = parseAttrs(attrStr);
      const parent = stack.at(-1);
      const timelineStart = contextTimelineStart(parent || node, attrs);
      const explicitRole = trim(attrs.role);
      const parentRole = trim(parent?.attrs?._effective_role || parent?.effectiveRole);
      const effectiveRole = explicitRole || parentRole;
      const explicitTcFormat = trim(attrs.tcFormat);
      const parentTcFormat = trim(parent?.attrs?._effective_tcFormat || parent?.effectiveTcFormat);
      const effectiveTcFormat = explicitTcFormat || parentTcFormat;
      attrs._effective_role = effectiveRole;
      attrs._effective_tcFormat = effectiveTcFormat;
      const child = {
        tag: tagName,
        attrs,
        effectiveRole,
        effectiveTcFormat,
        timelineStart,
        start: parseFraction(attrs.start),
        duration: parseFraction(attrs.duration) || 0,
        openEnd: tagRegex.lastIndex,
      };
      if (child.start == null) child.start = parent?.start ?? node?.start ?? 0;
      if (selfClose !== "/") stack.push(child);
      else if (MEDIA_SEGMENT_LIKE.has(tagName)) addSegmentFromNode(child, "");
    } else {
      const child = stack.pop();
      if (child && MEDIA_SEGMENT_LIKE.has(child.tag)) addSegmentFromNode(child, body.slice(child.openEnd, match.index));
    }
  }

  const sourceGroups = {};
  const sourceOrder = [];
  for (const segment of segments) {
    const key = canonicalSourceGroupKey(segment.sourceKey, segment.sourceFilename);
    if (!key) continue;
    let group = sourceGroups[key];
    if (!group) {
      group = {
        sourceKey: segment.sourceKey,
        sourceFilename: trim(segment.sourceFilename),
        sourcePath: trim(segment.sourcePath),
        firstInSeconds: segment.sourceInSeconds || 0,
        lastOutSeconds: segment.sourceOutSeconds || 0,
        firstTimelineStart: segment.timelineStart || 0,
        sourceFrameDuration: segment.sourceFrameDuration || CONFIG.defaultFrameDuration,
        sourceTcFormat: segment.sourceTcFormat || "",
      };
      sourceGroups[key] = group;
      sourceOrder.push(key);
    } else {
      if ((segment.timelineStart || 0) < (group.firstTimelineStart || 0)) {
        group.firstTimelineStart = segment.timelineStart || 0;
        group.firstInSeconds = segment.sourceInSeconds ?? group.firstInSeconds;
        if (trim(segment.sourceFilename)) group.sourceFilename = trim(segment.sourceFilename);
        if (trim(segment.sourcePath)) group.sourcePath = trim(segment.sourcePath);
        if (trim(segment.sourceTcFormat)) group.sourceTcFormat = trim(segment.sourceTcFormat);
      }
      if ((segment.sourceOutSeconds || 0) > (group.lastOutSeconds || 0)) group.lastOutSeconds = segment.sourceOutSeconds;
    }
  }
  sourceOrder.sort((a, b) => {
    const ga = sourceGroups[a];
    const gb = sourceGroups[b];
    if ((ga?.firstTimelineStart || 0) === (gb?.firstTimelineStart || 0)) return String(ga?.sourceFilename || a).localeCompare(String(gb?.sourceFilename || b));
    return (ga?.firstTimelineStart || 0) - (gb?.firstTimelineStart || 0);
  });
  return {
    hasDisplayableSegments: sourceOrder.length > 0,
    groups: sourceOrder.map((key) => sourceGroups[key]).filter(Boolean),
    usedContainerTimeMapFallback,
  };
}

function collectPullRows(xml, assetMap, timelineFrameDuration, handleFrames, options = {}) {
  const rows = [];
  const pushRowsFromDetails = (targetRows, vfxNumber, note, details, rowMeta = {}) => {
    let layerIndex = 0;
    for (const group of details.groups || []) {
      layerIndex += 1;
      const layer = layerIndex === 1 ? "PL01" : `EL${String(layerIndex - 1).padStart(2, "0")}`;
      const frameDuration = Number(group.sourceFrameDuration) || timelineFrameDuration || CONFIG.defaultFrameDuration;
      const sourceInSeconds = Math.max((group.firstInSeconds || 0) - (handleFrames * frameDuration), 0);
      const sourceOutSecondsRaw = (group.lastOutSeconds || 0) + (handleFrames * frameDuration);
      const sourceDurationSeconds = Math.max(sourceOutSecondsRaw - sourceInSeconds, 0);
      let sourceDurationFrames = Math.floor((sourceDurationSeconds / frameDuration) + 0.5);
      if (sourceDurationFrames <= 0) sourceDurationFrames = 1;
      const sourceOutSeconds = sourceInSeconds + (sourceDurationFrames * frameDuration);
      targetRows.push({
        vfxNumber,
        note: trim(note),
        layer,
        sourceFilename: trim(group.sourceFilename),
        sourcePath: trim(group.sourcePath),
        reel: basenameWithoutExtension(trim(group.sourceFilename)),
        sourceInSeconds,
        sourceOutSeconds,
        sourceFrameDuration: frameDuration,
        sourceDurationFrames,
        handleFramesPerSide: handleFrames,
        totalHandleFrames: handleFrames,
        headHandleFrames: handleFrames,
        tailHandleFrames: handleFrames,
        sourceTcFormat: trim(group.sourceTcFormat),
        titleStartSeconds: rowMeta.titleStartSeconds,
        titleDurationSeconds: rowMeta.titleDurationSeconds,
        markerAbsSeconds: rowMeta.markerAbsSeconds,
      });
    }
  };

  const stack = [];
  const globalSegments = collectGlobalSourceSegments(xml, assetMap);
  const globalTitles = collectGlobalVfxTitles(xml);

  // Markers provide a stable temporal anchor for titles inside nested and
  // connected structures. The standalone app can generate these anchors in a
  // private XML copy, so users do not need markers in their working timeline.
  const tagRegex = /<(\/?)([\w:_-]+)(.*?)(\/?)>/gs;
  let match;
  while ((match = tagRegex.exec(xml))) {
    const [, closing, tagName, attrStr, selfClose] = match;
    if (closing !== "/") {
      const attrs = parseAttrs(attrStr);
      const parent = stack.at(-1);
      const timelineStart = contextTimelineStart(parent, attrs);
      const node = {
        tag: tagName,
        attrs,
        timelineStart,
        start: parseFraction(attrs.start) || 0,
        duration: parseFraction(attrs.duration) || 0,
        openEnd: tagRegex.lastIndex,
        pendingMarkers: [],
      };
      if (!attrs.start) node.start = parent?.start ?? 0;
      if ((tagName === "marker" || tagName === "chapter-marker") && parent && CLIP_LIKE.has(parent.tag)) {
        parent.pendingMarkers.push({ tagName, value: attrs.value || "", note: attrs.note || "", relStart: parseFraction(attrs.start) || 0 });
      }
      if (selfClose !== "/") stack.push(node);
    } else {
      const node = stack.pop();
      if (node && CLIP_LIKE.has(node.tag) && node.pendingMarkers.length > 0) {
        const body = xml.slice(node.openEnd, match.index);
        const titleRanges = collectTitleRanges(node, body);
        const sourceDetails = collectBodyDetailsForRange(node, body, assetMap);
        for (const marker of node.pendingMarkers) {
          const markerValue = trim(marker.value);
          const markerAbsTime = (Number(node.timelineStart) || 0) + ((Number(marker.relStart) || 0) - (Number(node.start) || 0));
          const matchedTitle = chooseTitleForMarker(markerAbsTime, markerValue, titleRanges, globalTitles);
          if (!matchedTitle) continue;
          const visibleStart = matchedTitle?.timelineStart ?? node.timelineStart;
          const visibleEnd = matchedTitle?.timelineEnd ?? (node.timelineStart + (node.duration || 0));
          let details = collectBodyDetailsForRange(node, body, assetMap, visibleStart, visibleEnd);
          if (!details.hasDisplayableSegments) details = sourceDetails;
          const allowedKeys = new Set((details.groups || []).map((group) => canonicalSourceGroupKey(group.sourceKey, group.sourceFilename)).filter(Boolean));
          const filteredGlobalSegments = globalSegments.filter((segment) => allowedKeys.has(canonicalSourceGroupKey(segment.sourceKey, segment.sourceFilename)));
          const timelineDetails = summarizeSegmentsForWindow(filteredGlobalSegments, visibleStart, visibleEnd);
          let sourceDetailsForRows;
          if (options.markerScoped === true) {
            // A Shot List describes the exact frame captured at the marker,
            // not every edit crossed by the full naming-title duration.
            const halfFrame = (Number(timelineFrameDuration) || CONFIG.defaultFrameDuration) / 2;
            const markerDetails = summarizeSegmentsForWindow(
              globalSegments,
              markerAbsTime - halfFrame,
              markerAbsTime + halfFrame,
            );
            sourceDetailsForRows = markerDetails.hasDisplayableSegments ? markerDetails : details;
          } else if (options.ownerScoped === true) {
            // Shot List follows the visible marker owner, matching the original
            // SpliceKit workflow. Do not absorb unrelated clips merely because
            // they overlap the VFX title elsewhere in the timeline hierarchy.
            sourceDetailsForRows = timelineDetails.hasDisplayableSegments ? timelineDetails : details;
          } else {
            const titleLayerDetails = removeForeignBoundarySlivers(
              summarizeSegmentsForWindow(globalSegments, visibleStart, visibleEnd),
              details,
              timelineFrameDuration,
            );
            sourceDetailsForRows = mergeSourceDetails(
              titleLayerDetails,
              timelineDetails.hasDisplayableSegments ? timelineDetails : null,
              details,
            );
          }
          pushRowsFromDetails(rows, trim(matchedTitle.vfxNumber), trim(matchedTitle.note || marker.note), sourceDetailsForRows, {
            titleStartSeconds: Number(matchedTitle.timelineStart) || visibleStart,
            titleDurationSeconds: Number(matchedTitle.duration) || Math.max(visibleEnd - visibleStart, 0),
            markerAbsSeconds: markerAbsTime,
          });
        }
      }
    }
  }
  return dedupeRowsByTitle(rows);
}

function tcToFrames(tc, fps) {
  const match = /^(\d+):(\d+):(\d+):(\d+)$/.exec(String(tc || ""));
  if (!match) return 0;
  const [, hh, mm, ss, ff] = match.map(Number);
  return (((hh * 60 + mm) * 60) + ss) * fps + ff;
}

function framesToTC(frames, fps) {
  let f = Math.max(0, Math.floor((Number(frames) || 0) + 0.5));
  const hh = Math.floor(f / (fps * 3600));
  f %= fps * 3600;
  const mm = Math.floor(f / (fps * 60));
  f %= fps * 60;
  const ss = Math.floor(f / fps);
  const ff = f % fps;
  return [hh, mm, ss, ff].map((v) => String(v).padStart(2, "0")).join(":");
}

function framesToDropFrameTC(frames, fps) {
  let f = Math.max(0, Math.floor((Number(frames) || 0) + 0.5));
  const dropFrames = Math.round(fps * 0.0666666667);
  if (dropFrames <= 0) return framesToTC(f, fps);
  const framesPerMinute = (fps * 60) - dropFrames;
  const framesPer10Minutes = (fps * 600) - (dropFrames * 9);
  const tenMinuteChunks = Math.floor(f / framesPer10Minutes);
  const remainder = f % framesPer10Minutes;
  const extraDropped = (dropFrames * 9 * tenMinuteChunks)
    + (dropFrames * Math.floor(Math.max(0, remainder - dropFrames) / framesPerMinute));
  return framesToTC(f + extraDropped, fps);
}

function secondsToTC(seconds, frameDuration, tcFormat = "") {
  const fd = frameDuration && frameDuration > 0 ? frameDuration : CONFIG.defaultFrameDuration;
  const fps = Math.max(1, Math.floor((1 / fd) + 0.5));
  const totalFrames = Math.floor((Number(seconds) || 0) / fd + 0.000001);
  if (trim(tcFormat).toUpperCase() === "DF" && (fps === 30 || fps === 60)) return framesToDropFrameTC(totalFrames, fps);
  return framesToTC(totalFrames, fps);
}

function edlSafeName(value, maxLen) {
  let text = trim(value)
    .replace(/^🎞\s*Conform Prep(?:\s+v\d+(?:\.\d+)*)?\s*-\s*/u, "")
    .replace(/^[\p{Extended_Pictographic}\p{Emoji_Presentation}\uFE0F\s]+/gu, "")
    .replace(/\s+/g, "_")
    .replace(/[^\w.-]/g, "_")
    .replace(/_+/g, "_")
    .replace(/^[_\s.-]+|[_\s.-]+$/g, "");
  if (!text) text = "Project";
  if (maxLen && text.length > maxLen) text = text.slice(0, maxLen);
  return text;
}

function tsvEscape(value) {
  return String(value ?? "").replace(/\\/g, "\\\\").replace(/\t/g, "\\t").replace(/\r/g, "\\r").replace(/\n/g, "\\n");
}

function buildEdl(projectName, rows, timelineFrameDuration) {
  const fps = Math.max(1, Math.floor((1 / (timelineFrameDuration || CONFIG.defaultFrameDuration)) + 0.5));
  let recordCursor = tcToFrames(CONFIG.recordStartTC, fps);
  const edlLines = [
    `TITLE: ${edlSafeName(projectName || "VFX_PULL", 64)} MPS`,
    "FCM: NON-DROP FRAME",
    "",
  ];
  const companionRows = [];
  rows.forEach((row, index) => {
    const eventIndex = index + 1;
    const recordInFrames = recordCursor;
    const recordOutFrames = recordInFrames + Math.max(1, Number(row.sourceDurationFrames) || 1);
    const recordInTC = framesToTC(recordInFrames, fps);
    const recordOutTC = framesToTC(recordOutFrames, fps);
    const sourceInTC = secondsToTC(row.sourceInSeconds, row.sourceFrameDuration, row.sourceTcFormat);
    const sourceOutTC = secondsToTC(row.sourceOutSeconds, row.sourceFrameDuration, row.sourceTcFormat);
    const eventName = `${trim(row.vfxNumber)}_${trim(row.layer || "PL01")}`;
    const reel = edlSafeName(row.reel || row.sourceFilename, 32);
    edlLines.push(`${String(eventIndex).padStart(6, "0")}  ${reel.padEnd(32, " ")} V     C        ${sourceInTC} ${sourceOutTC} ${recordInTC} ${recordOutTC}`);
    edlLines.push(`* FROM CLIP NAME: ${trim(row.sourceFilename)}`);
    if (trim(row.sourcePath)) edlLines.push(`* FILE PATH: ${trim(row.sourcePath)}`);
    edlLines.push(`* LOC: ${sourceInTC} GREEN ${eventName}`);
    edlLines.push("");
    companionRows.push({
      index: eventIndex,
      eventName,
      vfxNumber: trim(row.vfxNumber),
      layer: trim(row.layer),
      reel,
      sourceFilename: trim(row.sourceFilename),
      sourcePath: trim(row.sourcePath),
      sourceTCIn: sourceInTC,
      sourceTCOut: sourceOutTC,
      sourceDurationFrames: Number(row.sourceDurationFrames) || 0,
      handleFramesPerSide: Number(row.handleFramesPerSide) || 0,
      totalHandleFrames: Number(row.totalHandleFrames) || 0,
      headHandleFrames: Number(row.headHandleFrames) || 0,
      tailHandleFrames: Number(row.tailHandleFrames) || 0,
      recordTCIn: recordInTC,
      recordTCOut: recordOutTC,
      locTC: sourceInTC,
      note: trim(row.note),
    });
    recordCursor = recordOutFrames;
  });
  return { edlText: edlLines.join("\n"), companionRows };
}

function buildCompanionTSV(rows) {
  const headers = ["index", "event_name", "vfx_number", "layer", "reel", "source_filename", "source_path", "source_tc_in", "source_tc_out", "source_duration_frames", "handle_frames_per_side", "total_handle_frames", "head_handle_frames", "tail_handle_frames", "record_tc_in", "record_tc_out", "loc_tc", "note"];
  const lines = [headers.join("\t")];
  for (const row of rows) {
    lines.push([
      row.index,
      row.eventName,
      row.vfxNumber,
      row.layer,
      row.reel,
      row.sourceFilename,
      row.sourcePath,
      row.sourceTCIn,
      row.sourceTCOut,
      row.sourceDurationFrames,
      row.handleFramesPerSide,
      row.totalHandleFrames,
      row.headHandleFrames,
      row.tailHandleFrames,
      row.recordTCIn,
      row.recordTCOut,
      row.locTC,
      row.note,
    ].map(tsvEscape).join("\t"));
  }
  return lines.join("\n");
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const configText = await fs.readFile(args.config, "utf8").catch(() => "");
  const config = parseKeyValueTSV(configText);
  const handleFrames = Math.max(0, Math.floor(Number(config.handle_frames || config.total_handle_frames || 0) + 0.5));
  const xml = await fs.readFile(args.sourceXml, "utf8");
  const projectName = trim(/<project\s+[^>]*name="([^"]+)"/s.exec(xml)?.[1] || "");
  const formatMap = parseFormats(xml);
  const assetMap = parseAssets(xml, formatMap);
  const timelineFrameDuration = parseSequenceFrameDuration(xml, formatMap);
  const rows = collectPullRows(xml, assetMap, timelineFrameDuration, handleFrames);
  if (rows.length === 0) throw new Error("No VFX pull rows could be built from the current project.");
  const { edlText, companionRows } = buildEdl(projectName, rows, timelineFrameDuration);
  const safeProject = edlSafeName(projectName || "Project", 80);
  await fs.mkdir(args.outputDir, { recursive: true });
  await fs.mkdir(path.dirname(args.report), { recursive: true });
  const edlPath = path.join(args.outputDir, `VFX Pull EDL - ${safeProject}.edl`);
  const tsvPath = path.join(args.outputDir, `VFX Pull EDL - ${safeProject}.tsv`);
  await fs.writeFile(edlPath, edlText);
  await fs.writeFile(tsvPath, buildCompanionTSV(companionRows));
  const reportLines = [
    `source_xml\t${args.sourceXml}`,
    `project\t${projectName}`,
    `handle_frames_per_side\t${handleFrames}`,
    `timeline_frame_duration\t${timelineFrameDuration}`,
    `rows\t${rows.length}`,
    `edl_path\t${edlPath}`,
    `tsv_path\t${tsvPath}`,
  ];
  await fs.writeFile(args.report, `${reportLines.join("\n")}\n`);
  console.log(JSON.stringify({ status: "ok", rows: rows.length, edl_path: edlPath, tsv_path: tsvPath, report_path: args.report }));
}

export {
  collectPullRows,
  parseAssets,
  parseFormats,
  parseSequenceFrameDuration,
  secondsToTC,
};

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    console.error(error.stack || String(error));
    process.exit(1);
  });
}
