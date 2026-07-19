import fs from "node:fs/promises";
import { existsSync } from "node:fs";
import path from "node:path";

function parseArgs(argv) {
  const args = { mode: "auto", start: 10, step: 10 };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--source-xml") args.sourceXml = path.resolve(argv[++i]);
    else if (arg === "--output-xml") args.outputXml = path.resolve(argv[++i]);
    else if (arg === "--report") args.report = path.resolve(argv[++i]);
    else if (arg === "--mode") args.mode = String(argv[++i] || "").toLowerCase();
    else if (arg === "--start") args.start = Math.max(0, Math.floor(Number(argv[++i]) || 0));
    else if (arg === "--step") args.step = Math.max(1, Math.floor(Number(argv[++i]) || 1));
    else throw new Error(`Unknown argument: ${arg}`);
  }
  if (!args.sourceXml || !args.outputXml || !args.report) throw new Error("Missing required arguments.");
  if (!["auto", "reset"].includes(args.mode)) throw new Error("--mode must be auto or reset.");
  return args;
}

function trim(value) {
  return String(value ?? "").trim();
}

function parseFraction(value) {
  if (!value) return null;
  const fraction = /^([-\d.]+)\/([-\d.]+)s$/.exec(value);
  if (fraction) {
    const numerator = Number(fraction[1]);
    const denominator = Number(fraction[2]);
    if (Number.isFinite(numerator) && Number.isFinite(denominator) && denominator !== 0) return numerator / denominator;
  }
  const seconds = /^([-\d.]+)s$/.exec(value);
  return seconds ? Number(seconds[1]) : null;
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
  const frameSeconds = parseFraction(frameDuration);
  if (!frameSeconds || (!match && !whole)) return formatSeconds(seconds);
  const frames = BigInt(Math.round(seconds / frameSeconds));
  let numerator = frames * BigInt(match ? match[1] : whole[1]);
  let denominator = BigInt(match ? match[2] : 1);
  const divisor = gcdBigInt(numerator, denominator);
  numerator /= divisor;
  denominator /= divisor;
  return denominator === 1n ? `${numerator}s` : `${numerator}/${denominator}s`;
}

function parseAttrs(value = "") {
  const attrs = {};
  for (const match of value.matchAll(/([\w:_-]+)\s*=\s*"([^"]*)"/g)) attrs[match[1]] = match[2];
  return attrs;
}

function decodeXML(value = "") {
  return String(value)
    .replace(/&quot;/g, "\"")
    .replace(/&apos;/g, "'")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&amp;/g, "&");
}

function encodeXMLText(value = "") {
  return String(value).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

function encodeXMLAttr(value = "") {
  return encodeXMLText(value).replace(/"/g, "&quot;").replace(/'/g, "&apos;");
}

function extractTitleText(inner = "") {
  const styled = [...inner.matchAll(/<text-style\b[^>]*>(.*?)<\/text-style>/gs)]
    .map((match) => trim(decodeXML(match[1].replace(/<[^>]+>/g, ""))))
    .filter(Boolean);
  if (styled.length > 0) return styled;
  return [...inner.matchAll(/<text\b[^>]*>(.*?)<\/text>/gs)]
    .map((match) => trim(decodeXML(match[1].replace(/<[^>]+>/g, ""))))
    .filter(Boolean);
}

function contextTimelineStart(parent, attrs) {
  const parentTimeline = parent?.timelineStart ?? 0;
  const offset = parseFraction(attrs.offset);
  if (offset == null) return parentTimeline;
  return parentTimeline + offset - (parent?.start ?? 0);
}

function collectTitles(xml) {
  const titles = [];
  const allItems = [];
  const stack = [];
  const tagRegex = /<(\/?)([\w:_-]+)(.*?)(\/?)>/gs;
  let match;
  while ((match = tagRegex.exec(xml))) {
    const [full, closing, tag, attrText, selfClosing] = match;
    if (closing !== "/") {
      const attrs = parseAttrs(attrText);
      const parent = stack.at(-1);
      const node = {
        tag,
        attrs,
        timelineStart: contextTimelineStart(parent, attrs),
        start: parseFraction(attrs.start) ?? parent?.start ?? 0,
        duration: parseFraction(attrs.duration) ?? 0,
        openStart: match.index,
        openEnd: tagRegex.lastIndex,
        openTag: full,
        closeStart: selfClosing === "/" ? tagRegex.lastIndex : null,
        closeEnd: selfClosing === "/" ? tagRegex.lastIndex : null,
        selfClosing: selfClosing === "/",
      };
      if (["clip", "asset-clip", "ref-clip", "sync-clip", "video", "title"].includes(tag)) {
        allItems.push(node);
      }
      if (selfClosing !== "/") stack.push(node);
      continue;
    }

    const node = stack.pop();
    if (!node || node.tag !== tag) continue;
    node.closeStart = match.index;
    node.closeEnd = tagRegex.lastIndex;
    if (tag !== "title") continue;
    const innerStart = node.openEnd;
    const innerEnd = match.index;
    const inner = xml.slice(innerStart, innerEnd);
    const lines = extractTitleText(inner);
    const firstLine = trim(lines[0]);
    const titleName = trim(node.attrs.name);
    const looksLikeCode = /^[A-Z0-9_-]+_(?:XXXX|\d{4})$/i.test(firstLine);
    if (!titleName.toLowerCase().includes("vfx naming") && !looksLikeCode) continue;
    titles.push({
      titleName,
      firstLine,
      timelineTime: node.timelineStart + (node.duration / 2),
      openStart: node.openStart,
      openEnd: node.openEnd,
      openTag: node.openTag,
      innerStart,
      innerEnd,
      inner,
    });
  }
  titles.sort((a, b) => a.timelineTime - b.timelineTime || a.openStart - b.openStart);
  return { titles, allItems };
}

function replaceFirstLiteral(value, oldText, newText) {
  const encodedOld = encodeXMLText(oldText);
  const encodedNew = encodeXMLText(newText);
  const encodedIndex = value.indexOf(encodedOld);
  if (encodedIndex >= 0) return `${value.slice(0, encodedIndex)}${encodedNew}${value.slice(encodedIndex + encodedOld.length)}`;
  const rawIndex = value.indexOf(oldText);
  if (rawIndex >= 0) return `${value.slice(0, rawIndex)}${newText}${value.slice(rawIndex + oldText.length)}`;
  return null;
}

function replaceTitleName(openTag, oldName, oldCode, newCode) {
  let newName = oldName;
  if (oldName.startsWith(oldCode)) newName = `${newCode}${oldName.slice(oldCode.length)}`;
  else if (oldName.toLowerCase().includes("vfx naming")) newName = `${newCode} - VFX NAMING`;
  if (!newName || newName === oldName) return openTag;
  const oldAttr = `name="${encodeXMLAttr(oldName)}"`;
  const newAttr = `name="${encodeXMLAttr(newName)}"`;
  if (openTag.includes(oldAttr)) return openTag.replace(oldAttr, newAttr);
  return openTag.replace(/^<title\s+/, `<title ${newAttr} `);
}

function textStyleSignature(xml) {
  return [...xml.matchAll(/<text-style-def\b[\s\S]*?<\/text-style-def>/g)].map((match) => match[0]).join("\n");
}

function prefixProjectName(xml, prefix) {
  return xml.replace(/<project\b([^>]*?)\bname="([^"]+)"([^>]*)>/s, (full, before, name, after) => {
    const currentName = decodeXML(name);
    const cleanName = currentName.replace(/^(?:🛠|📝|🔁)\s+/u, "");
    const nextName = `${prefix}${cleanName}`;
    if (currentName === nextName) return full;
    return `<project${before}name="${encodeXMLAttr(nextName)}"${after}>`;
  });
}

function nearestOwnerLabel(xml, index) {
  const before = xml.slice(0, index);
  const match = [...before.matchAll(/<(asset-clip|clip|sync-clip|ref-clip|video|title)\b([^>]*)>/g)].at(-1);
  if (!match) return "timeline";
  const attrs = parseAttrs(match[2]);
  return `${match[1]} ${decodeXML(attrs.name || attrs.ref || "unnamed")}`;
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

function frameDurationForSequence(xml) {
  const formatID = parseAttrs(xml.match(/<sequence\s+([^>]*?)>/)?.[1] || "").format;
  for (const match of xml.matchAll(/<format\s+([^>]*?)\/?\s*>/g)) {
    const attrs = parseAttrs(match[1]);
    if (attrs.id === formatID && attrs.frameDuration) return attrs.frameDuration;
  }
  return "1/24s";
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
      if (stack.length === 0 && trailingTags.has(tag)) return owner.openEnd + match.index;
      if (selfClosing !== "/") stack.push(tag);
    } else {
      stack.pop();
    }
  }
  return owner.closeStart;
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
  return recheck
    .filter((item) => markerLabels.has(item.label))
    .map((item) => {
      const owner = ownerForIndex(allItems, item.index);
      const ownerLabel = owner ? `${owner.tag} ${decodeXML(owner.attrs.name || owner.attrs.ref || "unnamed")}` : "";
      return {
        ...item,
        markerOwner: owner,
        markerOwnerLabel: ownerLabel,
        name: `TURNOVER RECHECK: ${item.label}`,
        note: `${ownerLabel || item.owner}${ownerLabel && item.owner !== ownerLabel ? ` | source: ${item.owner}` : ""}${item.detail ? `\n${item.detail}` : ""}`,
      };
    });
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
  const frameSeconds = parseFraction(frameDuration) || (1 / 24);
  const start = owner.start || 0;
  const duration = Math.max(owner.duration || 0, frameSeconds);
  const min = start;
  const max = start + Math.max(duration - frameSeconds, 0);
  const candidates = [];
  for (let frame = 1; frame <= 24; frame += 1) candidates.push(Math.min(max, start + (frame * frameSeconds)));
  candidates.push(start);
  for (let frame = 1; frame <= 24; frame += 1) candidates.push(Math.max(min, start + duration - ((frame + 1) * frameSeconds)));
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
  return `<marker start="${encodeXMLAttr(markerStart)}" duration="${encodeXMLAttr(frameDuration)}" value="${encodeXMLAttr(event.name)}" completed="1" note="${encodeXMLAttr(note)}"/>`;
}

function insertRecheckMarkers(xml, recheckMarkers, frameDuration) {
  const insertions = new Map();
  const skipped = [];
  for (const event of recheckMarkers) {
    const owner = event.markerOwner;
    if (!owner) {
      skipped.push(event);
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
  }
  const replacements = [];
  for (const [owner, markers] of insertions) {
    const payload = `\n${markers.join("\n")}\n`;
    if (owner.selfClosing) {
      const open = xml.slice(owner.openStart, owner.openEnd).replace(/\/\s*>$/, ">");
      replacements.push({ start: owner.openStart, end: owner.openEnd, value: `${open}${payload}\n</${owner.tag}>` });
    } else {
      const insertionOffset = markerInsertionOffset(xml, owner);
      replacements.push({ start: insertionOffset, end: insertionOffset, value: payload });
    }
  }
  replacements.sort((a, b) => b.start - a.start);
  let patched = xml;
  for (const replacement of replacements) {
    patched = `${patched.slice(0, replacement.start)}${replacement.value}${patched.slice(replacement.end)}`;
  }
  return { xml: patched, created: recheckMarkers.length - skipped.length, skipped };
}

function buildPlan(titles, args) {
  const counters = new Map();
  const plan = [];
  for (const title of titles) {
    let match;
    let newCode;
    if (args.mode === "auto") {
      match = /^(.*?)_XXXX$/i.exec(title.firstLine);
      if (!match) continue;
      const base = match[1];
      const next = counters.has(base) ? counters.get(base) + args.step : args.start;
      counters.set(base, next);
      newCode = `${base}_${String(next).padStart(4, "0")}`;
    } else {
      match = /^(.*?)_\d{4}$/.exec(title.firstLine);
      if (!match) continue;
      newCode = `${match[1]}_XXXX`;
    }
    plan.push({ title, oldCode: title.firstLine, newCode });
  }
  return plan;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const xml = await fs.readFile(args.sourceXml, "utf8");
  const sourceTextStyles = textStyleSignature(xml);
  const { titles, allItems } = collectTitles(xml);
  if (titles.length === 0) throw new Error("No VFX naming titles were found.");
  const plan = buildPlan(titles, args);
  if (plan.length === 0) {
    throw new Error(args.mode === "auto"
      ? "No VFX naming titles ending in _XXXX (case-insensitive) were found."
      : "No VFX naming titles ending in four digits were found.");
  }

  const replacements = [];
  const warnings = [];
  for (const item of plan) {
    const inner = replaceFirstLiteral(item.title.inner, item.oldCode, item.newCode);
    if (inner == null) warnings.push(`Could not update title text: ${item.oldCode}`);
    else replacements.push({ start: item.title.innerStart, end: item.title.innerEnd, value: inner });
    replacements.push({
      start: item.title.openStart,
      end: item.title.openEnd,
      value: replaceTitleName(item.title.openTag, item.title.titleName, item.oldCode, item.newCode),
    });
  }

  replacements.sort((a, b) => b.start - a.start);
  let patched = xml;
  for (const replacement of replacements) {
    patched = `${patched.slice(0, replacement.start)}${replacement.value}${patched.slice(replacement.end)}`;
  }
  const recheck = recheckItems(xml, args.sourceXml);
  const recheckMarkers = recheckMarkerEvents(recheck, allItems);
  const frameDuration = frameDurationForSequence(xml);
  const recheckResult = insertRecheckMarkers(patched, recheckMarkers, frameDuration);
  patched = prefixProjectName(recheckResult.xml, args.mode === "auto" ? "📝 " : "🔁 ");
  if (textStyleSignature(patched) !== sourceTextStyles) {
    warnings.push("Text style definitions changed unexpectedly; output was still written for inspection.");
  }

  await fs.mkdir(path.dirname(args.outputXml), { recursive: true });
  await fs.mkdir(path.dirname(args.report), { recursive: true });
  await fs.writeFile(args.outputXml, patched);
  const report = [
    `source_xml\t${args.sourceXml}`,
    `output_xml\t${args.outputXml}`,
    `mode\t${args.mode}`,
    `titles_found\t${titles.length}`,
    `titles_changed\t${plan.length}`,
    `start\t${args.start}`,
    `step\t${args.step}`,
    `project_name\tupdated`,
    `project_uid\tpreserved`,
    `text_style_defs\t${warnings.some((warning) => warning.includes("Text style")) ? "changed" : "preserved"}`,
    `recheck_items\t${recheck.length}`,
    `recheck_markers_requested\t${recheckMarkers.length}`,
    `recheck_markers_created\t${recheckResult.created}`,
    `recheck_markers_skipped\t${recheckResult.skipped.length}`,
    `warnings\t${warnings.length}`,
    ...recheck.map((item) => `recheck\t${item.label}\t${item.owner}\t${item.detail || ""}`),
    ...recheckResult.skipped.map((item) => `recheck_marker_skipped\t${item.label}\t${item.owner}`),
    ...plan.map((item) => `rename\t${item.oldCode}\t${item.newCode}`),
    ...warnings.map((warning) => `warning\t${warning}`),
  ];
  await fs.writeFile(args.report, `${report.join("\n")}\n`);
  console.log(JSON.stringify({ status: "ok", mode: args.mode, changed: plan.length, output_xml: args.outputXml, report_path: args.report }));
}

main().catch((error) => {
  console.error(error.stack || String(error));
  process.exit(1);
});
