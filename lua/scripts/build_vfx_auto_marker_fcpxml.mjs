import fs from "node:fs/promises";
import { existsSync } from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import os from "node:os";
import { spawnSync } from "node:child_process";

function usage() {
  console.log(`Usage:
  node lua/scripts/build_vfx_auto_marker_fcpxml.mjs \\
    --source-xml <path> \\
    --output-xml <path> \\
    --report <path> \\
    --marker-kind <standard|todo|chapter> \\
    [--rename-markers <true|false>]`);
}

function parseArgs(argv) {
  const args = { markerKind: "standard", renameMarkers: false };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--source-xml") args.sourceXml = path.resolve(argv[++index]);
    else if (arg === "--output-xml") args.outputXml = path.resolve(argv[++index]);
    else if (arg === "--report") args.report = path.resolve(argv[++index]);
    else if (arg === "--marker-kind") args.markerKind = String(argv[++index] || "").toLowerCase();
    else if (arg === "--rename-markers") args.renameMarkers = /^(1|true|yes)$/i.test(argv[++index] || "");
    else if (arg === "--help" || arg === "-h") {
      usage();
      process.exit(0);
    } else throw new Error(`Unknown argument: ${arg}`);
  }
  if (!args.sourceXml || !args.outputXml || !args.report) {
    usage();
    throw new Error("Missing required arguments.");
  }
  if (!["standard", "todo", "chapter"].includes(args.markerKind)) {
    throw new Error("--marker-kind must be standard, todo, or chapter.");
  }
  return args;
}

function trim(value) {
  return String(value ?? "").trim();
}

function parseAttrs(source = "") {
  const attrs = {};
  for (const match of source.matchAll(/([\w:_-]+)\s*=\s*"([^"]*)"/g)) attrs[match[1]] = match[2];
  return attrs;
}

function parseTime(value) {
  const raw = trim(value).replace(/s$/, "");
  if (!raw) return null;
  if (raw.includes("/")) {
    const [numerator, denominator] = raw.split("/").map(Number);
    return Number.isFinite(numerator) && Number.isFinite(denominator) && denominator !== 0
      ? numerator / denominator
      : null;
  }
  const seconds = Number(raw);
  return Number.isFinite(seconds) ? seconds : null;
}

function formatSeconds(seconds) {
  const rounded = Math.round(seconds * 1_000_000) / 1_000_000;
  return `${String(rounded).replace(/\.?0+$/, "") || "0"}s`;
}

function gcdBigInt(a, b) {
  let x = a < 0n ? -a : a;
  let y = b < 0n ? -b : b;
  while (y !== 0n) [x, y] = [y, x % y];
  return x || 1n;
}

function snapToFrameTime(seconds, frameDuration) {
  const match = /^(-?\d+)\/(\d+)s$/.exec(frameDuration);
  const whole = /^(-?\d+)s$/.exec(frameDuration);
  const frameSeconds = parseTime(frameDuration);
  if (!frameSeconds || (!match && !whole)) return formatSeconds(seconds);
  const frames = BigInt(Math.round(seconds / frameSeconds));
  let numerator = frames * BigInt(match ? match[1] : whole[1]);
  let denominator = BigInt(match ? match[2] : 1);
  const divisor = gcdBigInt(numerator, denominator);
  numerator /= divisor;
  denominator /= divisor;
  return denominator === 1n ? `${numerator}s` : `${numerator}/${denominator}s`;
}

function escapeAttr(value) {
  return String(value ?? "")
    .replace(/&/g, "&amp;")
    .replace(/"/g, "&quot;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/'/g, "&apos;");
}

function unescapeXML(value) {
  return String(value ?? "")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&amp;/g, "&");
}

function extractText(inner = "") {
  const parts = [...inner.matchAll(/<text-style[^>]*>(.*?)<\/text-style>/gs)]
    .map((match) => trim(unescapeXML(match[1])))
    .filter(Boolean);
  return parts.join("\n");
}

function splitLines(value) {
  return String(value || "")
    .replace(/\u2028/g, "\n")
    .replace(/\r\n?/g, "\n")
    .split("\n")
    .map(trim)
    .filter(Boolean);
}

function isVFXTitle(name, text) {
  const firstLine = splitLines(text)[0] || "";
  return name.toLowerCase().includes("vfx naming") ||
    /^[A-Z0-9_-]+_(?:\d{4}|XXXX)$/.test(firstLine);
}

function markerIdentity(name, text) {
  const lines = splitLines(text);
  const fromName = /^([A-Z0-9_-]+)\s*-\s*VFX\s+NAMING$/i.exec(name)?.[1] || "";
  return {
    name: lines[0] || fromName || name || "Marker 1",
    note: lines.slice(1).join("\n"),
  };
}

function parseTimeline(xml) {
  const stack = [];
  const titles = [];
  const primaryItems = [];
  const allItems = [];
  const tagRegex = /<(\/?)([\w:_-]+)(.*?)(\/?)>/gs;
  let match;
  while ((match = tagRegex.exec(xml))) {
    const [, closing, tag, attrSource, selfClosing] = match;
    if (closing !== "/") {
      const attrs = parseAttrs(attrSource);
      const parent = stack.at(-1) || null;
      const offset = parseTime(attrs.offset) ?? 0;
      const start = parseTime(attrs.start) ?? 0;
      const duration = parseTime(attrs.duration) ?? 0;
      const absTime = (parent?.absTime ?? 0) + offset - (parent?.start ?? 0);
      const node = {
        tag,
        attrs,
        parent,
        start,
        duration,
        absTime,
        openStart: match.index,
        openEnd: tagRegex.lastIndex,
        closeStart: selfClosing === "/" ? tagRegex.lastIndex : null,
        closeEnd: selfClosing === "/" ? tagRegex.lastIndex : null,
        selfClosing: selfClosing === "/",
      };
      if (
        parent?.tag === "spine" &&
        parent?.parent?.tag === "sequence" &&
        ["clip", "asset-clip", "ref-clip", "sync-clip", "gap", "video"].includes(tag)
      ) {
        primaryItems.push(node);
      }
      if (["clip", "asset-clip", "ref-clip", "sync-clip", "video", "title"].includes(tag)) {
        allItems.push(node);
      }
      if (selfClosing !== "/") stack.push(node);
    } else {
      const node = stack.pop();
      if (!node || node.tag !== tag) continue;
      node.closeStart = match.index;
      node.closeEnd = tagRegex.lastIndex;
      if (tag === "title") {
        const inner = xml.slice(node.openEnd, match.index);
        const text = extractText(inner);
        const name = unescapeXML(node.attrs.name || "");
        if (isVFXTitle(name, text)) {
          titles.push({
            ...markerIdentity(name, text),
            titleName: name,
            timelineTime: node.absTime + node.duration / 2,
          });
        }
      }
    }
  }
  return { titles, primaryItems, allItems };
}

function markerXML(event, owner, kind, rename, frameDuration) {
  const localStart = owner.start + (event.timelineTime - owner.absTime);
  const markerStart = snapToFrameTime(localStart, frameDuration);
  const value = rename ? event.name : "Marker 1";
  const attrs = [
    `start="${escapeAttr(markerStart)}"`,
    `duration="${escapeAttr(frameDuration)}"`,
    `value="${escapeAttr(value)}"`,
  ];
  if (kind === "todo") attrs.push('completed="0"');
  if (rename && event.note && kind !== "chapter") attrs.push(`note="${escapeAttr(event.note)}"`);
  if (kind === "chapter") {
    attrs.push(`posterOffset="${escapeAttr(markerStart)}"`);
    return `<chapter-marker ${attrs.join(" ")}/>`;
  }
  return `<marker ${attrs.join(" ")}/>`;
}

function textStyleSignature(xml) {
  return [...xml.matchAll(/<text-style-def\b[\s\S]*?<\/text-style-def>/g)].map((match) => match[0]).join("\n");
}

function prefixProjectName(xml, prefix) {
  return xml.replace(/<project\s+([^>]*?)>/, (open, attrSource) => {
    const attrs = parseAttrs(attrSource);
    const currentName = unescapeXML(attrs.name || "Project");
    const cleanName = currentName.replace(/^(?:🛠|📝|🔁)\s+/u, "");
    const nextName = `${prefix}${cleanName}`;
    if (currentName === nextName) return open;
    return /\bname="[^"]*"/.test(open)
      ? open.replace(/\bname="[^"]*"/, `name="${escapeAttr(nextName)}"`)
      : open.replace("<project", `<project name="${escapeAttr(nextName)}"`);
  });
}

function nearestOwnerLabel(xml, index) {
  const before = xml.slice(0, index);
  const match = [...before.matchAll(/<(asset-clip|clip|sync-clip|ref-clip|video|title)\b([^>]*)>/g)].at(-1);
  if (!match) return "timeline";
  const attrs = parseAttrs(match[2]);
  return `${match[1]} ${unescapeXML(attrs.name || attrs.ref || "unnamed")}`;
}

function locatorMap(xml) {
  const locators = new Map();
  for (const match of xml.matchAll(/<locator\b([^>]*)>/g)) {
    const attrs = parseAttrs(match[1]);
    if (attrs.id && attrs.url) locators.set(attrs.id, attrs.url);
  }
  return locators;
}

function sidecarStatus(sourceXml, url) {
  if (!sourceXml || !url || /^[a-z]+:/i.test(url)) return "";
  const sourceDir = path.basename(sourceXml) === "Info.fcpxml" ? path.dirname(sourceXml) : path.dirname(sourceXml);
  return existsSync(path.resolve(sourceDir, url)) ? "sidecar present" : "sidecar missing";
}

function recheckItems(xml, sourceXml = "") {
  const items = [];
  const magneticMaskRegex = /<filter-video\b(?=[^>]*\bname="Magnetic Mask")[^>]*\/>|<filter-video\b(?=[^>]*\bname="Magnetic Mask")[^>]*>[\s\S]*?<\/filter-video>/g;
  for (const match of xml.matchAll(magneticMaskRegex)) {
    const hasPayload = /<data\b|<param\b|dataLocator=/.test(match[0]);
    const detail = hasPayload ? "effect payload present" : "effect shell only; mask analysis is not serialized in FCPXML";
    items.push({ label: "Magnetic Mask", owner: nearestOwnerLabel(xml, match.index), detail, index: match.index });
  }
  const locators = locatorMap(xml);
  for (const match of xml.matchAll(/<object-tracker\b[\s\S]*?<\/object-tracker>/g)) {
    const locatorID = /dataLocator="([^"]+)"/.exec(match[0])?.[1] || "";
    const url = locators.get(locatorID) || "";
    const detail = [locatorID ? `locator ${locatorID}` : "no locator", url || "no sidecar url", sidecarStatus(sourceXml, url)]
      .filter(Boolean)
      .join("; ");
    items.push({ label: "Object Tracking", owner: nearestOwnerLabel(xml, match.index), detail, index: match.index });
  }
  for (const match of xml.matchAll(/<adjust-stabilization\b[^>]*>/g)) {
    items.push({ label: "Stabilization", owner: nearestOwnerLabel(xml, match.index), detail: "stabilization settings in XML", index: match.index });
  }
  for (const match of xml.matchAll(/<timeMap\b[^>]*\bframeSampling="optical-flow[^"]*"[^>]*>/g)) {
    const attrs = parseAttrs(match[0]);
    items.push({ label: "Optical Flow", owner: nearestOwnerLabel(xml, match.index), detail: attrs.frameSampling || "optical-flow", index: match.index });
  }
  return items;
}

function ownerForIndex(allItems, index) {
  const candidates = allItems.filter((item) =>
    item.openStart <= index &&
    item.closeEnd != null &&
    index <= item.closeEnd
  );
  if (candidates.length === 0) return null;
  const depth = (item) => {
    let count = 0;
    let cursor = item.parent;
    while (cursor) {
      count += 1;
      cursor = cursor.parent;
    }
    return count;
  };
  const ownerTags = new Set(["clip", "asset-clip", "ref-clip", "sync-clip"]);
  const isVisibleOwner = (item) =>
    ownerTags.has(item?.tag) &&
    (item.attrs.lane != null || (item.parent?.tag === "spine" && item.parent?.parent?.tag === "sequence"));
  const deepest = candidates.slice().sort((a, b) => depth(b) - depth(a) || b.openStart - a.openStart)[0];
  let fallback = null;
  let cursor = deepest?.tag === "video" || deepest?.tag === "title" ? deepest.parent : deepest;
  while (cursor) {
    if (ownerTags.has(cursor.tag)) {
      fallback ||= cursor;
      if (isVisibleOwner(cursor)) return cursor;
    }
    cursor = cursor.parent;
  }
  return fallback;
}

function recheckMarkerEvents(recheck, allItems) {
  const markerLabels = new Set(["Magnetic Mask", "Object Tracking", "Stabilization", "Optical Flow"]);
  const events = [];
  for (const item of recheck) {
    if (!markerLabels.has(item.label)) continue;
    const owner = ownerForIndex(allItems, item.index);
    if (!owner) {
      events.push({ ...item, markerOwner: null });
      continue;
    }
    events.push({
      ...item,
      markerOwner: owner,
      markerOwnerLabel: `${owner.tag} ${unescapeXML(owner.attrs.name || owner.attrs.ref || "unnamed")}`,
      name: `TURNOVER RECHECK: ${item.label}`,
      note: `${owner.tag} ${unescapeXML(owner.attrs.name || owner.attrs.ref || "unnamed")}${item.owner !== `${owner.tag} ${unescapeXML(owner.attrs.name || owner.attrs.ref || "unnamed")}` ? ` | source: ${item.owner}` : ""}${item.detail ? `\n${item.detail}` : ""}`,
    });
  }
  return events;
}

function topLevelMarkerStarts(xml, owner) {
  const starts = new Set();
  if (owner.selfClosing || owner.closeStart == null) return starts;
  const body = xml.slice(owner.openEnd, owner.closeStart);
  const markerTags = new Set(["marker", "chapter-marker", "rating", "keyword", "analysis-marker", "hidden-clip-marker"]);
  const stack = [];
  const tagRegex = /<(\/?)([\w:_-]+)(.*?)(\/?)>/gs;
  let match;
  while ((match = tagRegex.exec(body))) {
    const [, closing, tag, attrText, selfClosing] = match;
    if (closing !== "/") {
      if (stack.length === 0 && markerTags.has(tag)) {
        const attrs = parseAttrs(attrText);
        if (attrs.start) starts.add(attrs.start);
      }
      if (selfClosing !== "/") stack.push(tag);
    } else {
      stack.pop();
    }
  }
  return starts;
}

function freeRecheckMarkerStart(owner, frameDuration, usedStarts) {
  const frameSeconds = parseTime(frameDuration) || (1 / 24);
  const start = owner.start || 0;
  const duration = Math.max(owner.duration || 0, frameSeconds);
  const min = start;
  const max = start + Math.max(duration - frameSeconds, 0);
  const candidates = [];
  for (let frame = 1; frame <= 24; frame += 1) {
    candidates.push(Math.min(max, start + (frame * frameSeconds)));
  }
  candidates.push(start);
  for (let frame = 1; frame <= 24; frame += 1) {
    candidates.push(Math.max(min, start + duration - ((frame + 1) * frameSeconds)));
  }
  for (const candidate of candidates) {
    const snapped = snapToFrameTime(candidate, frameDuration);
    if (!usedStarts.has(snapped)) {
      usedStarts.add(snapped);
      return snapped;
    }
  }
  const fallback = snapToFrameTime(start, frameDuration);
  usedStarts.add(fallback);
  return fallback;
}

function recheckMarkerXML(event, owner, frameDuration, usedStarts) {
  const markerStart = freeRecheckMarkerStart(owner, frameDuration, usedStarts);
  const note = String(event.note || "").replace(/\s*\n\s*/g, " | ");
  return `<marker start="${escapeAttr(markerStart)}" duration="${escapeAttr(frameDuration)}" value="${escapeAttr(event.name)}" completed="1" note="${escapeAttr(note)}"/>`;
}

function markerInsertionOffset(xml, owner) {
  if (owner.selfClosing) return owner.openEnd;
  const body = xml.slice(owner.openEnd, owner.closeStart);
  const trailingTags = new Set([
    "sync-source",
    "audio-channel-source",
    "filter-video",
    "filter-video-mask",
    "filter-audio",
    "metadata",
  ]);
  const stack = [];
  const tagRegex = /<(\/?)([\w:_-]+)(.*?)(\/?)>/gs;
  let match;
  while ((match = tagRegex.exec(body))) {
    const [, closing, tag, , selfClosing] = match;
    if (closing !== "/") {
      if (stack.length === 0 && trailingTags.has(tag)) {
        return owner.openEnd + match.index;
      }
      if (selfClosing !== "/") stack.push(tag);
    } else {
      stack.pop();
    }
  }
  return owner.closeStart;
}

function frameDurationForSequence(xml) {
  const formatID = parseAttrs(xml.match(/<sequence\s+([^>]*?)>/)?.[1] || "").format;
  for (const match of xml.matchAll(/<format\s+([^>]*?)\/?\s*>/g)) {
    const attrs = parseAttrs(match[1]);
    if (attrs.id === formatID && attrs.frameDuration) return attrs.frameDuration;
  }
  return "1/24s";
}

function applyMarkers(xml, events, owners, kind, rename, frameDuration, recheckEvents = []) {
  const insertions = new Map();
  const unmatched = [];
  for (const event of events) {
    const owner = owners.find((candidate, index) => {
      const end = candidate.absTime + candidate.duration;
      const isLast = index === owners.length - 1;
      return event.timelineTime >= candidate.absTime - 1e-7 &&
        (event.timelineTime < end - 1e-7 || (isLast && event.timelineTime <= end + 1e-7));
    });
    if (!owner) {
      unmatched.push(event);
      continue;
    }
    const marker = markerXML(event, owner, kind, rename, frameDuration);
    const bucket = insertions.get(owner) || [];
    bucket.push(marker);
    insertions.set(owner, bucket);
  }

  const recheckSkipped = [];
  let recheckCreated = 0;
  for (const event of recheckEvents) {
    const owner = event.markerOwner;
    if (!owner) {
      recheckSkipped.push(event);
      continue;
    }
    const bucket = insertions.get(owner) || [];
    const usedStarts = topLevelMarkerStarts(xml, owner);
    for (const existing of bucket) {
      const attrs = parseAttrs(existing);
      if (attrs.start) usedStarts.add(attrs.start);
    }
    bucket.push(recheckMarkerXML(event, owner, frameDuration, usedStarts));
    insertions.set(owner, bucket);
    recheckCreated += 1;
  }

  const replacements = [];
  for (const [owner, markers] of insertions) {
    const payload = `\n${markers.join("\n")}\n`;
    if (owner.selfClosing) {
      const open = xml.slice(owner.openStart, owner.openEnd).replace(/\/\s*>$/, ">");
      replacements.push({
        start: owner.openStart,
        end: owner.openEnd,
        value: `${open}${payload}\n</${owner.tag}>`,
      });
    } else {
      const insertionOffset = markerInsertionOffset(xml, owner);
      replacements.push({ start: insertionOffset, end: insertionOffset, value: payload });
    }
  }
  replacements.sort((a, b) => b.start - a.start);
  let patched = xml;
  for (const replacement of replacements) {
    patched = patched.slice(0, replacement.start) + replacement.value + patched.slice(replacement.end);
  }
  patched = prefixProjectName(patched, "🛠 ");
  return { xml: patched, created: events.length - unmatched.length, unmatched, recheckCreated, recheckSkipped };
}

function findDTD(version) {
  const filename = `FCPXMLv${version.replace(/\./g, "_")}.dtd`;
  const candidates = [
    `/Applications/Final Cut Pro.app/Contents/Frameworks/Interchange.framework/Versions/A/Resources/${filename}`,
    `/Applications/Final Cut Pro.app/Contents/Frameworks/Interchange.framework/Resources/${filename}`,
  ];
  return candidates.find(existsSync) || "";
}

async function validateDTD(xml, version) {
  const dtd = findDTD(version);
  if (!dtd) return "DTD validation skipped: local DTD not found";
  const temp = path.join(os.tmpdir(), `turnover_auto_marker_${crypto.randomUUID()}.fcpxml`);
  try {
    await fs.writeFile(temp, xml);
    const result = spawnSync("/usr/bin/xmllint", ["--noout", "--dtdvalid", `file://${dtd.replace(/ /g, "%20")}`, temp], { encoding: "utf8" });
    if (result.status !== 0) throw new Error(`DTD validation failed: ${trim(result.stderr || result.stdout)}`);
    return `DTD validation: passed (${path.basename(dtd)})`;
  } finally {
    await fs.rm(temp, { force: true });
  }
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const source = await fs.readFile(args.sourceXml, "utf8");
  const sourceTextStyles = textStyleSignature(source);
  const recheck = recheckItems(source, args.sourceXml);
  const { titles, primaryItems, allItems } = parseTimeline(source);
  if (titles.length === 0) throw new Error("No VFX naming titles were found.");
  const frameDuration = frameDurationForSequence(source);
  const recheckMarkers = recheckMarkerEvents(recheck, allItems);
  const result = applyMarkers(source, titles, primaryItems, args.markerKind, args.renameMarkers, frameDuration, recheckMarkers);
  if (result.created === 0) throw new Error("No marker anchors could be placed on the primary storyline.");
  const version = parseAttrs(source.match(/<fcpxml\s+([^>]*?)>/)?.[1] || "").version || "1.12";
  const validation = await validateDTD(result.xml, version);
  const textStylesPreserved = textStyleSignature(result.xml) === sourceTextStyles;
  await fs.mkdir(path.dirname(args.outputXml), { recursive: true });
  await fs.mkdir(path.dirname(args.report), { recursive: true });
  await fs.writeFile(args.outputXml, result.xml);
  await fs.writeFile(args.report, [
    `source: ${args.sourceXml}`,
    `marker kind: ${args.markerKind}`,
    `rename markers: ${args.renameMarkers}`,
    `VFX titles: ${titles.length}`,
    `markers created: ${result.created}`,
    `unmatched titles: ${result.unmatched.length}`,
    "project name: updated",
    "project uid: preserved",
    `text style definitions: ${textStylesPreserved ? "preserved" : "changed"}`,
    `recheck items: ${recheck.length}`,
    `recheck markers requested: ${recheckMarkers.length}`,
    `recheck markers created: ${result.recheckCreated}`,
    `recheck markers skipped: ${result.recheckSkipped.length}`,
    ...recheck.map((item) => `- recheck ${item.label}: ${item.owner}${item.detail ? ` (${item.detail})` : ""}`),
    ...result.recheckSkipped.map((item) => `- recheck marker skipped ${item.label}: ${item.owner}`),
    ...result.unmatched.map((event) => `- unmatched ${formatSeconds(event.timelineTime)} ${event.name}`),
    validation,
    "",
  ].join("\n"));
  console.log(JSON.stringify({ status: "ok", created: result.created, unmatched: result.unmatched.length }));
}

main().catch((error) => {
  console.error(error.stack || String(error));
  process.exit(1);
});
