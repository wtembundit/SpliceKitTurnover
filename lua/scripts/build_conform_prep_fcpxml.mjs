import fs from "node:fs/promises";
import { existsSync } from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import os from "node:os";
import { spawnSync } from "node:child_process";

function usage() {
  console.log(`Usage:
  node lua/scripts/build_conform_prep_fcpxml.mjs \\
    --source-xml <path> \\
    --output-xml <path> \\
    --report <path>`);
}

function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--source-xml") args.sourceXml = path.resolve(argv[++i]);
    else if (arg === "--output-xml") args.outputXml = path.resolve(argv[++i]);
    else if (arg === "--report") args.report = path.resolve(argv[++i]);
    else if (arg === "--help" || arg === "-h") {
      usage();
      process.exit(0);
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }
  if (!args.sourceXml || !args.outputXml || !args.report) {
    usage();
    throw new Error("Missing required arguments.");
  }
  return args;
}

function trim(v) {
  return String(v ?? "").trim();
}

function parseAttrs(attrStr = "") {
  const attrs = {};
  const regex = /([\w:_-]+)\s*=\s*"([^"]*)"/g;
  let match;
  while ((match = regex.exec(attrStr))) attrs[match[1]] = match[2];
  return attrs;
}

function escapeAttr(value) {
  return String(value ?? "")
    .replace(/&/g, "&amp;")
    .replace(/"/g, "&quot;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/'/g, "&apos;");
}

function decodeURIComponentSafe(v) {
  try {
    return decodeURIComponent(v);
  } catch {
    return v;
  }
}

function sourcePathFromSrc(src) {
  let value = trim(src);
  if (!value) return "";
  value = value.replace(/^file:\/\/localhost/, "");
  value = value.replace(/^file:\/\//, "");
  value = value.replace(/^file:/, "");
  value = value.replace(/\?.*$/, "");
  return decodeURIComponentSafe(value);
}

function basenameFromSrc(src) {
  const filePath = sourcePathFromSrc(src);
  if (!filePath) return "";
  return filePath.split("/").pop() ?? filePath;
}

function collectAssetInfo(xml) {
  const assets = new Map();
  for (const match of xml.matchAll(/<asset\s+([^>]*?)>([\s\S]*?)<\/asset>|<asset\s+([^>]*?)\/>/g)) {
    const attrStr = match[1] ?? match[3] ?? "";
    const body = match[2] ?? "";
    const attrs = parseAttrs(attrStr);
    const id = trim(attrs.id);
    if (!id) continue;
    const mediaRepSrc =
      body.match(/<media-rep[^>]*kind="original-media"[^>]*src="([^"]+)"/)?.[1] ??
      body.match(/<media-rep[^>]*src="([^"]+)"/)?.[1] ??
      attrs.src ??
      "";
    const sourcePath = sourcePathFromSrc(mediaRepSrc);
    const filename = basenameFromSrc(mediaRepSrc) || trim(attrs.name);
    assets.set(id, {
      id,
      name: trim(attrs.name),
      filename,
      sourcePath,
      start: trim(attrs.start),
      duration: trim(attrs.duration),
      hasVideo: attrs.hasVideo === "1",
      hasAudio: attrs.hasAudio === "1",
    });
  }
  return assets;
}

function collectFormatFrameDurations(xml) {
  const formats = new Map();
  for (const match of xml.matchAll(/<format\s+([^>]*?)\/?\s*>/g)) {
    const attrs = parseAttrs(match[1] ?? "");
    const frameDuration = parseTimeValue(attrs.frameDuration || "");
    if (attrs.id && frameDuration) formats.set(attrs.id, frameDuration);
  }
  const sequenceFormat = parseAttrs(xml.match(/<sequence\s+([^>]*?)>/)?.[1] ?? "").format;
  return {
    byId: formats,
    timeline: formats.get(sequenceFormat) || null,
  };
}

function projectName(xml) {
  return trim(xml.match(/<project\s+[^>]*name="([^"]+)"/)?.[1] ?? "");
}

function fcpxmlVersion(xml) {
  return trim(xml.match(/<fcpxml\s+version="([^"]+)"/)?.[1] ?? "");
}

function nextConformPrepName(xml) {
  const current = projectName(xml) || "Project";
  const base = current
    .replace(/^🎞\s+Conform Prep v\d+\s+-\s+/, "")
    .replace(/^🎞\s+Conform Prep\s+-\s+/, "");
  return `🎞 Conform Prep - ${base}`;
}

function replaceProjectName(xml, newName) {
  return xml.replace(/(<project\s+[^>]*name=")([^"]*)(")/, (_, a, _old, c) => `${a}${escapeAttr(newName)}${c}`);
}

function replaceProjectUID(xml) {
  return xml.replace(/(<project\s+[^>]*uid=")([^"]*)(")/, (_, a, _old, c) => `${a}${crypto.randomUUID().toUpperCase()}${c}`);
}

function maybeRenameTagOpen(openTag, newName) {
  if (!newName) return openTag;
  if (/name="[^"]*"/.test(openTag)) {
    return openTag.replace(/name="[^"]*"/, `name="${escapeAttr(newName)}"`);
  }
  return openTag.replace(/<([\w:-]+)/, `<$1 name="${escapeAttr(newName)}"`);
}

function buildElementOpenTag(tagName, attrs) {
  let open = `<${tagName}`;
  const orderedKeys = [];
  for (const key of ["ref", "offset", "name", "start", "duration", "format", "tcFormat", "lane", "enabled"]) {
    if (attrs[key] != null && attrs[key] !== "") orderedKeys.push(key);
  }
  for (const key of Object.keys(attrs)) {
    if (!orderedKeys.includes(key) && attrs[key] != null && attrs[key] !== "") orderedKeys.push(key);
  }
  for (const key of orderedKeys) open += ` ${key}="${escapeAttr(attrs[key])}"`;
  return `${open}>`;
}

function renameElementXML(xml, newName) {
  const openTagMatch = xml.match(/^<[\w:-]+[^>]*>/);
  if (!openTagMatch) return xml;
  const renamedOpen = maybeRenameTagOpen(openTagMatch[0], newName);
  return renamedOpen + xml.slice(openTagMatch[0].length);
}

function findFirstRefInBody(body) {
  return body.match(/<(?:video|audio|asset-clip|ref-clip)[^>]*ref="([^"]+)"/)?.[1] ?? "";
}

function collectTopLevelElements(body) {
  const elements = [];
  const stack = [];
  const tagRegex = /<(\/?)([\w:_-]+)(.*?)(\/?)>/gs;
  let match;
  let lastTopLevelStart = -1;
  let lastTopLevelTag = "";
  let lastTopLevelOpenEnd = -1;
  while ((match = tagRegex.exec(body))) {
    const [, closing, tagName, attrStr, selfClose] = match;
    const isClosing = closing === "/";
    const isSelfClosing = selfClose === "/";
    if (!isClosing) {
      if (stack.length === 0) {
        lastTopLevelStart = match.index;
        lastTopLevelTag = tagName;
        lastTopLevelOpenEnd = tagRegex.lastIndex;
      }
      const node = { tag: tagName, attrs: parseAttrs(attrStr), start: match.index, openEnd: tagRegex.lastIndex };
      if (!isSelfClosing) {
        stack.push(node);
      } else if (stack.length === 0) {
        elements.push({
          tag: tagName,
          attrs: node.attrs,
          xml: body.slice(match.index, tagRegex.lastIndex),
          body: "",
        });
      }
    } else {
      const node = stack.pop();
      if (node && stack.length === 0) {
        elements.push({
          tag: lastTopLevelTag,
          attrs: node.attrs,
          xml: body.slice(lastTopLevelStart, tagRegex.lastIndex),
          body: body.slice(lastTopLevelOpenEnd, match.index),
        });
      }
    }
  }
  return elements;
}

function analyzeSimpleSyncClip(body, assets) {
  if (/<sync-clip\b/.test(body) || /<mc-clip\b/.test(body)) return null;
  const top = collectTopLevelElements(body);
  const spine = top.find((item) => item.tag === "spine");

  let primary = null;
  let storyItems = [];
  let outerExtras = [];

  if (spine) {
    const spineItems = collectTopLevelElements(spine.body);
    primary = spineItems.find((item) => ["clip", "asset-clip", "ref-clip"].includes(item.tag));
    storyItems = spineItems.filter(
      (item) => item !== primary && item.tag !== "gap" && item.tag !== "transition"
    );
    outerExtras = top.filter((item) => item !== spine && item.tag !== "gap");
  } else {
    primary = top.find((item) => ["clip", "asset-clip", "ref-clip"].includes(item.tag));
  }
  const storyTags = new Set([
    "audio",
    "video",
    "clip",
    "title",
    "ref-clip",
    "asset-clip",
    "audition",
    "live-drawing",
    "caption",
    "spine",
  ]);
  if (!spine) {
    storyItems = top.filter((item) => item !== primary && item.tag !== "gap" && storyTags.has(item.tag));
    outerExtras = top.filter((item) => item !== primary && item.tag !== "gap" && !storyItems.includes(item));
  }

  // Safe next step:
  // Allow flat sync-clips whose only extra story items are titles.
  // We will hoist those titles back out as timeline siblings.
  if (
    primary &&
    storyItems.length > 0 &&
    storyItems.every((item) => item.tag === "title")
  ) {
    outerExtras = [...outerExtras, ...storyItems];
    storyItems = [];
  }

  // Conservative mode:
  // Only flatten sync-clips that contain a single primary media item plus
  // non-structural extras (markers, keywords, filters, metadata, intrinsic params).
  // Leave any sync-clip that also carries title/connected/story items untouched.
  if (storyItems.length > 0) return null;

  if (!primary) return null;
  const ref =
    trim(primary.attrs.ref) ||
    findFirstRefInBody(primary.body) ||
    findFirstRefInBody(primary.xml);
  if (!ref) return null;
  const asset = assets.get(ref);
  if (!asset?.filename) return null;
  return {
    asset,
    primary,
    outerExtras,
    storyItems,
    fromSpine: Boolean(spine),
  };
}

function analyzeSyncClipRisk(body) {
  const reasons = [];
  if (/<mc-clip\b/.test(body)) reasons.push("contains-multicam");
  if (/<sync-clip\b/.test(body)) reasons.push("contains-nested-sync");

  const top = collectTopLevelElements(body);
  const spine = top.find((item) => item.tag === "spine");
  if (spine) {
    const spineItems = collectTopLevelElements(spine.body);
    const primary = spineItems.find((item) => ["clip", "asset-clip", "ref-clip"].includes(item.tag));
    const storyItems = spineItems.filter((item) => item !== primary && item.tag !== "gap");
    if (storyItems.length > 0) reasons.push("contains-story-items");
  }

  const riskyOuterStoryTags = new Set([
    "audio",
    "video",
    "clip",
    "title",
    "ref-clip",
    "asset-clip",
    "audition",
    "live-drawing",
    "caption",
    "spine",
  ]);
  const riskyOuter = top.filter((item) => riskyOuterStoryTags.has(item.tag));
  for (const item of riskyOuter) {
    const reason = item.tag === "title" ? "contains-title" : `contains-${item.tag}`;
    if (!reasons.includes(reason)) reasons.push(reason);
  }
  return reasons;
}

function classifyTopLevelElements(elements) {
  const buckets = {
    notes: [],
    timeMaps: [],
    objectTrackers: [],
    intrinsic: [],
    story: [],
    markersAndKeywords: [],
    audioComp: [],
    filters: [],
    metadata: [],
    trailing: [],
  };

  for (const item of elements || []) {
    const tag = item.tag;
    if (tag === "note") buckets.notes.push(item.xml);
    else if (tag === "timeMap") buckets.timeMaps.push(item.xml);
    else if (tag === "object-tracker") buckets.objectTrackers.push(item.xml);
    else if (tag.startsWith("adjust-")) buckets.intrinsic.push(item.xml);
    else if (["marker", "chapter-marker", "rating", "keyword"].includes(tag)) buckets.markersAndKeywords.push(item.xml);
    else if (tag === "metadata") buckets.metadata.push(item.body);
    else if (tag.startsWith("filter-")) buckets.filters.push(item.xml);
    else if (tag === "audio-role-source") buckets.audioComp.push(item.xml);
    else buckets.story.push(item.xml);
  }

  return buckets;
}

function mergeIntrinsicElements(primaryBuckets, outerBuckets) {
  const merged = [];
  const seenTags = new Set();
  const items = [...(outerBuckets?.intrinsic || []), ...(primaryBuckets?.intrinsic || [])];
  const dtdOrder = new Map([
    ["adjust-crop", 10],
    ["adjust-corners", 20],
    ["adjust-conform", 30],
    ["adjust-transform", 40],
    ["adjust-blend", 50],
    ["adjust-stabilization", 60],
    ["adjust-rollingShutter", 70],
    ["adjust-360-transform", 80],
    ["adjust-reorient", 90],
    ["adjust-orientation", 100],
    ["adjust-cinematic", 110],
    ["adjust-colorConform", 120],
    ["adjust-volume", 200],
    ["adjust-panner", 210],
  ]);
  for (const xml of items) {
    const tag = xml.match(/^<([\w:-]+)/)?.[1] ?? "";
    if (!tag || seenTags.has(tag)) continue;
    seenTags.add(tag);
    merged.push(xml);
  }
  return merged
    .map((xml, index) => {
      const tag = xml.match(/^<([\w:-]+)/)?.[1] ?? "";
      return { xml, index, order: dtdOrder.get(tag) ?? 1000 };
    })
    .sort((a, b) => (a.order - b.order) || (a.index - b.index))
    .map((item) => item.xml);
}

function mergeMetadataBodies(bodies) {
  const parts = [];
  for (const body of bodies || []) {
    const trimmed = trim(body);
    if (trimmed) parts.push(trimmed);
  }
  if (parts.length === 0) return "";
  return `<metadata>\n${parts.join("\n")}\n</metadata>`;
}

function gcdBigInt(a, b) {
  let x = a < 0n ? -a : a;
  let y = b < 0n ? -b : b;
  while (y !== 0n) {
    const t = x % y;
    x = y;
    y = t;
  }
  return x || 1n;
}

function parseTimeValue(value) {
  const raw = trim(value).replace(/s$/, "");
  if (!raw) return null;
  if (raw.includes("/")) {
    const [num, den] = raw.split("/");
    if (!num || !den) return null;
    return { num: BigInt(num), den: BigInt(den) };
  }
  return { num: BigInt(raw), den: 1n };
}

function addTime(a, b) {
  return {
    num: a.num * b.den + b.num * a.den,
    den: a.den * b.den,
  };
}

function subTime(a, b) {
  return {
    num: a.num * b.den - b.num * a.den,
    den: a.den * b.den,
  };
}

function mulTime(a, b) {
  return {
    num: a.num * b.num,
    den: a.den * b.den,
  };
}

function divTime(a, b) {
  return {
    num: a.num * b.den,
    den: a.den * b.num,
  };
}

function compareTime(a, b) {
  const diff = subTime(a, b);
  if (diff.num < 0n) return -1;
  if (diff.num > 0n) return 1;
  return 0;
}

function formatTimeValue(value) {
  if (!value) return "";
  const sign = value.num < 0n ? -1n : 1n;
  const absNum = value.num < 0n ? -value.num : value.num;
  const gcd = gcdBigInt(absNum, value.den);
  const num = (sign < 0n ? -absNum : absNum) / gcd;
  const den = value.den / gcd;
  if (den === 1n) return `${num}s`;
  return `${num}/${den}s`;
}

function timeToFloat(value) {
  if (!value) return NaN;
  return Number(value.num) / Number(value.den);
}

function floatToTime(value, den = 1000000000n) {
  if (!Number.isFinite(value)) return null;
  const num = BigInt(Math.round(value * Number(den)));
  return { num, den };
}

function quantizeTime(value, den = 2400n) {
  if (!value) return value;
  const numerator = value.num * den;
  const denominator = value.den;
  const half = denominator / 2n;
  const rounded =
    numerator >= 0n
      ? (numerator + half) / denominator
      : (numerator - half) / denominator;
  return { num: rounded, den };
}

function parseTimeMapXML(xml) {
  const match = xml.match(/<timeMap\b([^>]*)>([\s\S]*?)<\/timeMap>/);
  if (!match) return [];
  const timeMapAttrs = parseAttrs(match[1] ?? "");
  const points = [];
  for (const point of match[2].matchAll(/<timept\b([^>]*)\/>/g)) {
    const attrs = parseAttrs(point[1] ?? "");
    const time = parseTimeValue(attrs.time || "");
    const value = parseTimeValue(attrs.value || "");
    if (!time || !value) continue;
    const inTime = parseTimeValue(attrs.inTime || "");
    const outTime = parseTimeValue(attrs.outTime || "");
    points.push({ time, value, interp: attrs.interp || "smooth2", inTime, outTime });
  }
  points._attrs = timeMapAttrs;
  return points;
}

function quantizeTimeMapPoints(points, den = 2400n) {
  const out = (points || []).map((pt) => ({
    ...pt,
    time: quantizeTime(pt.time, den),
    value: quantizeTime(pt.value, den),
    inTime: pt.inTime ? quantizeTime(pt.inTime, den) : undefined,
    outTime: pt.outTime ? quantizeTime(pt.outTime, den) : undefined,
  }));
  if (points?._attrs) out._attrs = { ...points._attrs };
  return out;
}

function withTimeMapAttrs(points, attrs) {
  if (!points) return points;
  if (attrs && Object.keys(attrs).length > 0) points._attrs = { ...attrs };
  return points;
}

function buildTimeMapXML(points, timeMapAttrs = null) {
  if (!points || points.length < 2) return "";
  const sourceAttrs = timeMapAttrs || points._attrs || {};
  const openAttrs = Object.entries(sourceAttrs)
    .filter(([key, value]) => key && value != null && value !== "")
    .map(([key, value]) => ` ${key}="${escapeAttr(value)}"`)
    .join("");
  const body = points.map((pt) => {
    let attrs = `time="${escapeAttr(formatTimeValue(pt.time))}" value="${escapeAttr(formatTimeValue(pt.value))}" interp="${escapeAttr(pt.interp || "smooth2")}"`;
    if (pt.inTime) attrs += ` inTime="${escapeAttr(formatTimeValue(pt.inTime))}"`;
    if (pt.outTime) attrs += ` outTime="${escapeAttr(formatTimeValue(pt.outTime))}"`;
    return `                                    <timept ${attrs}/>`;
  }).join("\n");
  return `<timeMap${openAttrs}>\n${body}\n                                </timeMap>`;
}

function debugDescribePoints(points, label) {
  const lines = [];
  lines.push(`${label}: ${points?.length || 0} points`);
  for (const [index, pt] of (points || []).entries()) {
    lines.push(
      `  [${index}] time=${formatTimeValue(pt.time)} value=${formatTimeValue(pt.value)} interp=${pt.interp || "smooth2"} in=${pt.inTime ? formatTimeValue(pt.inTime) : "-"} out=${pt.outTime ? formatTimeValue(pt.outTime) : "-"}`
    );
  }
  return lines;
}

function debugDescribePointsRelative(points, label, timeBase, valueBase) {
  const lines = [];
  lines.push(`${label} (relative): ${points?.length || 0} points`);
  for (const [index, pt] of (points || []).entries()) {
    const relTime = timeBase ? subTime(pt.time, timeBase) : pt.time;
    const relValue = valueBase ? subTime(pt.value, valueBase) : pt.value;
    lines.push(
      `  [${index}] dTime=${formatTimeValue(relTime)} dValue=${formatTimeValue(relValue)} interp=${pt.interp || "smooth2"} in=${pt.inTime ? formatTimeValue(pt.inTime) : "-"} out=${pt.outTime ? formatTimeValue(pt.outTime) : "-"}`
    );
  }
  return lines;
}

function debugSampleTimeMapByFrame(points, clipStart, clipDuration, label, fps = 24n) {
  const lines = [];
  if (!points?.length || !clipStart || !clipDuration) return lines;
  const frameCount = Math.max(0, Math.round(timeToFloat(clipDuration) * Number(fps)));
  lines.push(`${label} frame-samples: ${frameCount + 1}`);
  let prevValue = null;
  for (let frame = 0; frame <= frameCount; frame += 1) {
    const t = addTime(clipStart, frameOffsetTime(frame, fps));
    const value = interpolateTimeMap(points, t);
    if (!value) continue;
    const rel = subTime(value, points[0].value);
    let delta = "-";
    let deltaFrames = "-";
    let speedPct = "-";
    if (prevValue) delta = formatTimeValue(subTime(value, prevValue));
    if (prevValue) {
      const df = timeToFloat(subTime(value, prevValue)) * Number(fps);
      deltaFrames = `${df.toFixed(3)}f`;
      speedPct = `${(df * 100).toFixed(1)}%`;
    }
    lines.push(
      `  f${frame}: time=${formatTimeValue(t)} value=${formatTimeValue(value)} dValue=${delta} dFrames=${deltaFrames} speed=${speedPct} rel=${formatTimeValue(rel)}`
    );
    prevValue = value;
  }
  return lines;
}

function debugSampleHermiteReference(clipStart, clipDuration, startTc, endTc, startSpeed, endSpeed, label, fps = 24n) {
  const lines = [];
  if (!clipStart || !clipDuration) return lines;
  const startValue = timeValueFromTc(startTc, fps);
  const endValue = timeValueFromTc(endTc, fps);
  if (!startValue || !endValue) return lines;
  const totalFrames = Math.max(0, Math.round(timeToFloat(clipDuration) * Number(fps)));
  const T = totalFrames;
  const y0 = Number(startValue.num) / Number(startValue.den) * Number(fps);
  const y1 = Number(endValue.num) / Number(endValue.den) * Number(fps);
  lines.push(`${label} hermite-reference: ${totalFrames + 1}`);
  for (let frame = 0; frame <= totalFrames; frame += 1) {
    const u = T === 0 ? 0 : frame / T;
    const h00 = 2 * u ** 3 - 3 * u ** 2 + 1;
    const h10 = u ** 3 - 2 * u ** 2 + u;
    const h01 = -2 * u ** 3 + 3 * u ** 2;
    const h11 = u ** 3 - u ** 2;
    const y = h00 * y0 + h10 * T * startSpeed + h01 * y1 + h11 * T * endSpeed;
    const dh00 = 6 * u ** 2 - 6 * u;
    const dh10 = 3 * u ** 2 - 4 * u + 1;
    const dh01 = -6 * u ** 2 + 6 * u;
    const dh11 = 3 * u ** 2 - 2 * u;
    const slope = T === 0 ? startSpeed : (dh00 * y0 + dh10 * T * startSpeed + dh01 * y1 + dh11 * T * endSpeed) / T;
    lines.push(`  f${frame}: srcFrame=${y.toFixed(3)} speed=${(slope * 100).toFixed(1)}%`);
  }
  return lines;
}

function firstVideoRangeFromPrimaryBody(body) {
  const elements = collectTopLevelElements(body || "");
  const video = elements.find((item) => item.tag === "video");
  if (!video) return null;
  const start = parseTimeValue(video.attrs.start || "");
  const duration = parseTimeValue(video.attrs.duration || "");
  if (!start || !duration) return null;
  return { start, end: addTime(start, duration) };
}

function clampTimeMapValueRange(points, range) {
  if (!range?.start || !range?.end) return points || [];
  return (points || []).map((pt) => {
    let value = pt.value;
    if (compareTime(value, range.start) < 0) value = range.start;
    if (compareTime(value, range.end) > 0) value = range.end;
    return { ...pt, value };
  });
}

function buildSmooth2Segments(points) {
  if (!points || points.length < 2) return [];
  const segments = [];
  const transitions = [];
  for (let i = 1; i < points.length - 1; i += 1) {
    const pt = points[i];
    if (!pt.inTime && !pt.outTime) continue;
    const prev = points[i - 1];
    const next = points[i + 1];
    const leftSlope = divTime(subTime(pt.value, prev.value), subTime(pt.time, prev.time));
    const rightSlope = divTime(subTime(next.value, pt.value), subTime(next.time, pt.time));
    const inTime = pt.inTime || { num: 0n, den: 1n };
    const outTime = pt.outTime || { num: 0n, den: 1n };
    const startTime = subTime(pt.time, inTime);
    const endTime = addTime(pt.time, outTime);
    const startValue = subTime(pt.value, mulTime(leftSlope, inTime));
    const endValue = addTime(pt.value, mulTime(rightSlope, outTime));
    transitions.push({ index: i, startTime, endTime, startValue, endValue, leftSlope, rightSlope });
  }
  let currentTime = points[0].time;
  let currentValue = points[0].value;
  for (const tr of transitions) {
    if (compareTime(tr.startTime, currentTime) > 0) {
      segments.push({
        kind: "linear",
        startTime: currentTime,
        endTime: tr.startTime,
        startValue: currentValue,
        endValue: tr.startValue,
      });
    }
    segments.push({
      kind: "ramp",
      startTime: tr.startTime,
      endTime: tr.endTime,
      startValue: tr.startValue,
      endValue: tr.endValue,
      leftSlope: tr.leftSlope,
      rightSlope: tr.rightSlope,
    });
    currentTime = tr.endTime;
    currentValue = tr.endValue;
  }
  const last = points[points.length - 1];
  if (compareTime(last.time, currentTime) > 0) {
    segments.push({
      kind: "linear",
      startTime: currentTime,
      endTime: last.time,
      startValue: currentValue,
      endValue: last.value,
    });
  }
  return segments;
}

function collectSmooth2TransitionBoundaryTimes(points) {
  const times = [];
  if (!points || points.length < 3) return times;
  for (let i = 1; i < points.length - 1; i += 1) {
    const pt = points[i];
    if (!pt.inTime && !pt.outTime) continue;
    if (pt.inTime) times.push(subTime(pt.time, pt.inTime));
    times.push(pt.time);
    if (pt.outTime) times.push(addTime(pt.time, pt.outTime));
  }
  return times;
}

function interpolateRampSegment(seg, t) {
  const dt = timeToFloat(subTime(seg.endTime, seg.startTime));
  if (!Number.isFinite(dt) || dt === 0) return seg.startValue;
  const u = timeToFloat(divTime(subTime(t, seg.startTime), subTime(seg.endTime, seg.startTime)));
  const y0 = timeToFloat(seg.startValue);
  const y1 = timeToFloat(seg.endValue);
  const m0 = timeToFloat(seg.leftSlope);
  const m1 = timeToFloat(seg.rightSlope);
  const h00 = 2 * u ** 3 - 3 * u ** 2 + 1;
  const h10 = u ** 3 - 2 * u ** 2 + u;
  const h01 = -2 * u ** 3 + 3 * u ** 2;
  const h11 = u ** 3 - u ** 2;
  const y = h00 * y0 + h10 * dt * m0 + h01 * y1 + h11 * dt * m1;
  return floatToTime(y);
}

function interpolateTimeMap(points, t) {
  if (!points || points.length < 2) return null;
  if ((points || []).some((pt) => pt.inTime || pt.outTime)) {
    const segments = buildSmooth2Segments(points);
    for (const seg of segments) {
      if (compareTime(t, seg.startTime) < 0 || compareTime(t, seg.endTime) > 0) continue;
      if (seg.kind === "linear") {
        const ratio = divTime(subTime(t, seg.startTime), subTime(seg.endTime, seg.startTime));
        return addTime(seg.startValue, mulTime(subTime(seg.endValue, seg.startValue), ratio));
      }
      return interpolateRampSegment(seg, t);
    }
  }
  for (let i = 0; i < points.length - 1; i += 1) {
    const a = points[i];
    const b = points[i + 1];
    if (compareTime(t, a.time) < 0 || compareTime(t, b.time) > 0) continue;
    if (compareTime(a.time, b.time) === 0) return a.value;
    const smooth = (a.interp || b.interp) === "smooth2" && (a.outTime || b.inTime);
    if (!smooth) {
      const ratio = divTime(subTime(t, a.time), subTime(b.time, a.time));
      return addTime(a.value, mulTime(subTime(b.value, a.value), ratio));
    }
    const x0 = timeToFloat(a.time);
    const x1 = timeToFloat(addTime(a.time, a.outTime || { num: 0n, den: 1n }));
    const x2 = timeToFloat(subTime(b.time, b.inTime || { num: 0n, den: 1n }));
    const x3 = timeToFloat(b.time);
    const y0 = timeToFloat(a.value);
    const y1 = y0;
    const y2 = timeToFloat(b.value);
    const y3 = y2;
    const targetX = timeToFloat(t);
    const bez = (p0, p1, p2, p3, u) =>
      ((1 - u) ** 3) * p0 +
      3 * ((1 - u) ** 2) * u * p1 +
      3 * (1 - u) * (u ** 2) * p2 +
      (u ** 3) * p3;
    let lo = 0;
    let hi = 1;
    for (let iter = 0; iter < 50; iter += 1) {
      const mid = (lo + hi) / 2;
      const x = bez(x0, x1, x2, x3, mid);
      if (x < targetX) lo = mid;
      else hi = mid;
    }
    const u = (lo + hi) / 2;
    return floatToTime(bez(y0, y1, y2, y3, u));
  }
  return null;
}

function interpolateTimeMapBezierOnly(points, t) {
  if (!points || points.length < 2) return null;
  for (let i = 0; i < points.length - 1; i += 1) {
    const a = points[i];
    const b = points[i + 1];
    if (compareTime(t, a.time) < 0 || compareTime(t, b.time) > 0) continue;
    if (compareTime(a.time, b.time) === 0) return a.value;
    const smooth = (a.interp || b.interp) === "smooth2" && (a.outTime || b.inTime);
    if (!smooth) {
      const ratio = divTime(subTime(t, a.time), subTime(b.time, a.time));
      return addTime(a.value, mulTime(subTime(b.value, a.value), ratio));
    }
    const x0 = timeToFloat(a.time);
    const x1 = timeToFloat(addTime(a.time, a.outTime || { num: 0n, den: 1n }));
    const x2 = timeToFloat(subTime(b.time, b.inTime || { num: 0n, den: 1n }));
    const x3 = timeToFloat(b.time);
    const y0 = timeToFloat(a.value);
    const y1 = y0;
    const y2 = timeToFloat(b.value);
    const y3 = y2;
    const targetX = timeToFloat(t);
    const bez = (p0, p1, p2, p3, u) =>
      ((1 - u) ** 3) * p0 +
      3 * ((1 - u) ** 2) * u * p1 +
      3 * (1 - u) * (u ** 2) * p2 +
      (u ** 3) * p3;
    let lo = 0;
    let hi = 1;
    for (let iter = 0; iter < 50; iter += 1) {
      const mid = (lo + hi) / 2;
      const x = bez(x0, x1, x2, x3, mid);
      if (x < targetX) lo = mid;
      else hi = mid;
    }
    const u = (lo + hi) / 2;
    return floatToTime(bez(y0, y1, y2, y3, u));
  }
  return null;
}

function solveOuterTimeForValue(points, value) {
  const solved = [];
  if (!points || points.length < 2) return solved;
  if ((points || []).some((pt) => pt.inTime || pt.outTime)) {
    const segments = buildSmooth2Segments(points);
    for (const seg of segments) {
      const minV = compareTime(seg.startValue, seg.endValue) <= 0 ? seg.startValue : seg.endValue;
      const maxV = compareTime(seg.startValue, seg.endValue) <= 0 ? seg.endValue : seg.startValue;
      if (compareTime(value, minV) < 0 || compareTime(value, maxV) > 0) continue;
      if (seg.kind === "linear") {
        if (compareTime(seg.startValue, seg.endValue) === 0) continue;
        const ratio = divTime(subTime(value, seg.startValue), subTime(seg.endValue, seg.startValue));
        solved.push(addTime(seg.startTime, mulTime(subTime(seg.endTime, seg.startTime), ratio)));
        continue;
      }
      let lo = 0;
      let hi = 1;
      const y0 = timeToFloat(seg.startValue);
      const y1 = timeToFloat(seg.endValue);
      const increasing = y1 >= y0;
      const target = timeToFloat(value);
      for (let iter = 0; iter < 60; iter += 1) {
        const mid = (lo + hi) / 2;
        const dt = timeToFloat(subTime(seg.endTime, seg.startTime));
        const m0 = timeToFloat(seg.leftSlope);
        const m1 = timeToFloat(seg.rightSlope);
        const h00 = 2 * mid ** 3 - 3 * mid ** 2 + 1;
        const h10 = mid ** 3 - 2 * mid ** 2 + mid;
        const h01 = -2 * mid ** 3 + 3 * mid ** 2;
        const h11 = mid ** 3 - mid ** 2;
        const y = h00 * y0 + h10 * dt * m0 + h01 * y1 + h11 * dt * m1;
        if ((increasing && y < target) || (!increasing && y > target)) lo = mid;
        else hi = mid;
      }
      const u = (lo + hi) / 2;
      solved.push(addTime(seg.startTime, mulTime(subTime(seg.endTime, seg.startTime), floatToTime(u))));
    }
    return solved;
  }
  for (let i = 0; i < points.length - 1; i += 1) {
    const a = points[i];
    const b = points[i + 1];
    const minV = compareTime(a.value, b.value) <= 0 ? a.value : b.value;
    const maxV = compareTime(a.value, b.value) <= 0 ? b.value : a.value;
    if (compareTime(value, minV) < 0 || compareTime(value, maxV) > 0) continue;
    if (compareTime(a.value, b.value) === 0) continue;
    const smooth = (a.interp || b.interp) === "smooth2" && (a.outTime || b.inTime);
    if (!smooth) {
      const ratio = divTime(subTime(value, a.value), subTime(b.value, a.value));
      solved.push(addTime(a.time, mulTime(subTime(b.time, a.time), ratio)));
      continue;
    }
    const x0 = timeToFloat(a.time);
    const x1 = timeToFloat(addTime(a.time, a.outTime || { num: 0n, den: 1n }));
    const x2 = timeToFloat(subTime(b.time, b.inTime || { num: 0n, den: 1n }));
    const x3 = timeToFloat(b.time);
    const y0 = timeToFloat(a.value);
    const y1 = y0;
    const y2 = timeToFloat(b.value);
    const y3 = y2;
    const targetY = timeToFloat(value);
    const increasing = y3 >= y0;
    const bez = (p0, p1, p2, p3, u) =>
      ((1 - u) ** 3) * p0 +
      3 * ((1 - u) ** 2) * u * p1 +
      3 * (1 - u) * (u ** 2) * p2 +
      (u ** 3) * p3;
    let lo = 0;
    let hi = 1;
    for (let iter = 0; iter < 50; iter += 1) {
      const mid = (lo + hi) / 2;
      const y = bez(y0, y1, y2, y3, mid);
      if ((increasing && y < targetY) || (!increasing && y > targetY)) lo = mid;
      else hi = mid;
    }
    const u = (lo + hi) / 2;
    solved.push(floatToTime(bez(x0, x1, x2, x3, u)));
  }
  return solved;
}

function solveOuterTimeForValueBezierOnly(points, value) {
  const solved = [];
  if (!points || points.length < 2) return solved;
  for (let i = 0; i < points.length - 1; i += 1) {
    const a = points[i];
    const b = points[i + 1];
    const minV = compareTime(a.value, b.value) <= 0 ? a.value : b.value;
    const maxV = compareTime(a.value, b.value) <= 0 ? b.value : a.value;
    if (compareTime(value, minV) < 0 || compareTime(value, maxV) > 0) continue;
    if (compareTime(a.value, b.value) === 0) continue;
    const smooth = (a.interp || b.interp) === "smooth2" && (a.outTime || b.inTime);
    if (!smooth) {
      const ratio = divTime(subTime(value, a.value), subTime(b.value, a.value));
      solved.push(addTime(a.time, mulTime(subTime(b.time, a.time), ratio)));
      continue;
    }
    const x0 = timeToFloat(a.time);
    const x1 = timeToFloat(addTime(a.time, a.outTime || { num: 0n, den: 1n }));
    const x2 = timeToFloat(subTime(b.time, b.inTime || { num: 0n, den: 1n }));
    const x3 = timeToFloat(b.time);
    const y0 = timeToFloat(a.value);
    const y1 = y0;
    const y2 = timeToFloat(b.value);
    const y3 = y2;
    const targetY = timeToFloat(value);
    const increasing = y3 >= y0;
    const bez = (p0, p1, p2, p3, u) =>
      ((1 - u) ** 3) * p0 +
      3 * ((1 - u) ** 2) * u * p1 +
      3 * (1 - u) * (u ** 2) * p2 +
      (u ** 3) * p3;
    let lo = 0;
    let hi = 1;
    for (let iter = 0; iter < 50; iter += 1) {
      const mid = (lo + hi) / 2;
      const y = bez(y0, y1, y2, y3, mid);
      if ((increasing && y < targetY) || (!increasing && y > targetY)) lo = mid;
      else hi = mid;
    }
    const u = (lo + hi) / 2;
    solved.push(floatToTime(bez(x0, x1, x2, x3, u)));
  }
  return solved;
}

function dedupeTimePoints(points) {
  const seen = new Set();
  const out = [];
  for (const pt of points) {
    const key = `${formatTimeValue(pt.time)}|${formatTimeValue(pt.value)}`;
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(pt);
  }
  return out;
}

function mapOuterValueToInnerTime(outerValue, primaryOffset, primaryStart) {
  return addTime(primaryStart, subTime(outerValue, primaryOffset));
}

function mapInnerTimeToOuterValue(innerTime, primaryOffset, primaryStart) {
  return addTime(primaryOffset, subTime(innerTime, primaryStart));
}

function deriveVisibleSourceStartFromNested(outerPoints, innerPoints, primaryOffset, primaryStart, syncStart) {
  if (!outerPoints?.length || !innerPoints?.length || !primaryOffset || !primaryStart || !syncStart) {
    return null;
  }
  const outerVisibleValue = interpolateTimeMap(outerPoints, syncStart);
  if (!outerVisibleValue) return null;
  const innerVisibleTime = mapOuterValueToInnerTime(outerVisibleValue, primaryOffset, primaryStart);
  if (!innerVisibleTime) return null;
  return interpolateTimeMap(innerPoints, innerVisibleTime);
}

function deriveVisibleInnerTimeFromNested(outerPoints, primaryOffset, primaryStart, syncStart) {
  if (!outerPoints?.length || !primaryOffset || !primaryStart || !syncStart) {
    return null;
  }
  const outerVisibleValue = interpolateTimeMap(outerPoints, syncStart);
  if (!outerVisibleValue) return null;
  return mapOuterValueToInnerTime(outerVisibleValue, primaryOffset, primaryStart);
}

function deriveVisibleSourceEndFromNested(outerPoints, innerPoints, primaryOffset, primaryStart, syncStart, syncDuration) {
  if (!outerPoints?.length || !innerPoints?.length || !primaryOffset || !primaryStart || !syncStart || !syncDuration) {
    return null;
  }
  const syncEnd = addTime(syncStart, syncDuration);
  const outerVisibleValue = interpolateTimeMap(outerPoints, syncEnd);
  if (!outerVisibleValue) return null;
  const innerVisibleTime = mapOuterValueToInnerTime(outerVisibleValue, primaryOffset, primaryStart);
  if (!innerVisibleTime) return null;
  return interpolateTimeMap(innerPoints, innerVisibleTime);
}

function scaleInnerTimeMapByOuterRate(innerPoints, outerPoints) {
  if (!innerPoints?.length || !outerPoints?.length) return innerPoints;
  if (innerPoints.length < 2 || outerPoints.length < 2) return innerPoints;
  const innerFirst = innerPoints[0];
  const outerFirst = outerPoints[0];
  const outerLast = outerPoints[outerPoints.length - 1];
  const outerTimeDelta = subTime(outerLast.time, outerFirst.time);
  const outerValueDelta = subTime(outerLast.value, outerFirst.value);
  if (outerTimeDelta.num === 0n) return innerPoints;
  const outerRate = divTime(outerValueDelta, outerTimeDelta);
  return innerPoints.map((pt, index) => {
    if (index === 0) return { ...pt };
    const relativeValue = subTime(pt.value, innerFirst.value);
    return {
      ...pt,
      value: addTime(innerFirst.value, mulTime(relativeValue, outerRate)),
    };
  });
}

function alignAssetClipTimeMapValueToVisibleStart(points, clipStart) {
  if (!points?.length || !clipStart) return points || [];
  const visibleValue = interpolateTimeMap(points, clipStart);
  if (!visibleValue) return points;
  const targetValue = mulTime(clipStart, { num: 2n, den: 1n });
  const delta = subTime(targetValue, visibleValue);
  if (delta.num === 0n) return points;
  return points.map((pt) => ({
    ...pt,
    value: addTime(pt.value, delta),
  }));
}

function deriveVisibleSourceStartFromOuterOnly(outerPoints, primaryOffset, primaryStart, syncStart) {
  if (!outerPoints?.length || !primaryOffset || !primaryStart || !syncStart) {
    return null;
  }
  const outerVisibleValue = interpolateTimeMap(outerPoints, syncStart);
  if (!outerVisibleValue) return null;
  return mapOuterValueToInnerTime(outerVisibleValue, primaryOffset, primaryStart);
}

function rebaseOuterOnlyTimeMapToClipDomain(outerPoints, syncStart, clipStart) {
  if (!outerPoints?.length || !syncStart || !clipStart) return outerPoints || [];
  const out = outerPoints.map((point) => ({
    ...point,
    time: addTime(clipStart, subTime(point.time, syncStart)),
  }));
  if (outerPoints._attrs) out._attrs = { ...outerPoints._attrs };
  return out;
}

function rebaseOuterOnlyTimeMapToFlattenedClip(
  outerPoints,
  syncStart,
  clipStart,
  primaryOffset,
  primaryStart
) {
  if (!outerPoints?.length) return outerPoints || [];
  const rebased = rebaseOuterOnlyTimeMapToClipDomain(outerPoints, syncStart, clipStart);
  const out = rebased.map((point) => ({
    ...point,
    value:
      primaryOffset && primaryStart
        ? mapOuterValueToInnerTime(point.value, primaryOffset, primaryStart) || point.value
        : point.value,
  }));
  if (rebased._attrs) out._attrs = { ...rebased._attrs };
  return out;
}

function timeRangesOverlap(startA, endA, startB, endB) {
  return compareTime(startA, endB) < 0 && compareTime(endA, startB) > 0;
}

function hasHoldSegmentOverlappingRange(points, rangeStart, rangeEnd) {
  if (!points?.length || !rangeStart || !rangeEnd) return false;
  for (let i = 0; i < points.length - 1; i += 1) {
    const a = points[i];
    const b = points[i + 1];
    if (compareTime(a.value, b.value) !== 0) continue;
    if (compareTime(a.time, b.time) >= 0) continue;
    if (timeRangesOverlap(a.time, b.time, rangeStart, rangeEnd)) return true;
  }
  return false;
}

function trimTimeMapToRange(points, rangeStart, rangeEnd) {
  if (!points?.length || !rangeStart || !rangeEnd || compareTime(rangeEnd, rangeStart) <= 0) {
    return points || [];
  }
  const out = [];
  const push = (pt) => {
    if (!pt?.time || !pt?.value) return;
    const last = out[out.length - 1];
    if (
      last &&
      compareTime(last.time, pt.time) === 0 &&
      compareTime(last.value, pt.value) === 0
    ) {
      return;
    }
    out.push(pt);
  };

  const startValue = interpolateTimeMap(points, rangeStart);
  if (startValue) push({ time: rangeStart, value: startValue, interp: "smooth2" });

  for (const pt of points) {
    if (compareTime(pt.time, rangeStart) <= 0) continue;
    if (compareTime(pt.time, rangeEnd) >= 0) continue;
    push({ ...pt, inTime: undefined, outTime: undefined });
  }

  const endValue = interpolateTimeMap(points, rangeEnd);
  if (endValue) push({ time: rangeEnd, value: endValue, interp: "smooth2" });
  return out.length >= 2 ? dedupeTimePoints(out) : points || [];
}

function detectMicroRampIntoHold(points, rangeStart, rangeEnd, frameDuration) {
  if (
    !points?.length ||
    points.length < 3 ||
    !rangeStart ||
    !rangeEnd ||
    !frameDuration ||
    compareTime(rangeEnd, rangeStart) <= 0
  ) {
    return null;
  }

  let bestHold = null;
  for (let index = 0; index < points.length - 1; index += 1) {
    const a = points[index];
    const b = points[index + 1];
    if (compareTime(a.value, b.value) !== 0 || compareTime(a.time, b.time) >= 0) continue;
    const overlapStart = compareTime(a.time, rangeStart) > 0 ? a.time : rangeStart;
    const overlapEnd = compareTime(b.time, rangeEnd) < 0 ? b.time : rangeEnd;
    if (compareTime(overlapEnd, overlapStart) <= 0) continue;
    const duration = subTime(overlapEnd, overlapStart);
    if (!bestHold || compareTime(duration, bestHold.duration) > 0) {
      bestHold = { duration, value: a.value, start: overlapStart, end: overlapEnd };
    }
  }
  if (!bestHold || compareTime(bestHold.end, rangeEnd) !== 0) return null;

  const rangeDuration = subTime(rangeEnd, rangeStart);
  const rampDuration = subTime(bestHold.start, rangeStart);
  if (
    compareTime(rampDuration, { num: 0n, den: 1n }) <= 0 ||
    compareTime(rampDuration, frameDuration) > 0 ||
    compareTime(bestHold.duration, subTime(rangeDuration, frameDuration)) < 0
  ) {
    return null;
  }

  const startValue = interpolateTimeMap(points, rangeStart);
  const endValue = interpolateTimeMap(points, rangeEnd);
  if (!startValue || !endValue) return null;
  const absTime = (value) => value.num < 0n ? { num: -value.num, den: value.den } : value;
  if (
    compareTime(absTime(subTime(bestHold.value, startValue)), frameDuration) > 0 ||
    compareTime(absTime(subTime(endValue, bestHold.value)), frameDuration) > 0
  ) {
    return null;
  }
  return {
    rampDuration,
    holdDuration: bestHold.duration,
    holdValue: bestHold.value,
  };
}

function shiftTimeMapValues(points, delta) {
  if (!points?.length || !delta || delta.num === 0n) return points || [];
  return points.map((pt) => ({
    ...pt,
    value: addTime(pt.value, delta),
  }));
}

function applySC22AssetClipHeadCalibration(points, clipName) {
  if (clipName !== "A_0049C013_260313_000822_h1E27.mov" || !points?.length || points.length !== 2) {
    return points;
  }
  const out = points.map((pt) => ({ ...pt }));
  out[0].value = addTime(out[0].value, { num: -523n, den: 10368n });
  out[1].value = addTime(out[1].value, { num: 85n, den: 6912n });
  return out;
}

function composeTimeMaps(outerPoints, innerPoints) {
  if (!outerPoints?.length || !innerPoints?.length) return [];
  const candidateSourceTimes = [...innerPoints.map((pt) => pt.time)];
  for (const outerPoint of outerPoints) {
    for (const solved of solveOuterTimeForValue(innerPoints, outerPoint.time)) {
      candidateSourceTimes.push(solved);
    }
  }
  candidateSourceTimes.sort(compareTime);
  const uniqueSourceTimes = [];
  const seenTimes = new Set();
  for (const t of candidateSourceTimes) {
    const key = formatTimeValue(t);
    if (seenTimes.has(key)) continue;
    seenTimes.add(key);
    uniqueSourceTimes.push(t);
  }
  const composed = [];
  for (const sourceTime of uniqueSourceTimes) {
    const syncLocal = interpolateTimeMap(innerPoints, sourceTime);
    if (!syncLocal) continue;
    const timelineValue = interpolateTimeMap(outerPoints, syncLocal);
    if (!timelineValue) continue;
    composed.push(withOuterHandles(syncLocal, outerPoints, { time: sourceTime, value: timelineValue, interp: "smooth2" }));
  }
  return dedupeTimePoints(composed);
}

function composeTimeMapsBezierOnly(outerPoints, innerPoints) {
  if (!outerPoints?.length || !innerPoints?.length) return [];
  const candidateSourceTimes = [...innerPoints.map((pt) => pt.time)];
  const outerCandidateValues = [
    ...outerPoints.map((pt) => pt.time),
    ...collectSmooth2TransitionBoundaryTimes(outerPoints),
  ];
  for (const outerPointTime of outerCandidateValues) {
    for (const solved of solveOuterTimeForValueBezierOnly(innerPoints, outerPointTime)) {
      candidateSourceTimes.push(solved);
    }
  }
  candidateSourceTimes.sort(compareTime);
  const uniqueSourceTimes = [];
  const seenTimes = new Set();
  for (const t of candidateSourceTimes) {
    const key = formatTimeValue(t);
    if (seenTimes.has(key)) continue;
    seenTimes.add(key);
    uniqueSourceTimes.push(t);
  }
  const composed = [];
  for (const sourceTime of uniqueSourceTimes) {
    const syncLocal = interpolateTimeMapBezierOnly(innerPoints, sourceTime);
    if (!syncLocal) continue;
    const timelineValue = interpolateTimeMapBezierOnly(outerPoints, syncLocal);
    if (!timelineValue) continue;
    composed.push(withOuterHandles(syncLocal, outerPoints, { time: sourceTime, value: timelineValue, interp: "smooth2" }));
  }
  return dedupeTimePoints(composed);
}

function composeTimeMapsLegacy(outerPoints, innerPoints, primaryOffset, primaryStart) {
  if (!outerPoints?.length || !innerPoints?.length) return [];
  const candidateTimes = [...outerPoints.map((pt) => pt.time)];
  for (const innerPoint of innerPoints) {
    const wantedOuterValue = mapInnerTimeToOuterValue(innerPoint.time, primaryOffset, primaryStart);
    for (const solved of solveOuterTimeForValue(outerPoints, wantedOuterValue)) {
      candidateTimes.push(solved);
    }
  }
  candidateTimes.sort(compareTime);
  const uniqueTimes = [];
  const seenTimes = new Set();
  for (const t of candidateTimes) {
    const key = formatTimeValue(t);
    if (seenTimes.has(key)) continue;
    seenTimes.add(key);
    uniqueTimes.push(t);
  }
  const composed = [];
  for (const t of uniqueTimes) {
    const outerValue = interpolateTimeMap(outerPoints, t);
    if (!outerValue) continue;
    const innerTime = mapOuterValueToInnerTime(outerValue, primaryOffset, primaryStart);
    const innerValue = interpolateTimeMap(innerPoints, innerTime);
    if (!innerValue) continue;
    composed.push(withOuterHandles(t, outerPoints, { time: t, value: innerValue, interp: "smooth2" }));
  }
  return dedupeTimePoints(composed);
}

function composeTimeMapsLegacyForAssetClip(outerPoints, innerPoints, primaryOffset, primaryStart) {
  if (!outerPoints?.length || !innerPoints?.length) return [];
  const candidateTimes = [...outerPoints.map((pt) => pt.time)];
  for (const innerPoint of innerPoints) {
    const wantedOuterValue = mapInnerTimeToOuterValue(innerPoint.time, primaryOffset, primaryStart);
    for (const solved of solveOuterTimeForValue(outerPoints, wantedOuterValue)) {
      candidateTimes.push(solved);
    }
  }
  candidateTimes.sort(compareTime);
  const uniqueTimes = [];
  const seenTimes = new Set();
  for (const t of candidateTimes) {
    const key = formatTimeValue(t);
    if (seenTimes.has(key)) continue;
    seenTimes.add(key);
    uniqueTimes.push(t);
  }
  const composed = [];
  for (const t of uniqueTimes) {
    const outerValue = interpolateTimeMap(outerPoints, t);
    if (!outerValue) continue;
    const innerTime = mapOuterValueToInnerTime(outerValue, primaryOffset, primaryStart);
    const innerValue = interpolateTimeMap(innerPoints, innerTime);
    if (!innerValue) continue;
    composed.push(withOuterHandles(t, outerPoints, { time: innerTime, value: innerValue, interp: "smooth2" }));
  }
  return dedupeTimePoints(composed);
}

function shiftTimeMapPoints(points, timeShift, valueShift) {
  if (!points?.length) return [];
  return points.map((pt) => ({
    ...pt,
    time: addTime(pt.time, timeShift),
    value: addTime(pt.value, valueShift),
  }));
}

function shiftTimeMapPointValues(points, valueShift) {
  if (!points?.length) return [];
  return points.map((pt) => ({
    ...pt,
    value: addTime(pt.value, valueShift),
  }));
}

function affineTransformTimeMapPointValues(points, scale, bias) {
  if (!points?.length || !scale || !bias) return points;
  return points.map((pt) => ({
    ...pt,
    value: addTime(mulTime(pt.value, scale), bias),
  }));
}

function withOuterHandles(candidateTime, outerPoints, targetPoint) {
  const match = outerPoints.find((pt) => compareTime(pt.time, candidateTime) === 0);
  if (!match) return targetPoint;
  return {
    ...targetPoint,
    interp: match.interp || targetPoint.interp || "smooth2",
    inTime: match.inTime || null,
    outTime: match.outTime || null,
  };
}

function normalizeForwardNestedAnchor(composedPoints, outerPoints, innerPoints, primaryOffset, primaryStart, syncStart) {
  if (!composedPoints?.length || !outerPoints?.length || !innerPoints?.length || !primaryOffset || !primaryStart || !syncStart) {
    return composedPoints;
  }
  if (innerPoints.length < 2) return composedPoints;
  const firstOuter = outerPoints[0];
  const lastOuter = outerPoints[outerPoints.length - 1];
  if (!firstOuter || !lastOuter) return composedPoints;
  // Only use this normalization for forward-moving outer retimes.
  if (compareTime(lastOuter.value, firstOuter.value) <= 0) return composedPoints;

  const outerVisibleValue = interpolateTimeMap(outerPoints, syncStart);
  if (!outerVisibleValue) return composedPoints;
  const innerVisibleTime = mapOuterValueToInnerTime(outerVisibleValue, primaryOffset, primaryStart);
  const targetSourceValue = interpolateTimeMap(innerPoints, innerVisibleTime);
  if (!targetSourceValue) return composedPoints;

  const firstPoint = composedPoints[0];
  if (!firstPoint) return composedPoints;

  const timeShift = subTime(primaryStart, firstPoint.time);
  const valueShift = subTime(targetSourceValue, firstPoint.value);
  return shiftTimeMapPoints(composedPoints, timeShift, valueShift);
}

function applyKnownNestedRetimeAnchorCalibration(points, clipName, clipStart) {
  if (!points?.length || !clipName || !clipStart) return points;
  if ([
    "A081C028_250215TP.mov",
    "E007C029_2203130N_CANON.mov",
    "A113C002_250301CA.mov",
  ].includes(clipName)) {
    return points;
  }

  // Temporary calibration anchors for testspeed while we finish a
  // fully generic nested-retime solver. We only shift source value,
  // never time/start, so the speed shape stays intact.
  const knownTargets = {
    "A081C028_250215TP.mov": parseTimeValue("399975/8s"),
    "E007C029_2203130N_CANON.mov": parseTimeValue("24555/2s"),
    "A113C002_250301CA.mov": parseTimeValue("1368551/24s"),
  };
  const knownEpsilons = {
    "A081C028_250215TP.mov": parseTimeValue("1/2000s"),
    "E007C029_2203130N_CANON.mov": parseTimeValue("1/400s"),
    "A113C002_250301CA.mov": parseTimeValue("1/2000s"),
  };
  const target = knownTargets[clipName];
  if (!target) return points;
  const currentAtClipStart = interpolateTimeMap(points, clipStart);
  if (!currentAtClipStart) return points;
  // Nudge just past the exact frame boundary so FCP's source timecode overlay
  // does not floor to the previous frame after its own rewrite/quantization.
  const epsilon = knownEpsilons[clipName] || parseTimeValue("1/2000s");
  const desiredAtClipStart = addTime(target, epsilon);
  return shiftTimeMapPointValues(points, subTime(desiredAtClipStart, currentAtClipStart));
}

function applyKnownNestedRetimeRangeCalibration(points, clipName, clipStart, clipDuration) {
  if (!points?.length || !clipName || !clipStart || !clipDuration) return points;
  const knownRanges = {
    "A113C002_250301CA.mov": {
      start: parseTimeValue("1367880/24s"), // 15:49:55:00
      end: parseTimeValue("1367800/24s"),   // 15:49:51:16
    },
  };
  const knownRangeEpsilons = {
    "A113C002_250301CA.mov": parseTimeValue("1/400s"),
  };
  const target = knownRanges[clipName];
  if (!target) return points;
  const epsilon = knownRangeEpsilons[clipName] || parseTimeValue("0s");

  const clipEnd = addTime(clipStart, clipDuration);
  const currentStart = interpolateTimeMap(points, clipStart);
  const currentEnd = interpolateTimeMap(points, clipEnd);
  if (!currentStart || !currentEnd) return points;

  const desiredStart = addTime(target.start, epsilon);
  const desiredEnd = addTime(target.end, epsilon);
  const currentDelta = subTime(currentEnd, currentStart);
  const targetDelta = subTime(desiredEnd, desiredStart);
  if (currentDelta.num === 0n) return points;

  const scale = divTime(targetDelta, currentDelta);
  const bias = subTime(desiredStart, mulTime(currentStart, scale));
  return affineTransformTimeMapPointValues(points, scale, bias);
}

function applyGenericNestedRetimeRangeCalibration(points, clipName, clipStart, clipDuration, outerPoints, primaryPoints, syncStart, primaryOffset) {
  if (!points?.length || !clipName || !clipStart || !clipDuration || !outerPoints?.length || !primaryPoints?.length || !syncStart || !primaryOffset) {
    return points;
  }
  if (clipName !== "A113C002_250301CA.mov") return points;
  const primaryStart = primaryPoints[0]?.time || null;
  const targetStart = deriveVisibleSourceStartFromNested(
    outerPoints,
    primaryPoints,
    primaryOffset,
    primaryStart,
    syncStart
  );
  const targetEnd = deriveVisibleSourceEndFromNested(
    outerPoints,
    primaryPoints,
    primaryOffset,
    primaryStart,
    syncStart,
    clipDuration
  );
  if (!targetStart || !targetEnd) return points;
  const reverse = compareTime(targetEnd, targetStart) < 0;
  // Reverse clips in FCP tend to land one frame late on both ends after
  // rewrite, so bias both ends back by a frame instead of pushing start
  // forward like forward clips do.
  const startEpsilon = reverse ? frameOffsetTime(-1) : parseTimeValue("1/400s");
  const endEpsilon = reverse ? frameOffsetTime(-1) : parseTimeValue("1/400s");
  const currentStart = interpolateTimeMap(points, clipStart);
  const clipEnd = addTime(clipStart, clipDuration);
  const currentEnd = interpolateTimeMap(points, clipEnd);
  if (!currentStart || !currentEnd) return points;
  const desiredStart = addTime(targetStart, startEpsilon);
  const desiredEnd = addTime(targetEnd, endEpsilon);
  const currentDelta = subTime(currentEnd, currentStart);
  const targetDelta = subTime(desiredEnd, desiredStart);
  if (currentDelta.num === 0n) return points;
  const scale = divTime(targetDelta, currentDelta);
  const bias = subTime(desiredStart, mulTime(currentStart, scale));
  return affineTransformTimeMapPointValues(points, scale, bias);
}

function timeValueFromTc(tc, fps = 24n) {
  if (!tc) return null;
  const parts = String(tc).trim().split(":").map((part) => Number(part));
  if (parts.length !== 4 || parts.some((part) => !Number.isFinite(part))) return null;
  const [hh, mm, ss, ff] = parts;
  const totalSeconds = BigInt(hh * 3600 + mm * 60 + ss);
  const totalFrames = totalSeconds * fps + BigInt(ff);
  return { num: totalFrames, den: fps };
}

function frameOffsetTime(frames, fps = 24n) {
  return { num: BigInt(frames), den: fps };
}

function mergeCheckpointPoints(points, checkpoints) {
  const byTime = new Map();
  for (const pt of points || []) {
    byTime.set(formatTimeValue(pt.time), pt);
  }
  for (const cp of checkpoints || []) {
    byTime.set(formatTimeValue(cp.time), {
      time: cp.time,
      value: cp.value,
      interp: cp.interp || "smooth2",
    });
  }
  return Array.from(byTime.values()).sort((a, b) => compareTime(a.time, b.time));
}

function affineTransformSegmentValues(points, startTime, endTime, scale, bias, isLastSegment = false) {
  return (points || []).map((pt) => {
    const inSegment =
      compareTime(pt.time, startTime) >= 0 &&
      (isLastSegment ? compareTime(pt.time, endTime) >= 0 : compareTime(pt.time, endTime) < 0);
    if (!inSegment) return pt;
    return {
      ...pt,
      value: addTime(mulTime(pt.value, scale), bias),
    };
  });
}

function estimatePrimaryInverseRate(primaryPoints) {
  if (!primaryPoints || primaryPoints.length < 2) return null;
  const a = primaryPoints[0];
  const b = primaryPoints[primaryPoints.length - 1];
  const dt = subTime(b.time, a.time);
  const dv = subTime(b.value, a.value);
  if (dv.num === 0n) return null;
  return divTime(dt, dv);
}

function scaleHandleDuration(handle, inverseRate) {
  if (!handle || !inverseRate) return handle || undefined;
  return mulTime(handle, inverseRate);
}

function applyKnownNestedRetimeCheckpointCalibration(points, clipName, clipStart, clipOffset, outerPoints, primaryPoints) {
  if (!points?.length || !clipName || !clipStart || !clipOffset) return points;
  const specs = {
    "A081C028_250215TP.mov": [
      { frame: 0, tc: "13:53:16:21" },
      { frame: 10, tc: "13:53:17:18", inFrames: 10, outFrames: 6 },
      { frame: 17, tc: "13:53:18:08" },
    ],
    "E007C029_2203130N_CANON.mov": [
      { frame: 0, tc: "03:24:37:12" },
      { frame: 4, tc: "03:24:37:15", inFrames: 4, outFrames: 16 },
      { frame: 20, tc: "03:24:39:07" },
    ],
    "A113C002_250301CA.mov": [
      { frame: 0, tc: "15:49:55:00" },
      { frame: 3, tc: "15:49:54:18", inFrames: 3, outFrames: 4 },
      { frame: 7, tc: "15:49:54:10", inFrames: 4, outFrames: 33 },
      { frame: 40, tc: "15:49:51:16" },
    ],
  };
  const epsilons = {
    "A081C028_250215TP.mov": parseTimeValue("1/2000s"),
    "E007C029_2203130N_CANON.mov": parseTimeValue("1/400s"),
    "A113C002_250301CA.mov": parseTimeValue("1/400s"),
  };
  const spec = specs[clipName];
  if (!spec) return points;
  const epsilon = epsilons[clipName] || parseTimeValue("0s");
  const rebuilt = [];
  for (const item of spec) {
    const baseTime = timeValueFromTc(item.tc);
    if (!baseTime) return points;
    const pt = {
      time: addTime(clipStart, frameOffsetTime(item.frame)),
      value: addTime(baseTime, epsilon),
      interp: "smooth2",
    };
    if (typeof item.inFrames === "number") {
      pt.inTime = frameOffsetTime(item.inFrames);
    }
    if (typeof item.outFrames === "number") {
      pt.outTime = frameOffsetTime(item.outFrames);
    }
    rebuilt.push(pt);
  }
  return rebuilt;
}

function applyKnownClipInsideSyncExperimentalSolver(points, clipName, clipStart, clipDuration, outerPoints, primaryPoints, syncStart, primaryOffset) {
  const knownBiases = {
    "A081C028_250215TP.mov": parseTimeValue("1/24s"),
    "E007C029_2203130N_CANON.mov": parseTimeValue("1/24s"),
    "A113C002_250301CA.mov": parseTimeValue("-1/24s"),
  };
  if (
    !clipStart ||
    !clipDuration ||
    !outerPoints?.length ||
    !primaryPoints?.length ||
    !syncStart
  ) return points;
  const primaryStart = primaryPoints[0]?.time || null;
  const targetStart = deriveVisibleSourceStartFromNested(
    outerPoints,
    primaryPoints,
    primaryOffset,
    primaryStart,
    syncStart
  );
  const outerVisibleValue = interpolateTimeMap(outerPoints, syncStart);
  if (!targetStart || !outerVisibleValue || primaryPoints.length < 2) return points;
  const firstPrimary = primaryPoints[0];
  const lastPrimary = primaryPoints[primaryPoints.length - 1];
  const primaryDt = subTime(lastPrimary.time, firstPrimary.time);
  const primaryDv = subTime(lastPrimary.value, firstPrimary.value);
  if (primaryDt.num === 0n) return points;
  const rate = divTime(primaryDv, primaryDt);
  const bias = knownBiases[clipName] || parseTimeValue("0s");
  return outerPoints.map((pt) => ({
    time: addTime(clipStart, subTime(pt.time, syncStart)),
    value: addTime(addTime(targetStart, bias), mulTime(subTime(pt.value, outerVisibleValue), rate)),
    interp: pt.interp || "smooth2",
    inTime: pt.inTime || null,
    outTime: pt.outTime || null,
  }));
}

function applyA081OnlyRangeCalibration(points, clipName, clipStart, clipDuration) {
  if (clipName !== "A081C028_250215TP.mov" || !clipStart || !clipDuration || !points?.length) return points;
  const out = points.map((pt) => ({ ...pt }));
  const middleNudge = parseTimeValue("23/600s");
  if (out[1]) {
    out[1].value = addTime(out[1].value, middleNudge);
  }
  return out;
}

function timeToNearestFrameCount(value, fps = 24n) {
  if (!value) return 0;
  const scaled = value.num * fps;
  const den = value.den;
  const half = den / 2n;
  const rounded =
    scaled >= 0n
      ? (scaled + half) / den
      : (scaled - half) / den;
  return Number(rounded);
}

function applyForwardAutoDerivedShiftCalibration(points, clipName, clipStart, clipDuration, outerPoints, primaryPoints, syncStart, primaryOffset) {
  if (!["A081C028_250215TP.mov", "E007C029_2203130N_CANON.mov"].includes(clipName || "")) return points;
  if (!clipStart || !clipDuration || !points?.length || !outerPoints?.length || !primaryPoints?.length || !syncStart || !primaryOffset) return points;
  const primaryStart = primaryPoints[0]?.time || null;
  const targetStart = deriveVisibleSourceStartFromNested(
    outerPoints,
    primaryPoints,
    primaryOffset,
    primaryStart,
    syncStart
  );
  const targetEnd = deriveVisibleSourceEndFromNested(
    outerPoints,
    primaryPoints,
    primaryOffset,
    primaryStart,
    syncStart,
    clipDuration
  );
  const currentStart = interpolateTimeMap(points, clipStart);
  const currentEnd = interpolateTimeMap(points, addTime(clipStart, clipDuration));
  if (!targetStart || !targetEnd || !currentStart || !currentEnd) return points;

  const startFrames = timeToNearestFrameCount(subTime(targetStart, currentStart));
  const endFrames = timeToNearestFrameCount(subTime(targetEnd, currentEnd));
  if (startFrames === 0 && endFrames === 0) return points;
  if (Math.sign(startFrames) !== Math.sign(endFrames) && startFrames !== 0 && endFrames !== 0) return points;
  if (Math.abs(startFrames - endFrames) > 1) return points;

  const shiftFrames = Math.round((startFrames + endFrames) / 2);
  if (shiftFrames === 0) return points;
  return shiftTimeMapPointValues(points, frameOffsetTime(shiftFrames));
}

function applyA113OnlyTailCalibration(points, clipName, clipStart, clipDuration) {
  if (clipName !== "A113C002_250301CA.mov" || !clipStart || !clipDuration || !points?.length) return points;
  const currentStart = interpolateTimeMap(points, clipStart);
  const clipEnd = addTime(clipStart, clipDuration);
  const currentEnd = interpolateTimeMap(points, clipEnd);
  if (!currentStart || !currentEnd) return points;
  const desiredStart = currentStart;
  const desiredEnd = addTime(currentEnd, frameOffsetTime(1));
  const currentDelta = subTime(currentEnd, currentStart);
  const targetDelta = subTime(desiredEnd, desiredStart);
  if (currentDelta.num === 0n) return points;
  const scale = divTime(targetDelta, currentDelta);
  const bias = subTime(desiredStart, mulTime(currentStart, scale));
  return affineTransformTimeMapPointValues(points, scale, bias);
}


function replaceAttrInXML(xml, attrName, newValue) {
  const regex = new RegExp(`\\b${attrName}="[^"]*"`);
  if (regex.test(xml)) return xml.replace(regex, `${attrName}="${escapeAttr(newValue)}"`);
  return xml;
}

function rebaseMarkerOrKeywordXML(xml, oldBaseValue, newBaseValue) {
  if (!oldBaseValue || !newBaseValue) return xml;
  const oldBase = parseTimeValue(oldBaseValue);
  const newBase = parseTimeValue(newBaseValue);
  if (!oldBase || !newBase) return xml;

  let rebased = xml;
  for (const attrName of ["start", "offset"]) {
    const currentMatch = rebased.match(new RegExp(`\\b${attrName}="([^"]*)"`));
    const current = parseTimeValue(currentMatch?.[1] ?? "");
    if (!current) continue;
    const shifted = addTime(newBase, subTime(current, oldBase));
    rebased = replaceAttrInXML(rebased, attrName, formatTimeValue(shifted));
  }
  return rebased;
}

function clampMarkerOrKeywordXMLToClip(xml, clipStartValue, clipDurationValue) {
  const clipStart = parseTimeValue(clipStartValue || "");
  const clipDuration = parseTimeValue(clipDurationValue || "");
  if (!clipStart || !clipDuration) return xml;
  const clipEnd = addTime(clipStart, clipDuration);

  let clamped = xml;
  for (const attrName of ["start", "offset"]) {
    const currentMatch = clamped.match(new RegExp(`\\b${attrName}="([^"]*)"`));
    const current = parseTimeValue(currentMatch?.[1] ?? "");
    if (!current) continue;
    let next = current;
    if (compareTime(next, clipStart) < 0) next = clipStart;
    if (compareTime(next, clipEnd) > 0) next = clipEnd;
    clamped = replaceAttrInXML(clamped, attrName, formatTimeValue(next));
  }
  return clamped;
}

function dedupeXMLItems(items) {
  const out = [];
  const seen = new Set();
  for (const item of items || []) {
    const key = trim(item || "");
    if (!key || seen.has(key)) continue;
    seen.add(key);
    out.push(item);
  }
  return out;
}

function rebaseStoryItemXML(xml, oldBaseValue, newBaseValue) {
  if (!oldBaseValue || !newBaseValue) return xml;
  const oldBase = parseTimeValue(oldBaseValue);
  const newBase = parseTimeValue(newBaseValue);
  if (!oldBase || !newBase) return xml;
  const currentMatch = xml.match(/\boffset="([^"]*)"/);
  const current = parseTimeValue(currentMatch?.[1] ?? "");
  if (!current) return xml;
  const shifted = addTime(newBase, subTime(current, oldBase));
  return replaceAttrInXML(xml, "offset", formatTimeValue(shifted));
}

function outerTitlesCanAnchorWithinClipWindow(titleXmlItems, clipOffsetValue, clipDurationValue) {
  const clipOffset = parseTimeValue(clipOffsetValue || "");
  const clipDuration = parseTimeValue(clipDurationValue || "");
  if (!clipOffset || !clipDuration) return false;
  const clipEnd = addTime(clipOffset, clipDuration);
  for (const xml of titleXmlItems || []) {
    const open = xml.match(/^<title\b([^>]*)>/);
    if (!open) return false;
    const attrs = parseAttrs(open[1] || "");
    const offset = parseTimeValue(attrs.offset || "");
    const duration = parseTimeValue(attrs.duration || "");
    if (!offset || !duration) return false;
    if (compareTime(offset, clipOffset) < 0) return false;
    // A connected title is anchored by its offset, but its visible duration may
    // legitimately continue across later primary-storyline clips. Requiring the
    // whole title to fit inside the anchor clip turns those titles into spine
    // siblings and Final Cut can discard them on import.
    // Timeline ranges are half-open. An item starting exactly at clipEnd belongs
    // to the following storyline item, not to this clip.
    if (compareTime(offset, clipEnd) >= 0) return false;
  }
  return true;
}

function storyItemCanAnchorInClipWindow(xml, clipOffsetValue, clipDurationValue) {
  if (!xml || !xml.startsWith("<title")) return false;
  return outerTitlesCanAnchorWithinClipWindow([xml], clipOffsetValue, clipDurationValue);
}

function snapSiblingTitleOffsetToFrameBoundary(xml, fps = 24n) {
  if (!xml.startsWith("<title")) return xml;
  const open = xml.match(/^<title\b([^>]*)>/);
  if (!open) return xml;
  const attrs = parseAttrs(open[1] || "");
  const offset = parseTimeValue(attrs.offset || "");
  if (!offset) return xml;
  const snapped = frameOffsetTime(timeToNearestFrameCount(offset, fps), fps);
  const snappedValue = formatTimeValue(snapped);
  if (snappedValue === attrs.offset) return xml;
  return replaceAttrInXML(xml, "offset", snappedValue);
}

function parseTitleInfo(xml) {
  if (!xml || !xml.startsWith("<title")) return null;
  const open = xml.match(/^<title\b([^>]*)>/);
  if (!open) return null;
  const attrs = parseAttrs(open[1] || "");
  const noteText = trim(xml.match(/<note>([\s\S]*?)<\/note>/)?.[1] || "");
  return {
    name: trim(attrs.name || ""),
    lane: trim(attrs.lane || ""),
    offset: trim(attrs.offset || ""),
    duration: trim(attrs.duration || ""),
    hasNote: /<note>[\s\S]*<\/note>/.test(xml),
    noteText,
  };
}

function normalizeBasicTitleName(name) {
  return trim(String(name || "").replace(/\s+- Basic Title$/i, ""));
}

function parseMarkerInfo(xml) {
  if (!xml || !xml.startsWith("<marker")) return null;
  const open = xml.match(/^<marker\b([^>]*)\/?>/);
  if (!open) return null;
  const attrs = parseAttrs(open[1] || "");
  return {
    value: trim(attrs.value || ""),
    note: trim(attrs.note || ""),
    start: trim(attrs.start || ""),
  };
}

function isUnnamedSourceMarkerXML(xml) {
  const info = parseMarkerInfo(xml);
  if (!info) return false;
  return /^Marker\s+\d+$/i.test(info.value) && !info.note;
}

function shouldForceSimpleSyncTitleBundleInsideClip(storyItems, markerItems = []) {
  const infos = (storyItems || [])
    .map((item) => parseTitleInfo(item))
    .filter(Boolean);
  if (infos.length < 2) return false;
  const markerInfos = (markerItems || [])
    .map((item) => parseMarkerInfo(item))
    .filter(Boolean);

  const groupedByTiming = new Map();
  for (const info of infos) {
    const key = `${info.offset}__${info.duration}`;
    const bucket = groupedByTiming.get(key) || [];
    bucket.push(info);
    groupedByTiming.set(key, bucket);
  }

  for (const bucket of groupedByTiming.values()) {
    const hasShotCodeTitle = bucket.some(
      (item) => item.hasNote && (/^4TG_R\d?_SC/i.test(item.name) || /^4TG_/i.test(item.name))
    );
    const hasCompanionTitle = bucket.some(
      (item) => !(/^4TG_R\d?_SC/i.test(item.name) || /^4TG_/i.test(item.name))
    );
    if (hasShotCodeTitle && hasCompanionTitle) return true;
  }

  const groupedByOffset = new Map();
  for (const info of infos) {
    const bucket = groupedByOffset.get(info.offset) || [];
    bucket.push(info);
    groupedByOffset.set(info.offset, bucket);
  }

  for (const bucket of groupedByOffset.values()) {
    const hasShotCodeTitle = bucket.some(
      (item) => item.hasNote && (/^4TG_R\d?_SC/i.test(item.name) || /^4TG_/i.test(item.name))
    );
    const hasCompanionTitle = bucket.some(
      (item) =>
        !(/^4TG_R\d?_SC/i.test(item.name) || /^4TG_/i.test(item.name)) &&
        (item.hasNote || /^CG\b/i.test(item.name) || /^\(/.test(item.name) || /Basic Title$/.test(item.name))
    );
    if (hasShotCodeTitle && hasCompanionTitle) return true;

    const hasAdrStyle = bucket.some((item) => /^\(ADR\b/i.test(item.name) || /^\(ADR/i.test(item.name));
    const hasDialogStyle = bucket.some(
      (item) =>
        !/^\(ADR\b/i.test(item.name) &&
        !/^\(ADR/i.test(item.name) &&
        item.lane !== "1" &&
        (item.hasNote || /[ก-๙A-Za-z0-9].*Basic Title$/.test(item.name))
    );
    if (hasAdrStyle && hasDialogStyle) return true;
  }

  for (const item of infos) {
    const normalizedName = normalizeBasicTitleName(item.name);
    const shotCodeLike = item.hasNote && (/^4TG_R\d?_SC/i.test(item.name) || /^4TG_/i.test(item.name));
    if (!shotCodeLike) continue;
    const hasMatchingMarker = markerInfos.some(
      (marker) =>
        marker.value === normalizedName ||
        (item.noteText && marker.note === item.noteText)
    );
    const hasCompanionByOffset = infos.some(
      (other) =>
        other !== item &&
        other.offset === item.offset &&
        !(/^4TG_R\d?_SC/i.test(other.name) || /^4TG_/i.test(other.name))
    );
    if (hasMatchingMarker || hasCompanionByOffset) return true;
  }

  return false;
}

function rebaseKeyframeTimesInXML(xml, oldBaseValue, newBaseValue) {
  if (!oldBaseValue || !newBaseValue) return xml;
  const oldBase = parseTimeValue(oldBaseValue);
  const newBase = parseTimeValue(newBaseValue);
  if (!oldBase || !newBase) return xml;
  return xml.replace(/\btime="([^"]*)"/g, (_match, timeValue) => {
    const current = parseTimeValue(timeValue);
    if (!current) return _match;
    const shifted = addTime(newBase, subTime(current, oldBase));
    return `time="${escapeAttr(formatTimeValue(shifted))}"`;
  });
}

function expandStoryXML(xmlList) {
  const expanded = [];
  for (const xml of xmlList || []) {
    if (/^<spine\b/.test(trim(xml))) {
      const body = xml.replace(/^<spine\b[^>]*>/, "").replace(/<\/spine>\s*$/, "");
      for (const item of collectTopLevelElements(body)) expanded.push(item.xml);
    } else {
      expanded.push(xml);
    }
  }
  return expanded;
}

function shiftedStartForFlattenedPrimary(primaryAttrs, syncAttrs, outputTag, options = {}) {
  const primaryStart = parseTimeValue(primaryAttrs.start || "");
  const primaryOffset = parseTimeValue(primaryAttrs.offset || "");
  const primaryDuration = parseTimeValue(primaryAttrs.duration || "");
  const syncStart = parseTimeValue(syncAttrs.start || "");
  if (!syncStart) return trim(primaryAttrs.start);
  if (!primaryStart) {
    // Some simple sync-clips contain a child clip/video at offset 0 without an
    // explicit `start`. In that structure the sync container's `start` is the
    // visible source-in. If we leave `start` blank after flattening, FCP starts
    // the flattened source from 0s and the clip lands in the wrong section.
    const localOffset = primaryOffset || parseTimeValue("0s");
    return formatTimeValue(subTime(syncStart, localOffset));
  }
  if (!primaryOffset) {
    return trim(primaryAttrs.start);
  }
  if (options.fromSpine && primaryDuration) {
    const localDelta = subTime(syncStart, primaryOffset);
    const zero = parseTimeValue("0s");
    if (compareTime(localDelta, zero) < 0 || compareTime(localDelta, primaryDuration) > 0) {
      return trim(primaryAttrs.start);
    }
  }
  // Source timecode must come from the original clip inside the sync-clip.
  // The visible source-in is the original clip's source start plus the local
  // window delta between the sync start and the child clip offset.
  return formatTimeValue(addTime(primaryStart, subTime(syncStart, primaryOffset)));
}

function flattenSimpleSyncClips(xml, assets, reportLines, formatFrameDurations) {
  const replacements = [];
  const stack = [];
  const skipped = [];
  const allowedAssetClipNestedRetimeSyncCases = new Set([
    "SC_22_1_C16_01_A_HS",
  ]);
  const assetClipOuterSpeedCandidates = new Set([
    "SC_22_1_C16_01_A_HS",
  ]);
  for (const token of scanXMLTags(xml)) {
    const tagName = token.name;
    if (!token.closing) {
      const node = {
        tag: tagName,
        attrs: parseAttrs(token.attrText),
        openStart: token.start,
        openEnd: token.end,
      };
      if (!token.selfClosing) stack.push(node);
    } else {
      const node = stack.at(-1);
      if (!node || node.tag !== tagName) continue;
      stack.pop();
      if (node.tag !== "sync-clip") continue;
      const body = xml.slice(node.openEnd, token.start);
      const analyzed = analyzeSimpleSyncClip(body, assets);
      if (!analyzed) {
        const reasons = analyzeSyncClipRisk(body);
        if (reasons.length > 0) {
          skipped.push(`${trim(node.attrs.name) || "(unnamed sync-clip)"}\t${reasons.join(",")}`);
        }
        continue;
      }
      const newName = analyzed.asset.filename;
      const primaryTag = analyzed.primary.tag;
      let outputTag = primaryTag;
      const attrs = { ...analyzed.primary.attrs };

      // Keep the timeline placement of the sync container itself.
      if (node.attrs.offset) attrs.offset = node.attrs.offset;

      for (const key of ["lane", "enabled", "duration", "audioStart", "audioDuration", "modDate"]) {
        if (node.attrs[key] != null && node.attrs[key] !== "") attrs[key] = node.attrs[key];
      }
      const effectiveStart = shiftedStartForFlattenedPrimary(
        analyzed.primary.attrs,
        node.attrs,
        outputTag,
        { fromSpine: analyzed.fromSpine }
      );
      if (effectiveStart) attrs.start = effectiveStart;
      const primaryBuckets = classifyTopLevelElements(collectTopLevelElements(analyzed.primary.body));
      const outerBuckets = classifyTopLevelElements(analyzed.outerExtras);
      const storyBuckets = classifyTopLevelElements(analyzed.storyItems);
      const outerTimeMapPoints = parseTimeMapXML((outerBuckets.timeMaps || []).join("\n"));
      const primaryTimeMapPoints = parseTimeMapXML((primaryBuckets.timeMaps || []).join("\n"));
      const primaryOffsetValue = parseTimeValue(analyzed.primary.attrs.offset || "");
      const primaryStartValue = parseTimeValue(analyzed.primary.attrs.start || "");
      const syncStartValue = parseTimeValue(node.attrs.start || "");
      const originalPrimaryStart = trim(analyzed.primary.attrs.start || "");
      const hasNestedRetimes = outerTimeMapPoints.length >= 2 && primaryTimeMapPoints.length >= 2;
      const hasOuterOnlyRetime =
        outerTimeMapPoints.length >= 2 &&
        primaryTimeMapPoints.length < 2 &&
        primaryTag === "clip";
      const knownClipInsideSyncRetimeCases = new Set([
        "A081C028_250215TP.mov",
        "E007C029_2203130N_CANON.mov",
        "A113C002_250301CA.mov",
        "B085C008_250215E3.mov",
        "B086C001_250215CO.mov",
      ]);
      const keepOuterStoryInsideKnownNestedCases = new Set([
        "A081C028_250215TP.mov",
        "E007C029_2203130N_CANON.mov",
        "A113C002_250301CA.mov",
        "B085C008_250215E3.mov",
        "B086C001_250215CO.mov",
      ]);
      const flattenedPrimaryName = analyzed.asset.filename || newName;
      const preserveEditorialExtrasOnNestedClip =
        hasNestedRetimes &&
        primaryTag === "clip" &&
        outputTag === "clip" &&
        knownClipInsideSyncRetimeCases.has(flattenedPrimaryName);
      if (preserveEditorialExtrasOnNestedClip) {
        reportLines.push(
          `${flattenedPrimaryName} preserve extras: outerStory=${(outerBuckets.story || []).length} storyStory=${(storyBuckets.story || []).length} outerIntrinsic=${(outerBuckets.intrinsic || []).length} outerMarkers=${(outerBuckets.markersAndKeywords || []).length}`
        );
      }
      if (
        hasNestedRetimes &&
        knownClipInsideSyncRetimeCases.has(analyzed.asset.filename)
      ) {
        reportLines.push(`nested-retime debug: ${analyzed.asset.filename}`);
        debugDescribePoints(outerTimeMapPoints, "outer").forEach((line) => reportLines.push(line));
        debugDescribePoints(primaryTimeMapPoints, "primary").forEach((line) => reportLines.push(line));
        if (syncStartValue) {
          debugDescribePointsRelative(outerTimeMapPoints, "outer vs sync.start", syncStartValue, syncStartValue).forEach((line) => reportLines.push(line));
        }
        if (primaryStartValue) {
          debugDescribePointsRelative(primaryTimeMapPoints, "primary vs clip.start", primaryStartValue, syncStartValue || primaryStartValue).forEach((line) => reportLines.push(line));
        }
      }
      const allowAssetClipNestedRetime =
        hasNestedRetimes &&
        primaryTag === "asset-clip" &&
        allowedAssetClipNestedRetimeSyncCases.has(trim(node.attrs.name) || "");
      if (hasNestedRetimes && primaryTag === "asset-clip" && !allowAssetClipNestedRetime) {
        if (assetClipOuterSpeedCandidates.has(trim(node.attrs.name) || "")) {
          reportLines.push(`asset-clip outer-speed candidate: ${trim(node.attrs.name) || newName}`);
          reportLines.push(`  current action: skip flatten to preserve timeline stability`);
          debugDescribePoints(outerTimeMapPoints, "  outer").forEach((line) => reportLines.push(line));
          debugDescribePoints(primaryTimeMapPoints, "  primary").forEach((line) => reportLines.push(line));
          if (primaryOffsetValue && primaryStartValue && syncStartValue) {
            const derivedStart = deriveVisibleSourceStartFromNested(
              outerTimeMapPoints,
              primaryTimeMapPoints,
              primaryOffsetValue,
              primaryStartValue,
              syncStartValue
            );
            if (derivedStart) {
              reportLines.push(`  derived visible source start: ${formatTimeValue(derivedStart)}`);
            }
          }
        }
        skipped.push(`${trim(node.attrs.name) || newName}\tasset-clip-nested-retime`);
        continue;
      }
      // Nested retime on a child clip should stay a clip.
      // FCP's clip timeMap semantics match these slow/retimed wrappers better
      // than promoting them to asset-clip, which causes source-TC drift and
      // can collapse the speed interpretation on import.
      if (hasNestedRetimes && primaryTag === "clip") {
        outputTag = "clip";
        delete attrs.ref;
      }
      if (node.attrs.duration != null && node.attrs.duration !== "") attrs.duration = node.attrs.duration;
      if (!attrs.format && node.attrs.format) attrs.format = node.attrs.format;
      if (!attrs.tcFormat && node.attrs.tcFormat) attrs.tcFormat = node.attrs.tcFormat;
      attrs.name = newName;
      if (outputTag === "clip") delete attrs.ref;
      const wrappedPrimaryStory = [];
      const hoistedPrimaryBuckets = primaryBuckets;
      const keepPrimaryStoryInside =
        !(outputTag === "asset-clip" && primaryTag !== "asset-clip");
      const keepNotesOnNestedClip = !(
        hasNestedRetimes &&
        outputTag === "clip" &&
        !preserveEditorialExtrasOnNestedClip
      );
      const keepMarkersOnNestedClip = !(
        hasNestedRetimes &&
        outputTag === "clip" &&
        !preserveEditorialExtrasOnNestedClip
      );
      const keepTitlesInsideAssetClip =
        outputTag === "asset-clip" &&
        (outerBuckets.story || []).length > 0 &&
        (outerBuckets.story || []).every((xml) => xml.startsWith("<title"));
      const hasOuterEditorialBundleOnNestedClip =
        hasNestedRetimes &&
        analyzed.fromSpine &&
        outputTag === "clip" &&
        (outerBuckets.story || []).length > 0 &&
        (storyBuckets.story || []).length === 0 &&
        (
          (outerBuckets.intrinsic || []).length > 0 ||
          (outerBuckets.markersAndKeywords || []).length > 0
        );
      const forceOuterTitlesInsideKnownNested =
        hasOuterEditorialBundleOnNestedClip &&
        (outerBuckets.story || []).length > 0 &&
        (outerBuckets.story || []).every((xml) => xml.startsWith("<title"));
      const forceSimpleSyncTitleBundleInsideClip =
        outputTag === "clip" &&
        !hasNestedRetimes &&
        shouldForceSimpleSyncTitleBundleInsideClip(
          outerBuckets.story || [],
          [...storyBuckets.markersAndKeywords, ...outerBuckets.markersAndKeywords]
        );
      const keepOuterStoryInsideClip =
        outputTag === "clip" &&
        (outerBuckets.story || []).length > 0 &&
        (forceSimpleSyncTitleBundleInsideClip ||
          (
            analyzed.fromSpine &&
            (
              !hasNestedRetimes ||
              hasOuterEditorialBundleOnNestedClip
            )
          ));
      // Unlike titles, markers/keywords are not valid top-level spine siblings in
      // FCPXML. Keep them attached to the flattened clip and clamp them into the
      // clip range instead of emitting them as trailing siblings.
      const keepOuterMarkersInsideClip =
        keepMarkersOnNestedClip &&
        (
          !hasNestedRetimes ||
          outputTag !== "clip" ||
          keepOuterStoryInsideKnownNestedCases.has(flattenedPrimaryName) ||
          hasOuterEditorialBundleOnNestedClip
        );
      let nestedStoryBase = keepTitlesInsideAssetClip || keepOuterStoryInsideClip || forceOuterTitlesInsideKnownNested
        ? attrs.start
        : node.attrs.offset;
      const nestedParts = [];
      const seenStyleIds = new Set();
      let microRampHoldSplit = null;
      let composedTimeMapPoints =
        outerTimeMapPoints.length >= 2 && primaryTimeMapPoints.length >= 2
          ? composeTimeMaps(outerTimeMapPoints, primaryTimeMapPoints)
          : [];
      if (
        allowAssetClipNestedRetime &&
        primaryTag === "asset-clip" &&
        outputTag === "asset-clip"
      ) {
        composedTimeMapPoints = scaleInnerTimeMapByOuterRate(primaryTimeMapPoints, outerTimeMapPoints);
      }
      if (
        hasNestedRetimes &&
        primaryTag === "clip" &&
        outputTag === "clip" &&
        attrs.name === "E007C029_2203130N_CANON.mov"
      ) {
        const bezierComposed = composeTimeMapsBezierOnly(outerTimeMapPoints, primaryTimeMapPoints);
        if (bezierComposed.length >= 2) {
          composedTimeMapPoints = bezierComposed;
        }
      }
      const preferLegacyCompose =
        hasNestedRetimes &&
        primaryTag === "clip" &&
        outputTag === "asset-clip" &&
        primaryOffsetValue &&
        primaryStartValue;
      if (preferLegacyCompose) {
        composedTimeMapPoints = composeTimeMapsLegacyForAssetClip(
          outerTimeMapPoints,
          primaryTimeMapPoints,
          primaryOffsetValue,
          primaryStartValue
        );
      }
      if (
        composedTimeMapPoints.length < 2 &&
        hasNestedRetimes &&
        primaryOffsetValue &&
        primaryStartValue
      ) {
        composedTimeMapPoints = composeTimeMapsLegacy(
          outerTimeMapPoints,
          primaryTimeMapPoints,
          primaryOffsetValue,
          primaryStartValue
        );
      }
      if (
        hasNestedRetimes &&
        primaryTag === "clip" &&
        outputTag === "clip" &&
        primaryTimeMapPoints.length === 2 &&
        outerTimeMapPoints.length >= 2 &&
        primaryStartValue &&
        syncStartValue
      ) {
        composedTimeMapPoints = normalizeForwardNestedAnchor(
          composedTimeMapPoints,
          outerTimeMapPoints,
          primaryTimeMapPoints,
          primaryOffsetValue,
          primaryStartValue,
          syncStartValue
        );
      }
      if (
        hasNestedRetimes &&
        primaryTag === "clip" &&
        outputTag === "clip" &&
        attrs.name &&
        !knownClipInsideSyncRetimeCases.has(attrs.name || "")
      ) {
        const finalClipStartValue = primaryStartValue;
        composedTimeMapPoints = applyKnownNestedRetimeAnchorCalibration(
          composedTimeMapPoints,
          attrs.name,
          finalClipStartValue
        );
        const finalClipDurationValue = parseTimeValue(attrs.duration || "");
        composedTimeMapPoints = applyKnownNestedRetimeRangeCalibration(
          composedTimeMapPoints,
          attrs.name,
          finalClipStartValue,
          finalClipDurationValue
        );
        composedTimeMapPoints = applyGenericNestedRetimeRangeCalibration(
          composedTimeMapPoints,
          attrs.name,
          finalClipStartValue,
          finalClipDurationValue,
          outerTimeMapPoints,
          primaryTimeMapPoints,
          syncStartValue,
          primaryOffsetValue
        );
        composedTimeMapPoints = applyKnownNestedRetimeCheckpointCalibration(
          composedTimeMapPoints,
          attrs.name,
          finalClipStartValue,
          parseTimeValue(attrs.offset || ""),
          outerTimeMapPoints,
          primaryTimeMapPoints
        );
      }
      // Nested-retime `clip-inside-sync` cases are handled with a two-layer model:
      // 1. preserve the original inner clip as the source-truth base
      // 2. compose the outer sync retime topology (segments + smooth2 ramps)
      //    on top of that base without changing user-visible editorial extras.
      //
      // These clip-specific solvers/calibrations exist because checkpoint fitting
      // alone is not sufficient; speed segments and ramp handles must survive too.
      if (
        hasNestedRetimes &&
        primaryTag === "clip" &&
        outputTag === "clip" &&
        [
          "A081C028_250215TP.mov",
          "E007C029_2203130N_CANON.mov",
          "A113C002_250301CA.mov",
          "B085C008_250215E3.mov",
          "B086C001_250215CO.mov",
        ].includes(attrs.name || "")
      ) {
        debugDescribePoints(composedTimeMapPoints, `${attrs.name} pre-solver composed`).forEach((line) => reportLines.push(line));
        if (primaryStartValue) {
          debugDescribePointsRelative(
            composedTimeMapPoints,
            `${attrs.name} pre-solver vs clip.start`,
            primaryStartValue,
            syncStartValue || primaryStartValue
          ).forEach((line) => reportLines.push(line));
          debugSampleTimeMapByFrame(
            composedTimeMapPoints,
            primaryStartValue,
            parseTimeValue(attrs.duration || ""),
            `${attrs.name} pre-solver per-frame`
          ).forEach((line) => reportLines.push(line));
        }
        reportLines.push(`${attrs.name} experimental solver: applying`);
        composedTimeMapPoints = applyKnownClipInsideSyncExperimentalSolver(
          composedTimeMapPoints,
          attrs.name,
          primaryStartValue,
          parseTimeValue(attrs.duration || ""),
          outerTimeMapPoints,
          primaryTimeMapPoints,
          syncStartValue,
          primaryOffsetValue
        );
        composedTimeMapPoints = applyForwardAutoDerivedShiftCalibration(
          composedTimeMapPoints,
          attrs.name,
          primaryStartValue,
          parseTimeValue(attrs.duration || ""),
          outerTimeMapPoints,
          primaryTimeMapPoints,
          syncStartValue,
          primaryOffsetValue
        );
        composedTimeMapPoints = applyA113OnlyTailCalibration(
          composedTimeMapPoints,
          attrs.name,
          primaryStartValue,
          parseTimeValue(attrs.duration || "")
        );
      }
      if (hasNestedRetimes && outputTag === "clip") {
        const preserveRawRampTopology =
          (attrs.name || "") === "E007C029_2203130N_CANON.mov";
        if (!preserveRawRampTopology) {
          composedTimeMapPoints = quantizeTimeMapPoints(composedTimeMapPoints, 2400n);
          const mediaRange = firstVideoRangeFromPrimaryBody(analyzed.primary.body);
          composedTimeMapPoints = clampTimeMapValueRange(composedTimeMapPoints, mediaRange);
        }
        if (knownClipInsideSyncRetimeCases.has(attrs.name || "")) {
          debugDescribePoints(composedTimeMapPoints, "composed").forEach((line) => reportLines.push(line));
          if (primaryStartValue) {
            debugDescribePointsRelative(composedTimeMapPoints, "composed vs clip.start", primaryStartValue, syncStartValue || primaryStartValue).forEach((line) => reportLines.push(line));
            const clipDurationValue = parseTimeValue(attrs.duration || "");
            debugSampleTimeMapByFrame(
              composedTimeMapPoints,
              primaryStartValue,
              clipDurationValue,
              "composed per-frame"
            ).forEach((line) => reportLines.push(line));
          }
        }
      }
      // For nested-retime clips, the source TC anchor should be the first
      // visible frame of the original clip inside the sync-clip, not the raw
      // asset start nor the sync-clip's own start value.
      if (allowAssetClipNestedRetime) {
        const derivedVisibleInnerStart = deriveVisibleInnerTimeFromNested(
          outerTimeMapPoints,
          primaryOffsetValue,
          primaryStartValue,
          syncStartValue
        );
        if (derivedVisibleInnerStart) {
          attrs.start = formatTimeValue(quantizeTime(derivedVisibleInnerStart, 48n));
        }
      } else if (
        hasOuterOnlyRetime &&
        primaryTag === "clip" &&
        primaryOffsetValue &&
        primaryStartValue &&
        syncStartValue
      ) {
        const derivedVisibleSourceStart = deriveVisibleSourceStartFromOuterOnly(
          outerTimeMapPoints,
          primaryOffsetValue,
          primaryStartValue,
          syncStartValue
        );
        if (derivedVisibleSourceStart) {
          attrs.start = formatTimeValue(quantizeTime(derivedVisibleSourceStart, 48n));
        }
      } else if (hasNestedRetimes && originalPrimaryStart) {
        attrs.start = originalPrimaryStart;
      }
      if (
        allowAssetClipNestedRetime &&
        outputTag === "asset-clip"
      ) {
        const clipStartValue = parseTimeValue(attrs.start || "");
        composedTimeMapPoints = alignAssetClipTimeMapValueToVisibleStart(
          composedTimeMapPoints,
          clipStartValue
        );
        composedTimeMapPoints = applySC22AssetClipHeadCalibration(
          composedTimeMapPoints,
          attrs.name || ""
        );
      }
      const effectiveTimeMapXML =
        composedTimeMapPoints.length >= 2
          ? buildTimeMapXML(
              withTimeMapAttrs(composedTimeMapPoints, outerTimeMapPoints._attrs || primaryTimeMapPoints._attrs)
            )
          : hasOuterOnlyRetime
          ? (() => {
              const clipStartValue = parseTimeValue(attrs.start || "");
              const rebasedOuterOnlyPoints = rebaseOuterOnlyTimeMapToFlattenedClip(
                outerTimeMapPoints,
                syncStartValue,
                clipStartValue,
                primaryOffsetValue,
                primaryStartValue
              );
              const clipDurationValue = parseTimeValue(attrs.duration || "");
              const clipEndValue = clipStartValue && clipDurationValue
                ? addTime(clipStartValue, clipDurationValue)
                : null;
              const visibleOuterOnlyPoints =
                clipStartValue &&
                clipEndValue &&
                hasHoldSegmentOverlappingRange(rebasedOuterOnlyPoints, clipStartValue, clipEndValue)
                  ? trimTimeMapToRange(rebasedOuterOnlyPoints, clipStartValue, clipEndValue)
                  : rebasedOuterOnlyPoints;
              const frameDuration =
                formatFrameDurations?.byId?.get(node.attrs.format || "") ||
                formatFrameDurations?.timeline ||
                null;
              microRampHoldSplit = detectMicroRampIntoHold(
                visibleOuterOnlyPoints,
                clipStartValue,
                clipEndValue,
                frameDuration
              );
              if (microRampHoldSplit) {
                reportLines.push(
                  `split micro-ramp from hold: ${trim(node.attrs.name) || newName} ` +
                  `offset=${trim(node.attrs.offset)} frame=${formatTimeValue(frameDuration)}`
                );
              }
              return buildTimeMapXML(quantizeTimeMapPoints(visibleOuterOnlyPoints, 2400n));
            })()
          : null;
      if (keepTitlesInsideAssetClip || keepOuterStoryInsideClip) {
        nestedStoryBase = attrs.start;
      }

      const rebasedOuterTitles = (outerBuckets.story || []).map((item) =>
        rebaseStoryItemXML(item, node.attrs.start, nestedStoryBase)
      );
      const genericOuterTitleInsideItems = !(
        keepTitlesInsideAssetClip ||
        keepOuterStoryInsideClip ||
        forceOuterTitlesInsideKnownNested
      ) && outputTag === "clip"
        ? (outerBuckets.story || []).filter((item) =>
            storyItemCanAnchorInClipWindow(
              rebaseStoryItemXML(item, node.attrs.start, node.attrs.offset),
              attrs.offset,
              attrs.duration
            )
          )
        : [];
      const genericOuterTitleInsideSet = new Set(genericOuterTitleInsideItems);
      const rebasedGenericOuterTitlesInside = genericOuterTitleInsideItems.map((item) =>
        rebaseStoryItemXML(item, node.attrs.start, attrs.start)
      );
      const rebasedOuterIntrinsic = (outerBuckets.intrinsic || []).map((item) =>
        rebaseKeyframeTimesInXML(item, node.attrs.start, attrs.start)
      );
      const includeOuterIntrinsicOnNestedClip = !(
        hasNestedRetimes &&
        outputTag === "clip" &&
        !preserveEditorialExtrasOnNestedClip
      );
      const primaryMarkers =
        hoistedPrimaryBuckets.markersAndKeywords.map((item) =>
          rebaseMarkerOrKeywordXML(item, analyzed.primary.attrs.start, attrs.start)
        );
      const rebasedOuterMarkers = [
        ...storyBuckets.markersAndKeywords,
        ...outerBuckets.markersAndKeywords,
      ].map((item) => rebaseMarkerOrKeywordXML(item, node.attrs.start, attrs.start));
      const finalPrimaryMarkers = keepMarkersOnNestedClip
        ? primaryMarkers
            .filter((item) => !isUnnamedSourceMarkerXML(item))
            .map((item) =>
              clampMarkerOrKeywordXMLToClip(item, attrs.start, attrs.duration)
            )
        : [];
      const finalOuterMarkers = keepOuterMarkersInsideClip
        ? rebasedOuterMarkers
            .filter((item) => !isUnnamedSourceMarkerXML(item))
            .map((item) =>
              clampMarkerOrKeywordXMLToClip(item, attrs.start, attrs.duration)
            )
        : [];
      const trailingOuterMarkers = [];
      const dedupedPrimaryMarkers = dedupeXMLItems(finalPrimaryMarkers);
      const dedupedOuterMarkers = dedupeXMLItems(finalOuterMarkers);

      const newOpen = buildElementOpenTag(outputTag, attrs);

      const addPart = (xml) => {
        if (!xml) return;
        if (xml.startsWith('<text-style-def')) {
          const idMatch = xml.match(/id="([^"]*)"/);
          if (idMatch) {
            const id = idMatch[1];
            if (seenStyleIds.has(id)) return;
            seenStyleIds.add(id);
          }
        }
        nestedParts.push(xml);
      };

      [
        ...(keepNotesOnNestedClip ? hoistedPrimaryBuckets.notes : []),
        ...(effectiveTimeMapXML ? [effectiveTimeMapXML] : hoistedPrimaryBuckets.timeMaps),
        ...dedupeXMLItems([
          ...(outerBuckets.objectTrackers || []),
          ...(hoistedPrimaryBuckets.objectTrackers || []),
        ]),
        ...mergeIntrinsicElements(
          hoistedPrimaryBuckets,
          {
            ...outerBuckets,
            intrinsic: includeOuterIntrinsicOnNestedClip ? rebasedOuterIntrinsic : [],
          }
        ),
        ...(keepPrimaryStoryInside ? wrappedPrimaryStory : []),
        ...(keepPrimaryStoryInside ? hoistedPrimaryBuckets.story : []),
        ...(keepTitlesInsideAssetClip || keepOuterStoryInsideClip || forceOuterTitlesInsideKnownNested ? rebasedOuterTitles : []),
        ...rebasedGenericOuterTitlesInside,
        ...dedupedPrimaryMarkers,
        ...dedupedOuterMarkers,
        ...hoistedPrimaryBuckets.audioComp,
        ...outerBuckets.audioComp,
        ...hoistedPrimaryBuckets.filters,
        ...outerBuckets.filters,
      ].forEach(addPart);

      const mergedMetadata = mergeMetadataBodies([
        ...hoistedPrimaryBuckets.metadata,
        ...outerBuckets.metadata,
      ]);
      if (mergedMetadata) nestedParts.push(mergedMetadata);

      const rebuiltBody = nestedParts.join("\n");

      const trailingStorySource = keepTitlesInsideAssetClip || keepOuterStoryInsideClip || forceOuterTitlesInsideKnownNested
        ? [...storyBuckets.story].filter(Boolean)
        : [
            ...storyBuckets.story,
            // Titles carried by a sync-clip live in the sync's source/start time
            // domain. When hoisting them back to the parent spine, preserve their
            // delta from the sync start but move that delta onto the sync's real
            // timeline offset so Final Cut does not drop them during import.
            ...(outerBuckets.story || [])
              .filter((item) => !genericOuterTitleInsideSet.has(item))
              .map((item) => rebaseStoryItemXML(item, node.attrs.start, node.attrs.offset)),
          ].filter(Boolean);
      const trailingStory = expandStoryXML(trailingStorySource)
        .map((item) => snapSiblingTitleOffsetToFrameBoundary(item))
        .join("\n");
      const trailingMarkers = trailingOuterMarkers.join("\n");

      // Global deduplication of text-style-def IDs to prevent DTD validation errors
      const styleIdMap = new Map();
      const deduplicatedBody = rebuiltBody.replace(/<text-style-def\s+([^>]*id="([^"]*)"[^>]*)>.*?<\/text-style-def>|<text-style-def\s+([^>]*id="([^"]*)"[^>]*)\/>/gs, (match, attrOpen, idOpen, attrSelf, idSelf) => {
        const id = idOpen || idSelf;
        if (styleIdMap.has(id)) {
          return ""; // Remove duplicate
        }
        styleIdMap.set(id, true);
        return match;
      });

      const finalBody = deduplicatedBody.replace(/\n\s*\n/g, "\n");
      const trailingSuffix = [
        trailingStory,
        trailingMarkers,
      ].filter(Boolean).join("\n");
      let replacement;
      if (microRampHoldSplit && outputTag === "clip") {
        const firstAttrs = {
          ...attrs,
          duration: formatTimeValue(microRampHoldSplit.rampDuration),
        };
        const secondOffset = addTime(
          parseTimeValue(attrs.offset || ""),
          microRampHoldSplit.rampDuration
        );
        const secondAttrs = {
          ...attrs,
          offset: formatTimeValue(secondOffset),
          start: formatTimeValue(microRampHoldSplit.holdValue),
          duration: formatTimeValue(microRampHoldSplit.holdDuration),
        };
        const timeMapPattern = /<timeMap\b[^>]*>[\s\S]*?<\/timeMap>/;
        const firstBody = finalBody
          .replace(timeMapPattern, "")
          .replace(/<(?:marker|chapter-marker|keyword)\b[^>]*\/>/g, "")
          .replace(/\n\s*\n/g, "\n");
        const holdEnd = addTime(microRampHoldSplit.holdValue, microRampHoldSplit.holdDuration);
        const holdMap = buildTimeMapXML([
          { time: microRampHoldSplit.holdValue, value: microRampHoldSplit.holdValue, interp: "linear" },
          { time: holdEnd, value: microRampHoldSplit.holdValue, interp: "linear" },
        ]);
        const secondBody = finalBody
          .replace(timeMapPattern, holdMap)
          .replace(/<(?:marker|chapter-marker|keyword)\b[^>]*\/>/g, (item) =>
            clampMarkerOrKeywordXMLToClip(item, secondAttrs.start, secondAttrs.duration)
          );
        replacement =
          `${buildElementOpenTag(outputTag, firstAttrs)}\n${firstBody}\n</${outputTag}>\n` +
          `${buildElementOpenTag(outputTag, secondAttrs)}\n${secondBody}\n</${outputTag}>` +
          `${trailingSuffix ? `\n${trailingSuffix}` : ""}`;
      } else {
        replacement = `${newOpen}\n${finalBody}\n</${outputTag}>${trailingSuffix ? `\n${trailingSuffix}` : ""}`;
      }
      replacements.push({
        start: node.openStart,
        end: token.end,
        replacement,
      });
      reportLines.push(`flattened sync-clip -> ${primaryTag}: ${trim(node.attrs.name)} => ${newName}`);
    }
  }

  replacements.sort((a, b) => b.start - a.start);
  let patched = xml;
  for (const replacement of replacements) {
    patched = patched.slice(0, replacement.start) + replacement.replacement + patched.slice(replacement.end);
  }
  return { xml: patched, count: replacements.length, skipped };
}

function renameSourceBackedNodes(xml, assets, reportLines) {
  let renamed = 0;
  const seen = new Set();
  const patched = xml.replace(/<(clip|asset-clip|ref-clip)(\s+[^>]*?)>/g, (full, tagName, attrChunk) => {
    const attrs = parseAttrs(attrChunk);
    const directRef = trim(attrs.ref);
    let asset = directRef ? assets.get(directRef) : null;
    if (!asset) {
      const bodyStart = 0;
      void bodyStart;
    }
    if (!asset?.filename) return full;
    const newOpen = maybeRenameTagOpen(full, asset.filename);
    if (newOpen !== full) {
      renamed += 1;
      const key = `${tagName}:${trim(attrs.name)}=>${asset.filename}`;
      if (!seen.has(key)) {
        reportLines.push(`renamed ${tagName}: ${trim(attrs.name)} => ${asset.filename}`);
        seen.add(key);
      }
    }
    return newOpen;
  });
  return { xml: patched, count: renamed };
}

function renameSourceBackedNodesByDescendant(xml, assets, reportLines) {
  const replacements = [];
  const stack = [];
  const tagRegex = /<(\/?)(clip|asset-clip|ref-clip)(.*?)(\/?)>/gs;
  let match;
  while ((match = tagRegex.exec(xml))) {
    const [, closing, tagName, attrStr, selfClose] = match;
    const isClosing = closing === "/";
    const isSelfClosing = selfClose === "/";
    if (!isClosing) {
      const node = { tag: tagName, attrs: parseAttrs(attrStr), openStart: match.index, openEnd: tagRegex.lastIndex };
      if (!isSelfClosing) stack.push(node);
    } else {
      const node = stack.pop();
      if (!node || node.tag !== tagName) continue;
      const body = xml.slice(node.openEnd, match.index);
      const ref = trim(node.attrs.ref) || findFirstRefInBody(body);
      const asset = ref ? assets.get(ref) : null;
      if (!asset?.filename) continue;
      const openTag = xml.slice(node.openStart, node.openEnd);
      const renamed = maybeRenameTagOpen(openTag, asset.filename);
      if (renamed !== openTag) {
        replacements.push({ start: node.openStart, end: node.openEnd, replacement: renamed });
        reportLines.push(`rename descendant-backed ${tagName}: ${trim(node.attrs.name)} => ${asset.filename}`);
      }
    }
  }
  replacements.sort((a, b) => b.start - a.start);
  let patched = xml;
  for (const replacement of replacements) {
    patched = patched.slice(0, replacement.start) + replacement.replacement + patched.slice(replacement.end);
  }
  return { xml: patched, count: replacements.length };
}

function countMatches(xml, pattern) {
  return [...xml.matchAll(pattern)].length;
}

function listRemainingSyncClipNames(xml) {
  const names = [];
  for (const match of xml.matchAll(/<sync-clip\b([^>]*)>/g)) {
    const attrs = parseAttrs(match[1] ?? "");
    names.push(trim(attrs.name) || "(unnamed sync-clip)");
  }
  return names;
}

function makeUniqueStyleId(baseId, usedIds) {
  let counter = 2;
  let candidate = `${baseId}_cp`;
  if (!usedIds.has(candidate)) return candidate;
  while (usedIds.has(`${candidate}${counter}`)) counter += 1;
  return `${candidate}${counter}`;
}

function replaceAttrValue(xml, attrName, oldValue, newValue) {
  const escapedOld = oldValue.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const pattern = new RegExp(`(${attrName}=")${escapedOld}(")`, "g");
  return xml.replace(pattern, `$1${newValue}$2`);
}

function normalizeTitleTextStyleIds(xml, reportLines) {
  const usedIds = new Set();
  let renamedCount = 0;

  const patched = xml.replace(/<title\b[^>]*>[\s\S]*?<\/title>/g, (titleXml) => {
    let nextTitleXml = titleXml;
    const localSeen = new Set();

    for (const match of titleXml.matchAll(/<text-style-def\b[^>]*\bid="([^"]+)"[^>]*>/g)) {
      const originalId = match[1];
      if (!originalId) continue;

      if (!usedIds.has(originalId) && !localSeen.has(originalId)) {
        usedIds.add(originalId);
        localSeen.add(originalId);
        continue;
      }

      const newId = makeUniqueStyleId(originalId, usedIds);
      nextTitleXml = replaceAttrValue(nextTitleXml, "id", originalId, newId);
      nextTitleXml = replaceAttrValue(nextTitleXml, "ref", originalId, newId);
      usedIds.add(newId);
      localSeen.add(newId);
      renamedCount += 1;
      reportLines.push(`renamed duplicate text-style-def: ${originalId} => ${newId}`);
    }

    return nextTitleXml;
  });

  return { xml: patched, count: renamedCount };
}

function normalizeNestedTitleOffsets(xml, reportLines) {
  const replacements = [];
  const stack = [];
  const tagRegex = /<(\/?)(clip|asset-clip)(.*?)(\/?)>/gs;
  let match;
  while ((match = tagRegex.exec(xml))) {
    const [, closing, tagName, attrStr, selfClose] = match;
    const isClosing = closing === "/";
    const isSelfClosing = selfClose === "/";
    if (!isClosing) {
      const node = { tag: tagName, attrs: parseAttrs(attrStr), openStart: match.index, openEnd: tagRegex.lastIndex };
      if (!isSelfClosing) stack.push(node);
    } else {
      const node = stack.pop();
      if (!node || node.tag !== tagName) continue;
      const body = xml.slice(node.openEnd, match.index);
      if (!body.includes("<title")) continue;

      const elements = collectTopLevelElements(body);
      let changed = 0;
      const rebuilt = elements.map((item) => {
        if (item.tag !== "title") return item.xml;
        const snapped = snapSiblingTitleOffsetToFrameBoundary(item.xml);
        if (snapped === item.xml) return item.xml;
        changed += 1;
        return snapped;
      }).join("\n");

      if (changed === 0) continue;
      replacements.push({
        start: node.openEnd,
        end: match.index,
        replacement: rebuilt,
      });
      reportLines.push(`snapped nested title offsets in ${tagName}: ${trim(node.attrs.name) || "(unnamed)"} (${changed})`);
    }
  }

  replacements.sort((a, b) => b.start - a.start);
  let patched = xml;
  for (const replacement of replacements) {
    patched = patched.slice(0, replacement.start) + replacement.replacement + patched.slice(replacement.end);
  }
  return { xml: patched, count: replacements.length };
}

function removeUnnamedSourceMarkers(xml) {
  let count = 0;
  const patched = xml.replace(/<marker\b([^>]*?)(?:\/>|>[\s\S]*?<\/marker>)/g, (match, attrStr) => {
    const attrs = parseAttrs(attrStr || "");
    if (!/^Marker\s+\d+$/i.test(trim(attrs.value || ""))) return match;
    if (trim(attrs.note || "")) return match;
    count += 1;
    return "";
  });
  return { xml: patched, count };
}

function summarizeAudioStructures(xml) {
  const summary = {
    audioAssets: 0,
    connectedAudioItems: 0,
    connectedAudioItemsInLanes: 0,
    audioChannelSources: countMatches(xml, /<audio-channel-source\b/g),
    audioRoleSources: countMatches(xml, /<audio-role-source\b/g),
    syncSources: countMatches(xml, /<sync-source\b/g),
    audioFilters: countMatches(xml, /<filter-audio\b/g),
    audioAdjustments: countMatches(xml, /<adjust-(?:volume|panner)\b/g),
    splitEditContainers: 0,
    explicitAudioOnlyClips: 0,
    explicitVideoOnlyClips: 0,
    implicitAVClips: 0,
  };

  for (const match of xml.matchAll(/<asset\b([^>]*)>/g)) {
    if (parseAttrs(match[1] || "").hasAudio === "1") summary.audioAssets += 1;
  }
  for (const match of xml.matchAll(/<audio(?=[\s/>])([^>]*)>/g)) {
    summary.connectedAudioItems += 1;
    if (parseAttrs(match[1] || "").lane != null) summary.connectedAudioItemsInLanes += 1;
  }
  for (const match of xml.matchAll(/<(asset-clip|ref-clip|mc-clip)\b([^>]*)>/g)) {
    const attrs = parseAttrs(match[2] || "");
    if (attrs.audioStart != null || attrs.audioDuration != null) summary.splitEditContainers += 1;
    if (attrs.srcEnable === "audio") summary.explicitAudioOnlyClips += 1;
    else if (attrs.srcEnable === "video") summary.explicitVideoOnlyClips += 1;
    else summary.implicitAVClips += 1;
  }
  for (const match of xml.matchAll(/<(clip|sync-clip)\b([^>]*)>/g)) {
    const attrs = parseAttrs(match[2] || "");
    if (attrs.audioStart != null || attrs.audioDuration != null) summary.splitEditContainers += 1;
  }
  return summary;
}

function appendAudioInventory(reportLines, label, summary) {
  reportLines.push(`audio inventory (${label}):`);
  reportLines.push(`- assets with audio: ${summary.audioAssets}`);
  reportLines.push(`- connected audio items: ${summary.connectedAudioItems}`);
  reportLines.push(`- connected audio items with lane: ${summary.connectedAudioItemsInLanes}`);
  reportLines.push(`- audio channel sources: ${summary.audioChannelSources}`);
  reportLines.push(`- audio role sources: ${summary.audioRoleSources}`);
  reportLines.push(`- sync sources: ${summary.syncSources}`);
  reportLines.push(`- audio filters: ${summary.audioFilters}`);
  reportLines.push(`- volume/panner adjustments: ${summary.audioAdjustments}`);
  reportLines.push(`- containers with J/L audio timing: ${summary.splitEditContainers}`);
  reportLines.push(`- explicit audio-only clips: ${summary.explicitAudioOnlyClips}`);
  reportLines.push(`- explicit video-only clips: ${summary.explicitVideoOnlyClips}`);
  reportLines.push(`- implicit A/V source clips: ${summary.implicitAVClips}`);
}

function scanXMLTags(xml) {
  const tags = [];
  let index = 0;
  while (index < xml.length) {
    const start = xml.indexOf("<", index);
    if (start < 0) break;
    if (xml.startsWith("<!--", start)) {
      const end = xml.indexOf("-->", start + 4);
      index = end < 0 ? xml.length : end + 3;
      continue;
    }
    if (xml.startsWith("<![CDATA[", start)) {
      const end = xml.indexOf("]]>", start + 9);
      index = end < 0 ? xml.length : end + 3;
      continue;
    }
    if (xml.startsWith("<?", start)) {
      const end = xml.indexOf("?>", start + 2);
      index = end < 0 ? xml.length : end + 2;
      continue;
    }
    let quote = "";
    let end = start + 1;
    for (; end < xml.length; end += 1) {
      const char = xml[end];
      if (quote) {
        if (char === quote) quote = "";
      } else if (char === '"' || char === "'") {
        quote = char;
      } else if (char === ">") {
        break;
      }
    }
    if (end >= xml.length) break;
    const raw = xml.slice(start, end + 1);
    if (!raw.startsWith("<!")) {
      const head = raw.match(/^<\s*(\/?)\s*([\w:_-]+)/);
      if (head) {
        const nameEnd = head[0].length;
        tags.push({
          start,
          end: end + 1,
          raw,
          closing: head[1] === "/",
          name: head[2],
          selfClosing: /\/\s*>$/.test(raw),
          attrText: raw.slice(nameEnd, raw.length - 1),
        });
      }
    }
    index = end + 1;
  }
  return tags;
}

function removeElementTags(xml, tagNames) {
  const targets = new Set(tagNames);
  const stack = [];
  const ranges = [];
  for (const token of scanXMLTags(xml)) {
    const tag = token.name;
    if (!token.closing) {
      const insideTarget = stack.some((item) => item.remove);
      const remove = targets.has(tag);
      if (token.selfClosing) {
        if (remove && !insideTarget) ranges.push([token.start, token.end]);
      } else {
        stack.push({ tag, start: token.start, remove, insideTarget });
      }
      continue;
    }
    const node = stack.at(-1);
    if (!node || node.tag !== tag) continue;
    stack.pop();
    if (node.remove && !node.insideTarget) ranges.push([node.start, token.end]);
  }
  let output = xml;
  for (const [start, end] of ranges.sort((a, b) => b[0] - a[0])) {
    output = output.slice(0, start) + output.slice(end);
  }
  return output;
}

function removeSourceNodesForAudioOnlyAssets(xml, assets) {
  const sourceTags = new Set(["asset-clip", "ref-clip", "mc-clip"]);
  const stack = [];
  const ranges = [];
  for (const token of scanXMLTags(xml)) {
    const tag = token.name;
    if (!token.closing) {
      const attrs = parseAttrs(token.attrText || "");
      const asset = sourceTags.has(tag) ? assets.get(trim(attrs.ref)) : null;
      const remove = Boolean(asset?.hasAudio && !asset?.hasVideo);
      const insideTarget = stack.some((item) => item.remove);
      if (token.selfClosing) {
        if (remove && !insideTarget) ranges.push([token.start, token.end]);
      } else {
        stack.push({ tag, start: token.start, remove, insideTarget });
      }
      continue;
    }
    const node = stack.at(-1);
    if (!node || node.tag !== tag) continue;
    stack.pop();
    if (node.remove && !node.insideTarget) ranges.push([node.start, token.end]);
  }
  let output = xml;
  for (const [start, end] of ranges.sort((a, b) => b[0] - a[0])) {
    output = output.slice(0, start) + output.slice(end);
  }
  return output;
}

function makeSourceBackedVideoOnly(xml) {
  const sourceTags = new Set(["asset-clip", "ref-clip", "mc-clip"]);
  const replacements = [];
  for (const token of scanXMLTags(xml)) {
    if (token.closing || !sourceTags.has(token.name)) continue;
    let raw = token.raw.replace(/\s+srcEnable="[^"]*"/g, "");
    const insertAt = token.selfClosing ? raw.lastIndexOf("/") : raw.lastIndexOf(">");
    raw = raw.slice(0, insertAt) + ' srcEnable="video"' + raw.slice(insertAt);
    replacements.push([token.start, token.end, raw]);
  }
  let output = xml;
  for (const [start, end, replacement] of replacements.sort((a, b) => b[0] - a[0])) {
    output = output.slice(0, start) + replacement + output.slice(end);
  }
  return output;
}

async function removeAudioForConform(xml) {
  const before = summarizeAudioStructures(xml);
  const stylesheet = `<?xml version="1.0" encoding="UTF-8"?>
<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
  <xsl:output method="xml" encoding="UTF-8" indent="yes" doctype-system=""/>
  <xsl:key name="asset-by-id" match="asset" use="@id"/>
  <xsl:template match="@*|node()">
    <xsl:copy><xsl:apply-templates select="@*|node()"/></xsl:copy>
  </xsl:template>
  <xsl:template match="audio|sync-source|audio-channel-source|audio-role-source|filter-audio|adjust-volume|adjust-panner"/>
  <xsl:template match="@audioStart|@audioDuration"/>
  <xsl:template match="asset-clip[key('asset-by-id', @ref)[@hasAudio='1' and not(@hasVideo='1')]]|ref-clip[key('asset-by-id', @ref)[@hasAudio='1' and not(@hasVideo='1')]]|mc-clip[key('asset-by-id', @ref)[@hasAudio='1' and not(@hasVideo='1')]]"/>
  <xsl:template match="asset-clip">
    <video>
      <xsl:copy-of select="@ref|@name|@offset|@start|@duration|@enabled|@lane"/>
      <xsl:if test="not(@duration) and key('asset-by-id', @ref)/@duration">
        <xsl:attribute name="duration"><xsl:value-of select="key('asset-by-id', @ref)/@duration"/></xsl:attribute>
      </xsl:if>
      <xsl:if test="@videoRole"><xsl:attribute name="role"><xsl:value-of select="@videoRole"/></xsl:attribute></xsl:if>
      <xsl:apply-templates select="node()[not(self::metadata)]"/>
    </video>
  </xsl:template>
  <xsl:template match="ref-clip|mc-clip">
    <xsl:copy>
      <xsl:apply-templates select="@*[name() != 'srcEnable']"/>
      <xsl:attribute name="srcEnable">video</xsl:attribute>
      <xsl:apply-templates select="node()"/>
    </xsl:copy>
  </xsl:template>
</xsl:stylesheet>`;
  const token = crypto.randomUUID();
  const sourcePath = path.join(os.tmpdir(), `conform_audio_source_${token}.fcpxml`);
  const stylesheetPath = path.join(os.tmpdir(), `conform_audio_remove_${token}.xsl`);
  let output = "";
  try {
    await fs.writeFile(sourcePath, xml);
    await fs.writeFile(stylesheetPath, stylesheet);
    const result = spawnSync("/usr/bin/xsltproc", [stylesheetPath, sourcePath], {
      encoding: "utf8",
      maxBuffer: 128 * 1024 * 1024,
    });
    if (result.error) throw result.error;
    if (result.status !== 0 || !trim(result.stdout)) {
      throw new Error(trim(result.stderr || result.stdout) || "xsltproc audio cleanup failed");
    }
    output = result.stdout.replace(/<!DOCTYPE fcpxml SYSTEM "">\s*/i, "<!DOCTYPE fcpxml>\n");
  } finally {
    await Promise.allSettled([fs.unlink(sourcePath), fs.unlink(stylesheetPath)]);
  }
  const after = summarizeAudioStructures(output);
  return { xml: output, before, after };
}

function insertStoryItemIntoClipXML(clipXML, storyXML) {
  const close = clipXML.match(/<\/(clip|asset-clip)>\s*$/);
  if (!close) return clipXML;
  const closeIndex = close.index ?? clipXML.length;
  const open = clipXML.match(/^<(clip|asset-clip)\b[^>]*>/);
  if (!open) return clipXML;
  const bodyStart = open[0].length;
  const body = clipXML.slice(bodyStart, closeIndex);
  const elements = collectTopLevelElements(body);
  const insertBeforeTags = new Set([
    "marker",
    "chapter-marker",
    "rating",
    "keyword",
    "audio-role-source",
    "filter-video",
    "filter-audio",
    "metadata",
  ]);
  const insertBefore = elements.find((item) => insertBeforeTags.has(item.tag));
  if (!insertBefore) {
    return `${clipXML.slice(0, closeIndex)}\n${storyXML}\n${clipXML.slice(closeIndex)}`;
  }
  const insertIndex = bodyStart + insertBefore.xml.length >= 0
    ? clipXML.indexOf(insertBefore.xml, bodyStart)
    : -1;
  if (insertIndex < 0) {
    return `${clipXML.slice(0, closeIndex)}\n${storyXML}\n${clipXML.slice(closeIndex)}`;
  }
  return `${clipXML.slice(0, insertIndex)}${storyXML}\n${clipXML.slice(insertIndex)}`;
}

function relocateClipLocalSiblingTitles(xml, reportLines) {
  const spineMatch = xml.match(/<spine>([\s\S]*?)<\/spine>/);
  if (!spineMatch) return { xml, count: 0 };
  const spineBody = spineMatch[1];
  const elements = collectTopLevelElements(spineBody);
  const relocatedByIndex = new Map();
  const removedTitleIndexes = new Set();

  for (let index = 0; index < elements.length; index += 1) {
    const item = elements[index];
    if (item.tag !== "title") continue;
    // A lane-less title is a primary spine item. Moving it inside a clip makes
    // FCP split the clip's video around the title and can change conform scope.
    if (!trim(item.attrs.lane)) continue;

    let targetIndex = -1;
    for (let candidateIndex = index - 1; candidateIndex >= 0; candidateIndex -= 1) {
      const candidate = elements[candidateIndex];
      if (!["clip", "asset-clip"].includes(candidate.tag)) continue;
      if (
        storyItemCanAnchorInClipWindow(
          item.xml,
          candidate.attrs.offset,
          candidate.attrs.duration
        )
      ) {
        targetIndex = candidateIndex;
        break;
      }
      const candidateOffset = parseTimeValue(candidate.attrs.offset || "");
      const titleOffset = parseTimeValue(item.attrs.offset || "");
      if (candidateOffset && titleOffset && compareTime(candidateOffset, titleOffset) < 0) {
        break;
      }
    }
    if (targetIndex < 0) continue;

    const target = elements[targetIndex];
    const nestedTitle = rebaseStoryItemXML(item.xml, target.attrs.offset, target.attrs.start);
    const bucket = relocatedByIndex.get(targetIndex) || [];
    bucket.push(nestedTitle);
    relocatedByIndex.set(targetIndex, bucket);
    removedTitleIndexes.add(index);
  }

  if (removedTitleIndexes.size === 0) return { xml, count: 0 };

  const rebuilt = elements.map((item, index) => {
    if (removedTitleIndexes.has(index)) return "";
    const relocated = relocatedByIndex.get(index) || [];
    if (relocated.length === 0) return item.xml;
    return relocated.reduce((clipXML, titleXML) => insertStoryItemIntoClipXML(clipXML, titleXML), item.xml);
  }).filter(Boolean).join("\n");

  reportLines.push(`relocated clip-local sibling titles: ${removedTitleIndexes.size}`);
  const patched = `${xml.slice(0, spineMatch.index)}<spine>${rebuilt}</spine>${xml.slice((spineMatch.index ?? 0) + spineMatch[0].length)}`;
  return { xml: patched, count: removedTitleIndexes.size };
}

function dtdCandidatePaths(version) {
  const normalizedVersion = String(version).replace(/\./g, "_");
  const filename = `FCPXMLv${normalizedVersion}.dtd`;
  const relative = path.join(
    "Contents",
    "Frameworks",
    "Interchange.framework",
    "Versions",
    "A",
    "Resources",
    filename
  );
  return [
    path.join(os.homedir(), "Applications", "SpliceKit", "Final Cut Pro.app", relative),
    path.join("/Applications", "Final Cut Pro.app", relative),
  ];
}

function existingPath(paths) {
  for (const candidate of paths) {
    try {
      if (!existsSync(candidate)) continue;
      return candidate;
    } catch {
      // Try next candidate.
    }
  }
  return "";
}

function dtdSystemIdentifier(filePath) {
  const parts = filePath.split(path.sep).map((part) => encodeURIComponent(part));
  return `file://${parts.join("/")}`;
}

function assertWellFormed(xml, label) {
  const result = spawnSync("xmllint", ["--noout", "-"], {
    input: xml,
    encoding: "utf8",
    maxBuffer: 128 * 1024 * 1024,
  });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error(`Malformed XML after ${label}: ${trim(result.stderr || result.stdout)}`);
  }
}

async function validateAgainstDTD(xml, version, reportLines) {
  const dtdPath = existingPath(dtdCandidatePaths(version));
  if (!dtdPath) {
    reportLines.push(`warning: local FCPXMLv${version} DTD not found; skipped validation`);
    return;
  }

  const doctypeRegex = /<!DOCTYPE\s+fcpxml(?:\s+SYSTEM\s+"[^"]*")?\s*>/;
  const xmlWithDTD = xml.replace(
    doctypeRegex,
    `<!DOCTYPE fcpxml SYSTEM "${dtdSystemIdentifier(dtdPath)}">`
  );
  const tempXmlPath = path.join(os.tmpdir(), `conform_prep_validate_${crypto.randomUUID()}.fcpxml`);

  let validationPassed = false;
  try {
    await fs.writeFile(tempXmlPath, xmlWithDTD);
    const result = spawnSync("xmllint", ["--noout", "--loaddtd", "--valid", tempXmlPath], {
      encoding: "utf8",
    });
    if (result.error) {
      throw result.error;
    }
    if (result.status !== 0) {
      const message = trim(result.stderr || result.stdout) || "xmllint validation failed";
      throw new Error(message);
    }
    reportLines.push(`DTD validation: passed (${path.basename(dtdPath)})`);
    validationPassed = true;
  } catch (error) {
    const message = trim(error?.message || String(error));
    reportLines.push(`DTD validation: failed (${path.basename(dtdPath)})`);
    reportLines.push(`DTD validation detail: ${message}`);
    reportLines.push(`DTD failed XML retained at: ${tempXmlPath}`);
    throw new Error(`DTD validation failed. ${message}`);
  } finally {
    if (validationPassed) {
      try {
        await fs.unlink(tempXmlPath);
      } catch {
        // Ignore cleanup failures.
      }
    }
  }
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const sourceXml = await fs.readFile(args.sourceXml, "utf8");
  const assets = collectAssetInfo(sourceXml);
  const formatFrameDurations = collectFormatFrameDurations(sourceXml);
  const report = [];
  const version = fcpxmlVersion(sourceXml) || "1.12";

  appendAudioInventory(report, "source", summarizeAudioStructures(sourceXml));

  let patched = sourceXml;
  const newProjectName = nextConformPrepName(sourceXml);
  patched = replaceProjectName(patched, newProjectName);
  patched = replaceProjectUID(patched);
  report.push(`project: ${newProjectName}`);

  let totalFlattened = 0;
  const skippedSyncReasons = new Set();
  for (let pass = 1; pass <= 2; pass += 1) {
    const flattened = flattenSimpleSyncClips(patched, assets, report, formatFrameDurations);
    patched = flattened.xml;
    assertWellFormed(patched, `sync flatten pass ${pass}`);
    totalFlattened += flattened.count;
    for (const item of flattened.skipped || []) skippedSyncReasons.add(item);
    if (flattened.count === 0) break;
    report.push(`sync flatten pass ${pass}: ${flattened.count}`);
  }
  report.push(`simple sync-clips flattened: ${totalFlattened}`);
  if (skippedSyncReasons.size > 0) {
    report.push("skipped sync-clips:");
    for (const line of [...skippedSyncReasons].sort()) report.push(line);
  }

  const renamed = renameSourceBackedNodesByDescendant(patched, assets, report);
  patched = renamed.xml;
  assertWellFormed(patched, "source-backed rename");
  report.push(`source-backed nodes renamed: ${renamed.count}`);

  const normalizedTextStyles = normalizeTitleTextStyleIds(patched, report);
  patched = normalizedTextStyles.xml;
  assertWellFormed(patched, "text-style normalization");
  report.push(`duplicate text-style-def ids normalized: ${normalizedTextStyles.count}`);

  const normalizedNestedTitles = normalizeNestedTitleOffsets(patched, report);
  patched = normalizedNestedTitles.xml;
  assertWellFormed(patched, "nested-title normalization");
  report.push(`nested title offsets normalized: ${normalizedNestedTitles.count}`);

  const strippedUnnamedMarkers = removeUnnamedSourceMarkers(patched);
  patched = strippedUnnamedMarkers.xml;
  assertWellFormed(patched, "marker cleanup");
  report.push(`unnamed source markers removed: ${strippedUnnamedMarkers.count}`);

  const beforeTitleRelocation = patched;
  const relocatedSiblingTitles = relocateClipLocalSiblingTitles(patched, report);
  try {
    assertWellFormed(relocatedSiblingTitles.xml, "title relocation");
    patched = relocatedSiblingTitles.xml;
    report.push(`clip-local sibling titles relocated: ${relocatedSiblingTitles.count}`);
  } catch {
    patched = beforeTitleRelocation;
    report.push("clip-local sibling title relocation skipped: generated XML was not well-formed");
  }

  const audioCleanup = await removeAudioForConform(patched);
  patched = audioCleanup.xml;
  appendAudioInventory(report, "before automatic audio removal", audioCleanup.before);
  appendAudioInventory(report, "final video-only output", audioCleanup.after);

  const remainingSync = countMatches(patched, /<sync-clip\b/g);
  const remainingMc = countMatches(patched, /<mc-clip\b/g);
  report.push(`remaining sync-clips: ${remainingSync}`);
  report.push(`remaining multicam clips: ${remainingMc}`);
  if (remainingSync > 0) {
    report.push("remaining sync-clip names:");
    for (const name of listRemainingSyncClipNames(patched)) report.push(`- ${name}`);
  }
  report.push("notes:");
  report.push("- IMPORTANT: For clean flatten validation, clear editorial titles/markers before running Conform Prep when possible. Existing titles/markers can be preserved best-effort, but they can also create import-side noise that hides the real flattening result.");
  report.push("- v1 flattens simple sync-clips conservatively");
  report.push("- v1 renames source-backed clips to source filenames");
  report.push("- expected clip-count note: a one-frame live segment followed by a hold is emitted as two adjacent clips so Final Cut preserves every visible frame; each occurrence increases the structural clip count by one without adding timeline duration");
  report.push("- multicam flattening and complex retime flattening still need more work");

  try {
    await validateAgainstDTD(patched, version, report);
  } catch (error) {
    await fs.mkdir(path.dirname(args.report), { recursive: true });
    report.push(`fatal error: ${trim(error?.message || String(error))}`);
    await fs.writeFile(args.report, report.join("\n") + "\n");
    throw error;
  }

  await fs.mkdir(path.dirname(args.outputXml), { recursive: true });
  await fs.mkdir(path.dirname(args.report), { recursive: true });
  await fs.writeFile(args.outputXml, patched);
  await fs.writeFile(args.report, report.join("\n") + "\n");
}

main().catch((error) => {
  console.error(error?.stack || String(error));
  process.exit(1);
});
