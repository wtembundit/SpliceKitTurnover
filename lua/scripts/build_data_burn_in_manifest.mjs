#!/usr/bin/env node

import fs from "node:fs/promises";
import path from "node:path";
import {
  collectGlobalVfxTitles,
  parseAssets,
  parseFormats,
  parseSequenceFrameDuration,
} from "./build_vfx_pull_edl.mjs";
import {
  floatToTime,
  interpolateTimeMap,
  parseTimeMapXML,
  timeToFloat,
} from "./lib/fcpxml_time_model.mjs";

function parseArgs(argv) {
  const args = {};
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--source-xml") args.sourceXml = path.resolve(argv[++index]);
    else if (arg === "--output-manifest" || arg === "--output-index") args.outputManifest = path.resolve(argv[++index]);
    else if (arg === "--report") args.report = path.resolve(argv[++index]);
    else throw new Error(`Unknown argument: ${arg}`);
  }
  if (!args.sourceXml || !args.outputManifest || !args.report) {
    throw new Error("Usage: build_data_burn_in_manifest.mjs --source-xml INPUT --output-index OUTPUT --report REPORT");
  }
  return args;
}

function trim(value) {
  return String(value ?? "").trim();
}

function parseTime(value) {
  const fraction = /^([-\d.]+)\/([-\d.]+)s$/.exec(trim(value));
  if (fraction) return Number(fraction[1]) / Number(fraction[2]);
  const seconds = /^([-\d.]+)s$/.exec(trim(value));
  return seconds ? Number(seconds[1]) : 0;
}

function parseAttrs(value = "") {
  const attrs = {};
  for (const match of value.matchAll(/([\w:_-]+)\s*=\s*"([^"]*)"/g)) attrs[match[1]] = match[2];
  return attrs;
}

function isSelfClosingTag(attrText = "", selfClosing = "") {
  return selfClosing === "/" || /\/\s*$/.test(String(attrText ?? ""));
}

function decodeXML(value = "") {
  return String(value)
    .replace(/&quot;/g, "\"")
    .replace(/&apos;/g, "'")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&amp;/g, "&");
}

function formatFrameRate(frameDuration) {
  const fps = 1 / Number(frameDuration || 0);
  if (!Number.isFinite(fps) || fps <= 0) return "";
  const rounded = Math.round(fps * 1000) / 1000;
  return Number.isInteger(rounded) ? String(rounded) : String(rounded).replace(/\.?0+$/, "");
}

function parseMetadataEntries(blob = "") {
  const entries = [];
  for (const match of blob.matchAll(/<md\s+([^>]*?)(?:\/>|>[\s\S]*?<\/md>)/g)) {
    const attrs = parseAttrs(match[1]);
    const key = trim(attrs.key);
    const value = trim(decodeXML(attrs.value));
    const label = metadataDisplayLabel(key, trim(decodeXML(attrs.displayName)));
    const source = trim(attrs.source);
    if (!label || !value) continue;
    entries.push({ key, label, value, source });
  }
  return entries;
}

function metadataDisplayLabel(key = "", displayName = "") {
  const display = trim(displayName);
  if (display && !/^com\./i.test(display)) return display;
  const raw = trim(key) || display;
  const compact = raw.split(".").filter(Boolean).at(-1) || raw;
  const candidate = compact.replace(/^kMDItem/i, "") || compact;
  const aliases = new Map([
    ["fstop", "F-stop"],
    ["fnumber", "F-stop"],
    ["aperture", "F-stop"],
    ["lens", "Lens"],
    ["lensmodel", "Lens"],
    ["lens_model", "Lens"],
    ["quality", "Q"],
    ["q", "Q"],
  ]);
  const normalized = candidate.toLowerCase().replace(/[^a-z0-9]+/g, "");
  if (aliases.has(normalized)) return aliases.get(normalized);
  return candidate
    .replace(/^k\s*md\s*item\s*/i, "")
    .replace(/[_-]+/g, " ")
    .replace(/([a-z0-9])([A-Z])/g, "$1 $2")
    .replace(/\s+/g, " ")
    .trim()
    .replace(/\b\w/g, (letter) => letter.toUpperCase());
}

function normalizeMetadataLabel(value = "") {
  return trim(value).toLowerCase().replace(/[^a-z0-9]+/g, " ");
}

function combineMetadataEntries(...groups) {
  const seen = new Set();
  const entries = [];
  for (const group of groups.flat()) {
    if (!group?.label || !group?.value) continue;
    const key = `${normalizeMetadataLabel(group.label)}|${trim(group.value)}`;
    if (seen.has(key)) continue;
    seen.add(key);
    entries.push({
      key: trim(group.key),
      label: metadataDisplayLabel(trim(group.key), trim(group.label)),
      value: trim(group.value),
      source: trim(group.source),
    });
  }
  return entries;
}

function pickMetadataValue(entries, patterns) {
  for (const pattern of patterns) {
    const found = entries.find((entry) => {
      const haystack = `${normalizeMetadataLabel(entry.label)} ${normalizeMetadataLabel(entry.key)}`;
      return pattern.test(haystack);
    });
    if (found) return found.value;
  }
  return "";
}

function summarizeMetadata(entries, { customOnly = false, limit = 8 } = {}) {
  return entries
    .filter((entry) => !customOnly || normalizeMetadataLabel(entry.source).includes("custom"))
    .slice(0, limit)
    .map((entry) => `${entry.label}: ${entry.value}`)
    .join(" | ");
}

function metadataSummaryForSegment(source, localEntries = []) {
  const entries = combineMetadataEntries(source?.asset?.metadataEntries || [], localEntries);
  const customMetadata = trim(source?.customMetadata);
  return {
    sourceName: trim(source?.asset?.name),
    reel: pickMetadataValue(entries, [/\breel\b/]),
    scene: pickMetadataValue(entries, [/\bscene\b/]),
    take: pickMetadataValue(entries, [/\btake\b/]),
    camera: pickMetadataValue(entries, [/\bcamera name\b/, /\bcamera\b/]),
    angle: pickMetadataValue(entries, [/\bangle\b/, /\bcamera angle\b/]),
    custom: customMetadata || summarizeMetadata(entries, { customOnly: true }) || summarizeMetadata(entries, { limit: 6 }),
    all: summarizeMetadata(entries),
    entries,
  };
}

function extractFirstElement(xml, tagName) {
  const tagRegex = /<(\/?)([\w:_-]+)(.*?)(\/?)>/gs;
  let depth = 0;
  let startIndex = -1;
  let match;
  while ((match = tagRegex.exec(xml))) {
    const [, closing, currentTag, attrText, selfClosing] = match;
    if (currentTag !== tagName) continue;
    if (closing === "/") {
      depth -= 1;
      if (depth === 0 && startIndex >= 0) return xml.slice(startIndex, tagRegex.lastIndex);
      continue;
    }
    if (depth === 0) startIndex = match.index;
    if (!isSelfClosingTag(attrText, selfClosing)) depth += 1;
    else if (startIndex >= 0 && depth === 0) return xml.slice(startIndex, tagRegex.lastIndex);
  }
  return "";
}

function collectAnalysisItems(xml, timelineFrameDuration = 1 / 24, timelineBounds = {}) {
  const items = [];
  const stack = [];
  const ownerTags = new Set(["clip", "asset-clip", "sync-clip", "mc-clip", "video", "title"]);
  const tagRegex = /<(\/?)([\w:_-]+)(.*?)(\/?)>/gs;
  let match;

  function ownerContext() {
    return [...stack].reverse().find((item) => ownerTags.has(item.tag));
  }

  function ownerName(owner) {
    if (!owner) return "Timeline";
    return decodeXML(owner.attrs.name || owner.attrs.ref || "Timeline");
  }

  function pushItem(label, detail, options = {}) {
    const owner = ownerContext();
    const ownerStart = Number(owner?.timelineStart) || 0;
    const ownerEnd = ownerStart + (Number(owner?.duration) || 0);
    items.push({
      label,
      key: options.key || label.toLowerCase().replaceAll(" ", "_"),
      value: options.value || "",
      owner: owner ? `${owner.tag} ${ownerName(owner)}` : "timeline",
      ownerName: ownerName(owner),
      detail,
      timelineStartSeconds: Number.isFinite(options.timelineStartSeconds) ? options.timelineStartSeconds : ownerStart,
      timelineEndSeconds: Number.isFinite(options.timelineEndSeconds) ? options.timelineEndSeconds : ownerEnd,
    });
  }

  function formatAttrSummary(attrs, preferred = []) {
    const parts = [];
    for (const key of preferred) {
      const value = trim(attrs[key]);
      if (value) parts.push(`${key}=${value}`);
    }
    if (parts.length > 0) return parts.join(" ");
    return Object.entries(attrs)
      .filter(([key, value]) => key !== "enabled" && trim(value))
      .slice(0, 6)
      .map(([key, value]) => `${key}=${trim(value)}`)
      .join(" ");
  }

  function transformNumbers(value = "") {
    return trim(value).split(/\s+/).map(Number).filter(Number.isFinite);
  }

  function isDefaultTransformValue(value = "", expected = 0) {
    const values = transformNumbers(value);
    if (values.length === 0) return false;
    return values.every((number) => Math.abs(number - expected) < 0.0001);
  }

  function animatedTransformKeys(body = "") {
    const keys = new Set();
    for (const match of body.matchAll(/<param\s+([^>]*?)(?:\/>|>[\s\S]*?<\/param>)/g)) {
      const attrs = parseAttrs(match[1]);
      const kind = transformParamKind(attrs);
      if (!kind || !/<keyframe\b|<keyframeAnimation\b|<curve\b/.test(match[0])) continue;
      keys.add(kind.key);
    }
    return keys;
  }

  function pushTransformItems(attrs, body = "") {
    const animatedKeys = animatedTransformKeys(body);
    const position = trim(attrs.position);
    const scale = trim(attrs.scale);
    const rotation = trim(attrs.rotation);
    const anchor = trim(attrs.anchor);
    const parts = [];
    if (position && !animatedKeys.has("transform_position") && !isDefaultTransformValue(position, 0)) {
      parts.push(`position=${position}`);
      pushItem("Position", `position ${formatTransformVector(position, "position")}`, { key: "transform_position", value: formatTransformVector(position, "position") });
    }
    if (scale && !animatedKeys.has("transform_scale") && !isDefaultTransformValue(scale, 1)) {
      parts.push(`scale=${scale}`);
      pushItem("Scale", `scale ${formatTransformVector(scale, "scale")}`, { key: "transform_scale", value: formatTransformVector(scale, "scale") });
    }
    if (rotation && !animatedKeys.has("transform_rotation") && !isDefaultTransformValue(rotation, 0)) {
      parts.push(`rotation=${rotation}`);
      pushItem("Rotation", `rotation ${formatTransformScalar(rotation, "°")}`, { key: "transform_rotation", value: formatTransformScalar(rotation, "°") });
    }
    if (anchor) parts.push(`anchor=${anchor}`);
  }

  function transformParamKind(attrs = {}) {
    const haystack = normalizeMetadataLabel(`${attrs.name || ""} ${attrs.key || ""}`);
    if (/\bposition\b/.test(haystack)) {
      return { label: "Position", key: "transform_position", defaultValue: 0, format: (value) => formatTransformVector(value, "position") };
    }
    if (/\bscale\b/.test(haystack)) {
      return { label: "Scale", key: "transform_scale", defaultValue: 1, format: (value) => formatTransformVector(value, "scale") };
    }
    if (/\brotation\b|\brotate\b/.test(haystack)) {
      return { label: "Rotation", key: "transform_rotation", defaultValue: 0, format: (value) => formatTransformScalar(value, "°") };
    }
    return null;
  }

  function keyframeOffsetCandidates(rawTime, node) {
    const time = parseTime(rawTime);
    const duration = Number(node?.duration) || 0;
    const nodeStart = Number(node?.start) || 0;
    const timelineStart = Number(node?.timelineStart) || 0;
    if (!Number.isFinite(time)) return null;
    return {
      local: time,
      source: time - nodeStart,
      timeline: time - timelineStart,
      duration,
    };
  }

  function normalizeKeyframeOffsets(keyframes, node) {
    const duration = Math.max(Number(node?.duration) || 0, 0);
    if (keyframes.length === 0) return [];
    const modes = ["local", "source", "timeline"];
    const scored = modes.map((mode) => {
      const offsets = keyframes.map((keyframe) => keyframe.candidates?.[mode]).filter(Number.isFinite);
      const inRange = offsets.filter((offset) => offset >= -duration && offset <= duration * 2);
      const visible = offsets.filter((offset) => offset >= -0.000001 && offset <= duration + 0.000001);
      const range = offsets.length > 1 ? Math.max(...offsets) - Math.min(...offsets) : 0;
      const averageDistance = offsets.length === 0
        ? Number.MAX_SAFE_INTEGER
        : offsets.reduce((sum, offset) => {
          if (offset >= 0 && offset <= duration) return sum;
          return sum + Math.min(Math.abs(offset), Math.abs(offset - duration));
        }, 0) / offsets.length;
      return {
        mode,
        offsets,
        score: (visible.length * 100) + (inRange.length * 10) + (range > 0.000001 ? 1 : 0) - Math.min(averageDistance, 1000000),
      };
    }).sort((a, b) => b.score - a.score);
    const mode = scored[0]?.mode ?? "local";
    return keyframes
      .map((keyframe) => ({
        ...keyframe,
        offset: keyframe.candidates?.[mode] ?? 0,
      }))
      .sort((a, b) => a.offset - b.offset);
  }

  function parseNumberList(value = "") {
    return trim(value).split(/\s+/).map(Number).filter(Number.isFinite);
  }

  function interpolateRawValue(a, b, t) {
    const av = parseNumberList(a.rawValue);
    const bv = parseNumberList(b.rawValue);
    if (av.length === 0 || av.length !== bv.length) return a.rawValue;
    const values = av.map((value, index) => value + ((bv[index] - value) * t));
    return values.map((value) => {
      const rounded = Math.abs(value) < 0.000001 ? 0 : value;
      return rounded.toFixed(6).replace(/\.?0+$/, "");
    }).join(" ");
  }

  function summarizeAnimatedTransform(body = "", node = {}) {
    const summaries = [];
    for (const match of body.matchAll(/<param\s+([^>]*?)(?:\/>|>[\s\S]*?<\/param>)/g)) {
      const attrs = parseAttrs(match[1]);
      const kind = transformParamKind(attrs);
      const hasKeyframes = /<keyframe\b|<keyframeAnimation\b|<curve\b/.test(match[0]);
      if (!kind || !hasKeyframes) continue;
      const keyframes = normalizeKeyframeOffsets([...match[0].matchAll(/<keyframe\s+([^>]*?)(?:\/>|>[\s\S]*?<\/keyframe>)/g)]
        .map((keyframeMatch) => {
          const keyframeAttrs = parseAttrs(keyframeMatch[1]);
          const value = trim(decodeXML(keyframeAttrs.value));
          const candidates = keyframeOffsetCandidates(keyframeAttrs.time, node);
          if (!value) return null;
          return {
            candidates,
            rawValue: value,
            value: kind.format(value),
          };
        })
        .filter((keyframe) => keyframe?.candidates), node);
      if (keyframes.length === 0) {
        summaries.push({ label: kind.label, key: kind.key, value: "animated" });
        continue;
      }
      if (keyframes.every((keyframe) => isDefaultTransformValue(keyframe.rawValue, kind.defaultValue))) {
        continue;
      }
      const duration = Math.max(Number(node.duration) || 0, 0);
      keyframes.forEach((keyframe, index) => {
        const next = keyframes[index + 1];
        const intervalStart = Math.max(keyframe.offset, 0);
        const intervalEnd = Math.max(next?.offset ?? duration, intervalStart);
        const baseStep = Math.max(Number(timelineFrameDuration) || (1 / 24), 0.001);
        const maxSamplesPerParam = 5000;
        const step = Math.max(baseStep, (intervalEnd - intervalStart) / maxSamplesPerParam);
        if (!next || intervalEnd <= intervalStart + step) {
          if (isDefaultTransformValue(keyframe.rawValue, kind.defaultValue) || intervalEnd <= intervalStart) return;
          summaries.push({
            label: kind.label,
            key: kind.key,
            value: keyframe.value,
            timelineStartSeconds: (Number(node.timelineStart) || 0) + intervalStart,
            timelineEndSeconds: (Number(node.timelineStart) || 0) + (intervalEnd > intervalStart ? intervalEnd : duration),
          });
          return;
        }
        for (let offset = intervalStart; offset < intervalEnd; offset += step) {
          const t = (offset - intervalStart) / (intervalEnd - intervalStart);
          const rawValue = interpolateRawValue(keyframe, next, t);
          if (isDefaultTransformValue(rawValue, kind.defaultValue)) continue;
          const value = kind.format(rawValue);
          summaries.push({
            label: kind.label,
            key: kind.key,
            value,
            timelineStartSeconds: (Number(node.timelineStart) || 0) + offset,
            timelineEndSeconds: (Number(node.timelineStart) || 0) + Math.min(offset + step, intervalEnd),
          });
        }
      });
    }
    const seen = new Set();
    return summaries.filter((item) => {
      const key = `${item.key}|${item.value}|${Number(item.timelineStartSeconds || 0).toFixed(6)}|${Number(item.timelineEndSeconds || 0).toFixed(6)}`;
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    });
  }

  while ((match = tagRegex.exec(xml))) {
    const [, closing, tag, attrText, selfClosing] = match;
    if (closing === "/") {
      const node = stack.pop();
      if (node?.tag === "adjust-transform") {
        const body = xml.slice(node.openEnd, match.index);
        pushTransformItems(node.attrs, body);
        for (const item of summarizeAnimatedTransform(body, node)) {
          pushItem(item.label, `${item.label.toLowerCase()} ${item.value}`, {
            key: item.key,
            value: item.value,
            timelineStartSeconds: item.timelineStartSeconds,
            timelineEndSeconds: item.timelineEndSeconds,
          });
        }
      }
      continue;
    }

    const attrs = parseAttrs(attrText);
    const parent = stack.at(-1);
    const timelineStart = contextTimelineStart(parent, attrs);
    const node = {
      tag,
      attrs,
      timelineStart,
      start: attrs.start == null ? Number(parent?.start) || 0 : parseTime(attrs.start),
      duration: attrs.duration == null ? Number(parent?.duration) || 0 : parseTime(attrs.duration),
      openEnd: tagRegex.lastIndex,
    };

    if (tag === "filter-video" && attrs.name === "Magnetic Mask") {
      pushItem("Magnetic Mask", /dataLocator=|<data\b|<param\b/.test(match[0]) ? "effect payload present" : "effect shell present");
    } else if (tag === "object-tracker") {
      pushItem("Object Tracking", "object tracker data in XML");
    } else if (tag === "adjust-stabilization") {
      pushItem("Stabilization", formatAttrSummary(attrs, ["type", "amount", "method"]) || "stabilization settings in XML", {
        key: "stabilization",
        value: formatAttrSummary(attrs, ["type", "amount", "method"]) || "present",
      });
    } else if (tag === "timeMap" && /^optical-flow/.test(attrs.frameSampling || "")) {
      pushItem("Optical Flow", attrs.frameSampling || "optical-flow", {
        key: "optical_flow",
        value: attrs.frameSampling || "optical-flow",
      });
    } else if (tag === "adjust-crop") {
      const value = formatAttrSummary(attrs, ["mode", "crop", "trim-rect", "panAmount"]);
      pushItem("Crop", value || "crop settings in XML", { key: "crop", value: value || "present" });
    } else if (tag === "adjust-corners") {
      const value = formatAttrSummary(attrs, ["topLeft", "topRight", "bottomRight", "bottomLeft"]);
      pushItem("Distort", value || "corner distortion in XML", { key: "distort", value: value || "present" });
    } else if (tag === "adjust-conform") {
      const value = formatAttrSummary(attrs, ["type"]);
      pushItem("Spatial Conform", value || "spatial conform settings in XML", { key: "spatial_conform", value: value || "present" });
    } else if (tag === "conform-rate") {
      const value = formatAttrSummary(attrs, ["srcFrameRate"]);
      pushItem("Conform Rate", value || "conform-rate settings in XML", { key: "conform_rate", value: value || "present" });
    } else if (tag === "adjust-transform" && isSelfClosingTag(attrText, selfClosing)) {
      pushTransformItems(attrs);
    }

    if (!isSelfClosingTag(attrText, selfClosing)) stack.push(node);
  }

  const boundsStart = Number(timelineBounds.startSeconds) || 0;
  const boundsEnd = boundsStart + (Number(timelineBounds.durationSeconds) || Number.POSITIVE_INFINITY);
  return items
    .map((item) => ({
      ...item,
      timelineStartSeconds: Math.max(Number(item.timelineStartSeconds) || 0, boundsStart),
      timelineEndSeconds: Math.min(Number(item.timelineEndSeconds) || 0, boundsEnd),
    }))
    .filter((item) => item.timelineEndSeconds > item.timelineStartSeconds);
}

function formatTransformScalar(value, suffix = "") {
  const number = Number(value);
  if (!Number.isFinite(number)) return trim(value);
  const rounded = Math.abs(number) < 0.005 ? 0 : number;
  return `${rounded.toFixed(2).replace(/\.?0+$/, "")}${suffix}`;
}

function formatTransformVector(value, kind) {
  const values = trim(value).split(/\s+/).map(Number).filter(Number.isFinite);
  if (values.length === 0) return trim(value);
  const format = (number) => {
    const scaled = kind === "scale" ? number * 100 : number;
    const rounded = Math.abs(scaled) < 0.005 ? 0 : scaled;
    return rounded.toFixed(2).replace(/\.?0+$/, "");
  };
  if (values.length === 1) return kind === "scale" ? `${format(values[0])}%` : format(values[0]);
  const suffix = kind === "scale" ? "%" : "";
  return `x ${format(values[0])}${suffix}, y ${format(values[1])}${suffix}`;
}

function contextTimelineStart(parent, attrs) {
  const parentTimeline = Number(parent?.timelineStart) || 0;
  const offset = attrs.offset == null ? null : parseTime(attrs.offset);
  if (offset == null) return parentTimeline;
  return parentTimeline + offset - (Number(parent?.start) || 0);
}

function findFirstChildRef(blob = "") {
  return /<video[^>]*ref="([^"]+)"/s.exec(blob)?.[1]
    || /<asset-clip[^>]*ref="([^"]+)"/s.exec(blob)?.[1]
    || /<ref-clip[^>]*ref="([^"]+)"/s.exec(blob)?.[1]
    || "";
}

function hasNestedContainerChildren(body = "") {
  return /<(asset-clip|clip|ref-clip|sync-clip|mc-clip)[\s>]/.test(body);
}

function directChildElementXML(body = "", targetTag = "") {
  const target = trim(targetTag).toLowerCase();
  if (!target) return "";
  const tagRegex = /<(\/?)([\w:_-]+)(.*?)(\/?)>/gs;
  let depth = 0;
  let targetDepth = -1;
  let targetStart = -1;
  let match;
  while ((match = tagRegex.exec(body))) {
    const [, closing, tagName, attrText, selfClosing] = match;
    const tag = trim(tagName).toLowerCase();
    const selfClosed = isSelfClosingTag(attrText, selfClosing);
    if (closing === "/") {
      if (tag === target && depth === targetDepth && targetStart >= 0) {
        return body.slice(targetStart, tagRegex.lastIndex);
      }
      depth = Math.max(0, depth - 1);
      continue;
    }
    if (depth === 0 && tag === target) {
      if (selfClosed) return body.slice(match.index, tagRegex.lastIndex);
      targetStart = match.index;
      targetDepth = depth + 1;
    }
    if (!selfClosed) depth += 1;
  }
  return "";
}

function parseDirectTimeMapXML(body = "") {
  const directTimeMap = directChildElementXML(body, "timeMap");
  return directTimeMap ? parseTimeMapXML(directTimeMap) : [];
}

function hasDirectVideoPayload(body = "") {
  return /<video\b[^>]*\bref="/s.test(directChildElementXML(body, "video"));
}

function directMediaChildUsesNonVideoRole(body = "") {
  let depth = 0;
  const tagRegex = /<(\/?)([\w:_-]+)(.*?)(\/?)>/gs;
  let match;
  while ((match = tagRegex.exec(body))) {
    const [, closing, tagName, attrText, selfClosing] = match;
    if (closing !== "/") {
      if (depth === 0 && TOP_LEVEL_MEDIA_TAGS.has(tagName)) {
        const role = trim(parseAttrs(attrText).role).toLowerCase();
        if (role && !role.startsWith("video")) return true;
      }
      if (!isSelfClosingTag(attrText, selfClosing)) depth += 1;
    } else if (depth > 0) {
      depth -= 1;
    }
  }
  return false;
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
    sourceTcSeconds,
    sourceFrameDuration: asset?.frameDuration || 0,
    sourceTcFormat: trim(node?.attrs?.tcFormat || node?.attrs?._effective_tcFormat || ""),
  };
}

function isOriginalVideoSegment(segmentNode, source) {
  const tag = trim(segmentNode?.tag).toLowerCase();
  const attrs = segmentNode?.attrs || {};
  const role = trim(attrs._effective_role || attrs.role).toLowerCase();
  if (tag === "audio") return false;
  if (role && !role.startsWith("video")) return false;
  if (["sync-clip", "mc-clip", "audition", "spine", "gap"].includes(tag)) return false;
  if (!source?.asset || trim(source.asset.hasVideo) !== "1") return false;
  return trim(source.sourceFilename) !== "";
}

function collectAudioRoleIntervals(xml, timelineStartSeconds = 0, timelineEndSeconds = Number.POSITIVE_INFINITY) {
  const intervals = [];
  const stack = [];
  const tags = new Set(["audio", "audio-role-source", "audio-channel-source"]);
  const tagRegex = /<(\/?)([\w:_-]+)(.*?)(\/?)>/gs;
  let match;
  while ((match = tagRegex.exec(xml))) {
    const [, closing, tag, attrText, selfClosing] = match;
    if (closing === "/") {
      stack.pop();
      continue;
    }
    const attrs = parseAttrs(attrText);
    const parent = stack.at(-1);
    const timelineStart = contextTimelineStart(parent, attrs);
    const start = attrs.start == null ? Number(parent?.start) || 0 : parseTime(attrs.start);
    const duration = attrs.duration == null ? Number(parent?.duration) || 0 : parseTime(attrs.duration);
    const inheritedRole = trim(parent?.role);
    const role = trim(attrs.role || attrs.audioRole || inheritedRole);
    const enabled = attrs.enabled !== "0" && attrs.active !== "0";
    const node = { tag, attrs, timelineStart, start, duration, role };

    const audioOnlyClip = ["asset-clip", "ref-clip", "mc-clip"].includes(tag) && attrs.srcEnable === "audio";
    if ((tags.has(tag) || audioOnlyClip) && enabled && role && duration > 0) {
      intervals.push({
        timelineStartSeconds: timelineStart,
        timelineEndSeconds: timelineStart + duration,
        role,
        sourceTag: tag,
      });
    }
    if (!isSelfClosingTag(attrText, selfClosing)) stack.push(node);
  }

  const seen = new Set();
  const uniqueIntervals = intervals.filter((item) => {
    const key = `${item.role}|${item.timelineStartSeconds.toFixed(6)}|${item.timelineEndSeconds.toFixed(6)}`;
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  }).sort((a, b) => a.timelineStartSeconds - b.timelineStartSeconds || a.role.localeCompare(b.role));

  return mergeAudioRoleIntervals(uniqueIntervals)
    .filter((item) => item.timelineEndSeconds > timelineStartSeconds && item.timelineStartSeconds < timelineEndSeconds);
}

function mergeAudioRoleIntervals(intervals) {
  const tolerance = 1 / 240;
  const sorted = [...intervals].sort((a, b) => (
    a.role.localeCompare(b.role)
    || a.timelineStartSeconds - b.timelineStartSeconds
    || a.timelineEndSeconds - b.timelineEndSeconds
  ));
  const merged = [];
  for (const interval of sorted) {
    const last = merged.at(-1);
    if (
      last
      && last.role === interval.role
      && last.sourceTag === interval.sourceTag
      && interval.timelineStartSeconds <= last.timelineEndSeconds + tolerance
    ) {
      last.timelineEndSeconds = Math.max(last.timelineEndSeconds, interval.timelineEndSeconds);
      continue;
    }
    merged.push({ ...interval });
  }
  return merged.sort((a, b) => a.timelineStartSeconds - b.timelineStartSeconds || a.role.localeCompare(b.role));
}

function defaultPreset() {
  return {
    name: "Editorial Review",
    layerPolicy: "primary-storyline-then-connected-layers-upward",
    fields: [
      { id: "timeline-tc", name: "Timeline TC", enabled: true, template: "{timeline_tc}", anchor: "top-right", x: -48, y: 36 },
      { id: "source", name: "Source", enabled: true, template: "{source_file}  {source_tc}", anchor: "bottom-left", x: 48, y: -36 },
      { id: "project", name: "Project", enabled: true, template: "{project}", anchor: "top-left", x: 48, y: 36 },
      { id: "vfx", name: "VFX Number", enabled: true, template: "{vfx_number}", anchor: "bottom-right", x: -48, y: -36 },
      { id: "audio-role", name: "Audio Role Message", enabled: false, template: "{custom_text}", customText: "TEMP AUDIO", anchor: "top-center", x: 0, y: 36, condition: { property: "audio_role", operator: "contains", value: "Dialogue" } },
    ],
  };
}

const TOP_LEVEL_MEDIA_TAGS = new Set(["video", "clip", "mc-clip", "ref-clip", "sync-clip", "asset-clip"]);
const SOURCE_CONTAINER_TAGS = new Set(["clip", "asset-clip", "ref-clip", "sync-clip"]);

function isDirectVideoPayload(node, parent) {
  return trim(node?.tag).toLowerCase() === "video"
    && SOURCE_CONTAINER_TAGS.has(trim(parent?.tag).toLowerCase());
}

function isNestedCompositeVideoLayer(node, body = "", rootLayerRole = "") {
  const tag = trim(node?.tag).toLowerCase();
  if (rootLayerRole !== "primary") return false;
  if (!TOP_LEVEL_MEDIA_TAGS.has(tag)) return false;
  return ownVisibleVideoLane(node?.attrs) !== "";
}

function ownVisibleVideoLane(attrs = {}) {
  const lane = trim(attrs?._own_lane ?? attrs?.lane);
  if (!lane) return "";
  const laneNumber = Number(lane);
  if (!Number.isFinite(laneNumber) || laneNumber <= 0) return "";
  return lane;
}

function effectiveLayerRole(attrs = {}, fallbackRole = "primary") {
  return ownVisibleVideoLane(attrs) ? "connected" : (trim(attrs?._timeline_layer_role) || fallbackRole);
}

function effectiveTimelineLane(attrs = {}, fallbackLane = "") {
  return ownVisibleVideoLane(attrs) || trim(attrs?._timeline_lane) || fallbackLane;
}

function collectConformStyleSourceSegments(node, body = "", assetMap, timelineFrameDuration) {
  const segments = [];
  const rootLayerRole = trim(node?.attrs?._timeline_layer_role) || (node?.attrs?.lane != null ? "connected" : "primary");
  const rootTimelineLane = trim(node?.attrs?._timeline_lane ?? node?.attrs?.lane);

  function mappedTime(timeMap, localTime) {
    if (timeMap?.length >= 2) {
      const value = interpolateTimeMap(timeMap, floatToTime(localTime));
      if (value) return timeToFloat(value);
    }
    return localTime;
  }

  function addSegment(segmentNode, segmentBody = "") {
    const source = resolveSourceInfo(segmentNode, assetMap, segmentBody);
    const tag = trim(segmentNode?.tag).toLowerCase();
    const hasOwnRef = trim(segmentNode?.attrs?.ref) !== "";
    if (!isOriginalVideoSegment(segmentNode, source)) return;
    if (["clip", "asset-clip", "ref-clip"].includes(tag) && !hasOwnRef && hasNestedContainerChildren(segmentBody) && !hasDirectVideoPayload(segmentBody)) return;
    if (directMediaChildUsesNonVideoRole(segmentBody)) return;

    const timelineStart = Number(segmentNode.timelineStart) || 0;
    const duration = Number(segmentNode.duration) || 0;
    if (duration <= 0) return;
    const localStart = segmentNode.start ?? source.sourceTcSeconds ?? 0;
    const timeMap = parseDirectTimeMapXML(segmentBody);
    const sourceAtTimelineSeconds = (absoluteSeconds) => {
      const localTime = localStart + (Number(absoluteSeconds) - timelineStart);
      if (timeMap?.length >= 2) {
        const value = interpolateTimeMap(timeMap, floatToTime(localTime));
        if (value) return timeToFloat(value);
      }
      return (source.sourceTcSeconds || 0) + (Number(absoluteSeconds) - timelineStart);
    };
    const sourceInSeconds = sourceAtTimelineSeconds(timelineStart);
    const sourceOutSeconds = sourceAtTimelineSeconds(timelineStart + duration);
    const metadata = metadataSummaryForSegment(source, parseMetadataEntries(segmentBody));

    segments.push({
      sourceKey: trim(source.ref) || trim(source.sourceFilename),
      timelineStart,
      timelineEnd: timelineStart + duration,
      clipName: trim(segmentNode?.attrs?.name),
      sourceFilename: trim(source.sourceFilename),
      sourceName: metadata.sourceName,
      sourceInSeconds,
      sourceOutSeconds,
      sourceFrameDuration: Number(source.sourceFrameDuration) || timelineFrameDuration,
      sourceFrameRate: formatFrameRate(Number(source.sourceFrameDuration) || timelineFrameDuration),
      sourceTcFormat: trim(source.sourceTcFormat),
      layerRole: effectiveLayerRole(segmentNode?.attrs, rootLayerRole),
      timelineLane: effectiveTimelineLane(segmentNode?.attrs, rootTimelineLane),
      nestingDepth: Number(segmentNode?.attrs?._timeline_depth) || 0,
      metadata,
      sourceAtTimelineSeconds,
      timeMapDomainStart: localStart,
      timeMapPointCount: timeMap?.length || 0,
      timeMapPoints: (timeMap || []).map((point) => ({
        time: timeToFloat(point.time),
        value: timeToFloat(point.value),
        interp: point.interp || "",
        inTime: point.inTime ? timeToFloat(point.inTime) : null,
        outTime: point.outTime ? timeToFloat(point.outTime) : null,
      })),
    });
  }

  function addNestedChildSegment(child, childBody = "") {
    const source = resolveSourceInfo(child, assetMap, childBody);
    if (!isOriginalVideoSegment(child, source)) return;
    if (directMediaChildUsesNonVideoRole(childBody)) return;

    const parentTimelineStart = Number(node.timelineStart) || 0;
    const parentTimelineEnd = parentTimelineStart + (Number(node.duration) || 0);
    const parentLocalStart = Number(node.start) || 0;
    const parentTimeMap = parseDirectTimeMapXML(body);
    const childOffset = child.attrs.offset == null ? Number(child.start) || 0 : parseTime(child.attrs.offset);
    const childDuration = Number(child.duration) || 0;
    if (childDuration <= 0) return;

    // Retimed sync clips use the parent's timeMap to project visible timeline
    // time into the nested source. In those cases the child offset is source
    // space, not a reliable visible overlap boundary in parent local space.
    const hasParentTimeMap = parentTimeMap?.length >= 2;
    const timelineStart = hasParentTimeMap
      ? parentTimelineStart
      : Math.max(parentTimelineStart, parentTimelineStart + (childOffset - parentLocalStart));
    const timelineEnd = hasParentTimeMap
      ? parentTimelineEnd
      : Math.min(parentTimelineEnd, parentTimelineStart + ((childOffset + childDuration) - parentLocalStart));
    if (timelineEnd <= timelineStart) return;

    const childTimeMap = parseDirectTimeMapXML(childBody);
    const childStart = Number(child.start ?? source.sourceTcSeconds) || 0;
    const sourceAtTimelineSeconds = (absoluteSeconds) => {
      const parentLocalTime = parentLocalStart + (Number(absoluteSeconds) - parentTimelineStart);
      const childTimelineTime = mappedTime(parentTimeMap, parentLocalTime);
      const childLocalTime = childStart + (childTimelineTime - childOffset);
      if (childTimeMap?.length >= 2) return mappedTime(childTimeMap, childLocalTime);
      return childLocalTime;
    };
    const sourceInSeconds = sourceAtTimelineSeconds(timelineStart);
    const sourceOutSeconds = sourceAtTimelineSeconds(timelineEnd);
    const metadata = metadataSummaryForSegment(source, parseMetadataEntries(childBody));

    segments.push({
      sourceKey: trim(source.ref) || trim(source.sourceFilename),
      timelineStart,
      timelineEnd,
      clipName: trim(child?.attrs?.name || node?.attrs?.name),
      sourceFilename: trim(source.sourceFilename),
      sourceName: metadata.sourceName,
      sourceInSeconds,
      sourceOutSeconds,
      sourceFrameDuration: Number(source.sourceFrameDuration) || timelineFrameDuration,
      sourceFrameRate: formatFrameRate(Number(source.sourceFrameDuration) || timelineFrameDuration),
      sourceTcFormat: trim(source.sourceTcFormat),
      layerRole: effectiveLayerRole(child?.attrs, rootLayerRole),
      timelineLane: effectiveTimelineLane(child?.attrs, rootTimelineLane),
      nestingDepth: Number(child?.attrs?._timeline_depth) || 0,
      metadata,
      sourceAtTimelineSeconds,
      timeMapDomainStart: parentLocalStart,
      timeMapPointCount: (parentTimeMap?.length || 0) + (childTimeMap?.length || 0),
      timeMapPoints: (parentTimeMap || []).map((point) => ({
        time: timeToFloat(point.time),
        value: timeToFloat(point.value),
        interp: point.interp || "",
        inTime: point.inTime ? timeToFloat(point.inTime) : null,
        outTime: point.outTime ? timeToFloat(point.outTime) : null,
      })),
    });
  }

  const hasNestedChildren = hasNestedContainerChildren(body);
  if (TOP_LEVEL_MEDIA_TAGS.has(node?.tag) && (!hasNestedChildren || hasDirectVideoPayload(body))) addSegment(node, body);

  const stack = [];
  const tagRegex = /<(\/?)([\w:_-]+)(.*?)(\/?)>/gs;
  let match;
  while ((match = tagRegex.exec(body))) {
    const [, closing, tagName, attrText, selfClosing] = match;
    if (closing !== "/") {
      const attrs = parseAttrs(attrText);
      const parent = stack.at(-1);
      const explicitRole = trim(attrs.role);
      const parentRole = trim(parent?.attrs?._effective_role || parent?.effectiveRole);
      attrs._effective_role = explicitRole || parentRole;
      const explicitTcFormat = trim(attrs.tcFormat);
      const parentTcFormat = trim(parent?.attrs?._effective_tcFormat || parent?.effectiveTcFormat);
      attrs._effective_tcFormat = explicitTcFormat || parentTcFormat;
      const parentLayerRole = trim(parent?.attrs?._timeline_layer_role);
      const parentTimelineLane = trim(parent?.attrs?._timeline_lane);
      const parentDepth = Number(parent?.attrs?._timeline_depth) || 0;
      attrs._timeline_layer_role = parentLayerRole || rootLayerRole;
      attrs._timeline_lane = parentTimelineLane || rootTimelineLane;
      attrs._own_lane = attrs.lane != null ? trim(attrs.lane) : "";
      attrs._timeline_depth = String(parentDepth + 1);
      const child = {
        tag: tagName,
        attrs,
        timelineStart: contextTimelineStart(parent || node, attrs),
        start: attrs.start == null ? (parent?.start ?? node?.start ?? 0) : parseTime(attrs.start),
        duration: attrs.duration == null ? 0 : parseTime(attrs.duration),
        openEnd: tagRegex.lastIndex,
      };
      if (!isSelfClosingTag(attrText, selfClosing)) stack.push(child);
      else if (TOP_LEVEL_MEDIA_TAGS.has(tagName)) {
        if (isDirectVideoPayload(child, parent || node)) continue;
        if (hasNestedChildren) addNestedChildSegment(child, "");
        else addSegment(child, "");
      }
    } else {
      const child = stack.pop();
      if (child && TOP_LEVEL_MEDIA_TAGS.has(child.tag)) {
      const parent = stack.at(-1);
      const childBody = body.slice(child.openEnd, match.index);
      if (isNestedCompositeVideoLayer(child, childBody, rootLayerRole)) {
        child.attrs._timeline_layer_role = "connected";
        child.attrs._timeline_lane = trim(child.attrs._own_lane) || child.attrs._timeline_lane;
      }
      if (isDirectVideoPayload(child, parent || node)) continue;
      if (hasNestedChildren) addNestedChildSegment(child, childBody);
      else addSegment(child, childBody);
    }
    }
  }

  return segments;
}

function collectVisibleSourceSegments(xml, assetMap, timelineFrameDuration) {
  const segments = [];
  const stack = [];
  const tagRegex = /<(\/?)([\w:_-]+)(.*?)(\/?)>/gs;
  let match;

  while ((match = tagRegex.exec(xml))) {
    const [, closing, tagName, attrText, selfClosing] = match;
    if (closing !== "/") {
      const attrs = parseAttrs(attrText);
      const parent = stack.at(-1);
      const timelineStart = contextTimelineStart(parent, attrs);
      const isPrimaryTimelineMedia = TOP_LEVEL_MEDIA_TAGS.has(tagName)
        && parent?.tag === "spine"
        && parent?.isPrimaryTimelineSpine === true;
      const parentLayerRole = trim(parent?.attrs?._timeline_layer_role);
      const parentTimelineLane = trim(parent?.attrs?._timeline_lane);
      const parentDepth = Number(parent?.attrs?._timeline_depth) || 0;
      attrs._timeline_layer_role = attrs.lane != null
        ? "connected"
        : (isPrimaryTimelineMedia ? "primary" : (parentLayerRole || "primary"));
      attrs._timeline_lane = attrs.lane != null ? trim(attrs.lane) : parentTimelineLane;
      attrs._timeline_depth = String(parentDepth + 1);
      const node = {
        tag: tagName,
        attrs,
        timelineStart,
        start: attrs.start == null ? Number(parent?.start) || 0 : parseTime(attrs.start),
        duration: attrs.duration == null ? Number(parent?.duration) || 0 : parseTime(attrs.duration),
        isPrimaryTimelineSpine: tagName === "spine" && parent && ["sequence", "project"].includes(parent.tag),
        openEnd: tagRegex.lastIndex,
      };
      const isTopLevelTimelineMedia = isPrimaryTimelineMedia;

      if (!isSelfClosingTag(attrText, selfClosing)) {
        stack.push(node);
      } else if (isTopLevelTimelineMedia) {
        segments.push(...collectConformStyleSourceSegments(node, "", assetMap, timelineFrameDuration));
      }
      continue;
    }

    const node = stack.pop();
    const parent = stack.at(-1);
    const isTopLevelTimelineMedia = node
      && TOP_LEVEL_MEDIA_TAGS.has(node.tag)
      && parent?.tag === "spine"
      && parent?.isPrimaryTimelineSpine === true;
    if (isTopLevelTimelineMedia) {
      const body = xml.slice(node.openEnd, match.index);
      segments.push(...collectConformStyleSourceSegments(
        node,
        body,
        assetMap,
        timelineFrameDuration
      ));
    }
  }

  const seen = new Set();
  return segments
    .filter((segment) => Number(segment.timelineEnd) > Number(segment.timelineStart))
    .filter((segment) => {
      const key = [
        Number(segment.timelineStart).toFixed(6),
        Number(segment.timelineEnd).toFixed(6),
        trim(segment.sourceFilename),
        Number(segment.sourceInSeconds).toFixed(6),
        Number(segment.sourceOutSeconds).toFixed(6),
      ].join("|");
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    })
    .sort((a, b) => (
      (Number(a.timelineStart) || 0) - (Number(b.timelineStart) || 0)
      || (Number(a.timelineEnd) || 0) - (Number(b.timelineEnd) || 0)
    ));
}

function buildFrameSamples(videoSegments, timeline, maxFrames = 250000) {
  const frameDuration = Number(timeline.frameDurationSeconds) || (1 / 24);
  const boundaryEpsilon = frameDuration / 1000;
  const startSeconds = Number(timeline.startSeconds) || 0;
  const durationSeconds = Number(timeline.durationSeconds) || 0;
  if (frameDuration <= 0 || durationSeconds <= 0) return [];
  const frameCount = Math.min(Math.ceil(durationSeconds / frameDuration), maxFrames);
  const sortedSegments = [...videoSegments].sort((a, b) => (
    (a.timelineStartSeconds || 0) - (b.timelineStartSeconds || 0)
    || (a.timelineEndSeconds || 0) - (b.timelineEndSeconds || 0)
  ));
  const samples = [];
  let segmentIndex = 0;
  for (let frame = 0; frame < frameCount; frame += 1) {
    const absoluteSeconds = startSeconds + (frame * frameDuration);
    while (
      segmentIndex < sortedSegments.length - 1
      && absoluteSeconds >= ((sortedSegments[segmentIndex].timelineEndSeconds || 0) - boundaryEpsilon)
    ) {
      segmentIndex += 1;
    }
    let segment = sortedSegments[segmentIndex];
    if (
      !segment
      || absoluteSeconds + boundaryEpsilon < (segment.timelineStartSeconds || 0)
      || absoluteSeconds >= ((segment.timelineEndSeconds || 0) - boundaryEpsilon)
    ) {
      segment = sortedSegments.find((candidate) => (
        absoluteSeconds + boundaryEpsilon >= (candidate.timelineStartSeconds || 0)
        && absoluteSeconds < ((candidate.timelineEndSeconds || 0) - boundaryEpsilon)
      ));
    }
    const activeLayers = sortedSegments.filter((candidate) => (
      absoluteSeconds + boundaryEpsilon >= (candidate.timelineStartSeconds || 0)
      && absoluteSeconds < ((candidate.timelineEndSeconds || 0) - boundaryEpsilon)
    ));
    if (activeLayers.length > 0) segment = activeLayers[activeLayers.length - 1];
    if (!segment) continue;
    if (!activeLayers.some((layer) => Number(layer.timeMapPointCount) > 1)) continue;
    const resolveLayer = (layer, layerIndex) => {
      const span = Math.max((layer.timelineEndSeconds || 0) - (layer.timelineStartSeconds || 0), 0);
      const ratio = span > 0 ? (absoluteSeconds - (layer.timelineStartSeconds || 0)) / span : 0;
      const mappedSourceSeconds = typeof layer.sourceAtTimelineSeconds === "function"
        ? layer.sourceAtTimelineSeconds(absoluteSeconds)
        : null;
      return {
        layerIndex,
        segmentIndex: Number(layer.index) || 0,
        clipName: trim(layer.clipName),
        sourceFilename: trim(layer.sourceFilename),
        sourceName: trim(layer.sourceName),
        layerRole: trim(layer.layerRole) || "primary",
        timelineLane: trim(layer.timelineLane),
        nestingDepth: Number(layer.nestingDepth) || 0,
        sourceFrameDuration: Number(layer.sourceFrameDuration) || null,
        sourceFrameRate: trim(layer.sourceFrameRate),
        sourceTcFormat: trim(layer.sourceTcFormat),
        metadata: layer.metadata || null,
        sourceSeconds: Number.isFinite(mappedSourceSeconds)
          ? mappedSourceSeconds
          : (Number(layer.sourceInSeconds) || 0)
            + (((Number(layer.sourceOutSeconds) || 0) - (Number(layer.sourceInSeconds) || 0)) * ratio),
        resolver: Number(layer.timeMapPointCount) > 1 ? "timeMap" : "linear",
      };
    };
    const visibleLayers = activeLayers.length > 6
      ? [resolveLayer(segment, 0)]
      : activeLayers.map(resolveLayer);
    const primaryLayer = resolveLayer(segment, Math.max(visibleLayers.length - 1, 0));
    samples.push({
      frame,
      timelineSeconds: absoluteSeconds,
      segmentIndex: primaryLayer.segmentIndex,
      sourceSeconds: primaryLayer.sourceSeconds,
      visibleLayers,
    });
  }
  return samples;
}

function retimeSummary(segment) {
  const points = segment.timeMapPoints || [];
  if (points.length < 2) return "";
  const intervals = retimeIntervals(segment);
  const speeds = intervals.length > 0
    ? intervals.map((interval) => interval.speed)
    : retimePointSpeeds(points);
  if (speeds.length === 0) return "";
  const steps = [];
  for (const speed of speeds) {
    const normalized = normalizeRetimeSpeed(speed);
    const previous = steps.at(-1);
    if (previous == null || Math.abs(previous - normalized) > 1) steps.push(normalized);
  }
  if (steps.every((speed) => Math.abs(speed - 100) <= 1)) return "";
  if (steps.every((speed) => Math.abs(speed) <= 1)) return "Hold";
  const formatSpeed = (speed) => `${speed}%`;
  if (steps.length > 1) return `Speed Ramp ${steps.map(formatSpeed).join(" -> ")}`;
  return `Speed ${formatSpeed(steps[0])}`;
}

function retimePointSpeeds(points) {
  const speeds = [];
  for (let index = 0; index < points.length - 1; index += 1) {
    const a = points[index];
    const b = points[index + 1];
    const dt = Number(b.time) - Number(a.time);
    const dv = Number(b.value) - Number(a.value);
    if (!Number.isFinite(dt) || Math.abs(dt) < 0.000001 || !Number.isFinite(dv)) continue;
    speeds.push(dv / dt);
  }
  return speeds;
}

function normalizeRetimeSpeed(speed) {
  const percent = speed * 100;
  if (Math.abs(percent) < 0.5) return 0;
  if (Math.abs(percent - 100) < 1) return 100;
  if (Math.abs(percent + 100) < 1) return -100;
  return Math.round(percent);
}

function retimeIntervals(segment) {
  const points = segment.timeMapPoints || [];
  if (points.length < 2) return [];
  const intervals = [];
  const timelineStart = Number(segment.timelineStartSeconds) || 0;
  const timelineEnd = Number(segment.timelineEndSeconds) || timelineStart;
  const domainStart = Number.isFinite(Number(segment.timeMapDomainStart))
    ? Number(segment.timeMapDomainStart)
    : Number(points[0]?.time) || 0;
  for (let index = 0; index < points.length - 1; index += 1) {
    const a = points[index];
    const b = points[index + 1];
    const dt = Number(b.time) - Number(a.time);
    const dv = Number(b.value) - Number(a.value);
    if (!Number.isFinite(dt) || Math.abs(dt) < 0.000001 || !Number.isFinite(dv)) continue;
    const start = Math.max(timelineStart, timelineStart + (Number(a.time) - domainStart));
    const end = Math.min(timelineEnd, timelineStart + (Number(b.time) - domainStart));
    if (end <= start) continue;
    intervals.push({ start, end, speed: dv / dt });
  }
  return intervals;
}

function retimeIntervalLabel(speed) {
  const normalized = normalizeRetimeSpeed(speed);
  if (Math.abs(normalized - 100) <= 1) return "";
  if (Math.abs(normalized) <= 1) return "Hold";
  return `Speed ${normalized}%`;
}

function retimeAnalysisItems(videoSegments) {
  return videoSegments
    .filter((segment) => Number(segment.timeMapPointCount) > 1)
    .flatMap((segment) => {
      const summary = retimeSummary(segment);
      if (summary.startsWith("Speed Ramp")) {
        return [{
          segment,
          interval: {
            value: summary,
            start: Number(segment.timelineStartSeconds) || 0,
            end: Number(segment.timelineEndSeconds) || 0,
          },
        }];
      }
      const intervals = retimeIntervals(segment)
        .map((interval) => ({ ...interval, value: retimeIntervalLabel(interval.speed) }))
        .filter((interval) => interval.value);
      if (intervals.length === 0) {
        const value = summary;
        return value ? [{
          segment,
          interval: {
            value,
            start: Number(segment.timelineStartSeconds) || 0,
            end: Number(segment.timelineEndSeconds) || 0,
          },
        }] : [];
      }
      return intervals.map((interval) => ({ segment, interval }));
    })
    .map(({ segment, interval }) => ({
      label: "Retime",
      key: "retime",
      value: interval.value,
      owner: trim(segment.clipName) || trim(segment.sourceFilename) || "timeline",
      ownerName: trim(segment.clipName) || trim(segment.sourceName) || trim(segment.sourceFilename),
      detail: "retime timeMap",
      timelineStartSeconds: Number(interval.start) || 0,
      timelineEndSeconds: Number(interval.end) || 0,
    }));
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const xml = await fs.readFile(args.sourceXml, "utf8");
  const projectXml = extractFirstElement(xml, "project") || xml;
  const sequenceXml = extractFirstElement(projectXml, "sequence") || projectXml;
  const formats = parseFormats(xml);
  const assets = parseAssets(xml, formats);
  const frameDuration = parseSequenceFrameDuration(sequenceXml, formats);
  const sequenceAttrs = parseAttrs(sequenceXml.match(/<sequence\b([^>]*)>/s)?.[1] || "");
  const sequenceFormat = formats[trim(sequenceAttrs.format)] || {};
  const projectName = trim(projectXml.match(/<project\b[^>]*name="([^"]+)"/s)?.[1]);
  const eventName = trim(xml.match(/<event\b[^>]*name="([^"]+)"/s)?.[1]);
  const sourceSegments = collectVisibleSourceSegments(sequenceXml, assets, frameDuration);
  const videoSegments = sourceSegments.map((segment, index) => ({
    index,
    timelineStartSeconds: Number(segment.timelineStart) || 0,
    timelineEndSeconds: Number(segment.timelineEnd) || 0,
    clipName: trim(segment.clipName),
    sourceFilename: trim(segment.sourceFilename),
    sourceName: trim(segment.sourceName),
    sourceInSeconds: Number(segment.sourceInSeconds) || 0,
    sourceOutSeconds: Number(segment.sourceOutSeconds) || 0,
    sourceFrameDuration: Number(segment.sourceFrameDuration) || frameDuration,
    sourceFrameRate: trim(segment.sourceFrameRate),
    sourceTcFormat: trim(segment.sourceTcFormat),
    layerRole: trim(segment.layerRole) || "primary",
    timelineLane: trim(segment.timelineLane),
    nestingDepth: Number(segment.nestingDepth) || 0,
    metadata: segment.metadata || {},
    sourceAtTimelineSeconds: segment.sourceAtTimelineSeconds,
    timeMapDomainStart: Number(segment.timeMapDomainStart),
    timeMapPointCount: Number(segment.timeMapPointCount) || 0,
    timeMapPoints: segment.timeMapPoints || [],
  }));
  const vfxTitles = collectGlobalVfxTitles(sequenceXml).map((title) => ({
    timelineStartSeconds: Number(title.timelineStart) || 0,
    timelineEndSeconds: Number(title.timelineEnd) || 0,
    vfxNumber: trim(title.vfxNumber),
    note: trim(title.note),
  }));
  const timelineStartSeconds = parseTime(sequenceAttrs.tcStart);
  const timelineDurationSeconds = parseTime(sequenceAttrs.duration);
  const audioRoles = collectAudioRoleIntervals(sequenceXml, timelineStartSeconds, timelineStartSeconds + timelineDurationSeconds);
  const timeline = {
    startSeconds: timelineStartSeconds,
    durationSeconds: timelineDurationSeconds,
    frameDurationSeconds: frameDuration,
    frameRate: formatFrameRate(frameDuration),
    tcFormat: trim(sequenceAttrs.tcFormat || "NDF"),
    width: Number(sequenceFormat.width) || 0,
    height: Number(sequenceFormat.height) || 0,
    colorSpace: trim(sequenceFormat.colorSpace),
    formatName: trim(sequenceFormat.name),
  };
  const analysisItems = [
    ...collectAnalysisItems(sequenceXml, timeline.frameDurationSeconds, timeline),
    ...retimeAnalysisItems(videoSegments),
  ];
  const frameSamples = buildFrameSamples(videoSegments, timeline);
  const manifest = {
    schemaVersion: 1,
    kind: "visible-frame-index",
    project: projectName,
    event: eventName,
    resolver: "visible-frame-index-segment-sampled-v1",
    timeline,
    supportedTokens: [
      "project",
      "event",
      "timeline_tc",
      "timeline_frame",
      "timeline_fps",
      "source_tc",
      "source_frame",
      "source_file",
      "source_fps",
      "clip_name",
      "source_name",
      "source_reel",
      "source_scene",
      "source_take",
      "source_camera",
      "source_angle",
      "metadata_custom",
      "metadata_all",
      "source_layers",
      "source_layers_tc",
      "source_layers_details",
      "vfx_number",
      "vfx_note",
      "audio_role",
      "analysis_flags",
      "analysis_effects",
      "analysis_transform",
      "analysis_transform_position",
      "analysis_transform_scale",
      "analysis_transform_rotation",
      "analysis_crop",
      "analysis_distort",
      "analysis_spatial_conform",
      "analysis_conform_rate",
      "analysis_retime",
      "analysis_stabilization",
      "analysis_optical_flow",
      "analysis_details",
      "custom_text",
    ],
    videoSegments,
    vfxTitles,
    audioRoles,
    analysisItems,
    frameSamples,
    preset: defaultPreset(),
  };

  await fs.mkdir(path.dirname(args.outputManifest), { recursive: true });
  await fs.mkdir(path.dirname(args.report), { recursive: true });
  await fs.writeFile(args.outputManifest, `${JSON.stringify(manifest, null, 2)}\n`);
  await fs.writeFile(args.report, [
    `source_xml\t${args.sourceXml}`,
    `project\t${projectName}`,
    `timeline_duration_seconds\t${manifest.timeline.durationSeconds}`,
    `frame_duration_seconds\t${frameDuration}`,
    `frame_size\t${manifest.timeline.width}x${manifest.timeline.height}`,
    `color_space\t${manifest.timeline.colorSpace || "unknown"}`,
    `video_segments\t${videoSegments.length}`,
    `frame_samples\t${frameSamples.length}`,
    `vfx_titles\t${vfxTitles.length}`,
    `audio_role_intervals\t${audioRoles.length}`,
    `analysis_items\t${analysisItems.length}`,
    `visible_frame_index\t${args.outputManifest}`,
  ].join("\n") + "\n");
  console.log(JSON.stringify({ status: "ok", video_segments: videoSegments.length, frame_samples: frameSamples.length, vfx_titles: vfxTitles.length, audio_roles: audioRoles.length, manifest_path: args.outputManifest, report_path: args.report }));
}

main().catch((error) => {
  console.error(error.stack || String(error));
  process.exit(1);
});
