import fs from "node:fs/promises";
import path from "node:path";

function usage() {
  console.log(`Usage:
  node lua/scripts/verify_conform_prep.mjs \\
    --original-xml <path-to-original-fcpxml-or-fcpxmld> \\
    --imported-xml <path-to-fcp-imported-export-fcpxml-or-fcpxmld> \\
    [--patched-xml <path-to-generated-patched-fcpxml-or-fcpxmld>] \\
    [--original-index <timeline-index-csv>] \\
    [--imported-index <timeline-index-csv>] \\
    [--fps 24] \\
    [--position-tolerance-frames 2] \\
    [--report <text-report-path>] \\
    [--json <json-report-path>]

Notes:
  - Pass the FCP re-exported imported XML as --imported-xml when possible.
    That proves what Final Cut Pro actually kept after import.
  - Timeline Index CSV is optional. The verifier derives title/marker timeline
    positions from FCPXML directly, then uses CSV only as an extra UI-facing
    validation layer when provided.
  - Timeline Index CSV matching by Name + Notes is useful but ambiguous for
    repeated titles. XML title identity is the stronger missing/added check.`);
}

function parseArgs(argv) {
  const args = {
    fps: 24,
    positionToleranceFrames: 2,
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--original-xml") args.originalXml = path.resolve(argv[++i]);
    else if (arg === "--imported-xml") args.importedXml = path.resolve(argv[++i]);
    else if (arg === "--patched-xml") args.patchedXml = path.resolve(argv[++i]);
    else if (arg === "--original-index") args.originalIndex = path.resolve(argv[++i]);
    else if (arg === "--imported-index") args.importedIndex = path.resolve(argv[++i]);
    else if (arg === "--fps") args.fps = Number(argv[++i]);
    else if (arg === "--position-tolerance-frames") args.positionToleranceFrames = Number(argv[++i]);
    else if (arg === "--report") args.report = path.resolve(argv[++i]);
    else if (arg === "--json") args.json = path.resolve(argv[++i]);
    else if (arg === "--help" || arg === "-h") {
      usage();
      process.exit(0);
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }
  if (!args.originalXml || !args.importedXml) {
    usage();
    throw new Error("Missing required --original-xml or --imported-xml.");
  }
  if (!Number.isFinite(args.fps) || args.fps <= 0) throw new Error("--fps must be a positive number.");
  if (!Number.isFinite(args.positionToleranceFrames) || args.positionToleranceFrames < 0) {
    throw new Error("--position-tolerance-frames must be zero or greater.");
  }
  return args;
}

function decodeText(buffer) {
  if (buffer.length >= 2 && buffer[0] === 0xff && buffer[1] === 0xfe) return buffer.toString("utf16le");
  if (buffer.length >= 2 && buffer[0] === 0xfe && buffer[1] === 0xff) {
    const swapped = Buffer.alloc(buffer.length - 2);
    for (let i = 2; i + 1 < buffer.length; i += 2) {
      swapped[i - 2] = buffer[i + 1];
      swapped[i - 1] = buffer[i];
    }
    return swapped.toString("utf16le");
  }
  return buffer.toString("utf8").replace(/^\uFEFF/, "");
}

async function readText(filePath) {
  return decodeText(await fs.readFile(filePath));
}

async function resolveXmlPath(inputPath) {
  const stat = await fs.stat(inputPath);
  if (!stat.isDirectory()) return inputPath;
  const candidates = ["Info.fcpxml", "info.fcpxml"];
  for (const candidate of candidates) {
    const full = path.join(inputPath, candidate);
    try {
      const candidateStat = await fs.stat(full);
      if (candidateStat.isFile()) return full;
    } catch {
      // Try the next common FCPXML bundle filename.
    }
  }
  throw new Error(`Directory does not contain Info.fcpxml: ${inputPath}`);
}

function trim(value) {
  return String(value ?? "").trim();
}

function decodeXML(value) {
  return String(value ?? "")
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&amp;/g, "&");
}

function parseAttrs(attrStr = "") {
  const attrs = {};
  const regex = /([\w:_-]+)\s*=\s*"([^"]*)"/g;
  let match;
  while ((match = regex.exec(attrStr))) attrs[match[1]] = decodeXML(match[2]);
  return attrs;
}

function stripTags(value) {
  return decodeXML(String(value ?? "").replace(/<[^>]+>/g, " ")).replace(/\s+/g, " ").trim();
}

function extractNote(body) {
  return stripTags(body.match(/<note\b[^>]*>([\s\S]*?)<\/note>/)?.[1] ?? "");
}

function extractTitleText(body) {
  const parts = [];
  for (const match of body.matchAll(/<text\b[^>]*>([\s\S]*?)<\/text>/g)) {
    parts.push(stripTags(match[1]));
  }
  return parts.join("\n").trim();
}

function parseTimeSeconds(value) {
  const raw = trim(value);
  if (!raw) return null;
  const clean = raw.endsWith("s") ? raw.slice(0, -1) : raw;
  if (clean.includes("/")) {
    const [num, den] = clean.split("/").map(Number);
    if (!Number.isFinite(num) || !Number.isFinite(den) || den === 0) return null;
    return num / den;
  }
  const n = Number(clean);
  return Number.isFinite(n) ? n : null;
}

function secondsToFrames(seconds, fps) {
  if (seconds == null) return null;
  return Math.round(seconds * fps);
}

function framesDrift(aSeconds, bSeconds, fps) {
  if (aSeconds == null || bSeconds == null) return null;
  return Math.round((bSeconds - aSeconds) * fps);
}

function timecodeToFrames(value, fps) {
  const match = trim(value).match(/^(\d+):(\d{2}):(\d{2}):(\d{2})$/);
  if (!match) return null;
  const [, hh, mm, ss, ff] = match.map(Number);
  return (((hh * 60 + mm) * 60 + ss) * fps) + ff;
}

function framesToTimecode(frames, fps) {
  if (frames == null) return "";
  const sign = frames < 0 ? "-" : "";
  let remaining = Math.abs(frames);
  const ff = remaining % fps;
  remaining = Math.floor(remaining / fps);
  const ss = remaining % 60;
  remaining = Math.floor(remaining / 60);
  const mm = remaining % 60;
  const hh = Math.floor(remaining / 60);
  return `${sign}${String(hh).padStart(2, "0")}:${String(mm).padStart(2, "0")}:${String(ss).padStart(2, "0")}:${String(ff).padStart(2, "0")}`;
}

function frameBoundaryStatus(value, fps) {
  const seconds = parseTimeSeconds(value);
  if (seconds == null) return { ok: true, frames: null, error: null };
  const exact = seconds * fps;
  const nearest = Math.round(exact);
  const error = exact - nearest;
  return { ok: Math.abs(error) < 1e-6, frames: nearest, error };
}

function titleIdentity(title) {
  return [
    title.name,
    title.note,
    title.text,
    title.role,
    title.enabled,
  ].map((part) => trim(part)).join("\u001f");
}

function markerIdentity(marker) {
  return [
    marker.tag,
    marker.value,
    marker.note,
    marker.completed,
  ].map((part) => trim(part)).join("\u001f");
}

function countTags(xml, tagName) {
  const regex = new RegExp(`<${tagName}\\b`, "g");
  return [...xml.matchAll(regex)].length;
}

const CLIP_LIKE_TAGS = new Set(["asset-clip", "clip", "sync-clip", "mc-clip", "ref-clip", "video", "audio", "gap"]);

function nearestClipLike(stack) {
  for (let i = stack.length - 1; i >= 0; i -= 1) {
    if (CLIP_LIKE_TAGS.has(stack[i].tag)) return stack[i];
  }
  return null;
}

function timelineSecondsForChild(attrs, stack, kind) {
  const parent = nearestClipLike(stack);
  const offsetSeconds = parseTimeSeconds(attrs.offset);
  const startSeconds = parseTimeSeconds(attrs.start);
  const localSeconds = kind === "marker"
    ? (startSeconds ?? offsetSeconds ?? 0)
    : (offsetSeconds ?? startSeconds ?? 0);
  if (!parent) return localSeconds;
  return parent.timelineSeconds + (localSeconds - parent.startSeconds);
}

function timelineSecondsForClip(attrs, stack) {
  const parent = nearestClipLike(stack);
  const offsetSeconds = parseTimeSeconds(attrs.offset);
  const startSeconds = parseTimeSeconds(attrs.start) ?? 0;
  const localSeconds = offsetSeconds ?? startSeconds;
  if (!parent) return localSeconds ?? 0;
  return parent.timelineSeconds + ((localSeconds ?? startSeconds) - parent.startSeconds);
}

function findElementEnd(xml, openEnd, tagName) {
  if (xml[openEnd - 2] === "/") return openEnd;
  const close = new RegExp(`<\\/${tagName}>`, "g");
  close.lastIndex = openEnd;
  const match = close.exec(xml);
  return match ? close.lastIndex : openEnd;
}

function collectTimelineItems(xml, fps) {
  const titles = [];
  const markers = [];
  const stack = [];
  const tagRegex = /<(\/?)([\w:_-]+)([^<>]*?)(\/?)>/g;
  let match;
  while ((match = tagRegex.exec(xml))) {
    const [full, slash, tagName, attrStr, selfCloseMark] = match;
    if (tagName.startsWith("?") || tagName.startsWith("!")) continue;
    const isClosing = slash === "/";
    const isSelfClosing = selfCloseMark === "/" || full.endsWith("/>");

    if (isClosing) {
      for (let i = stack.length - 1; i >= 0; i -= 1) {
        if (stack[i].tag === tagName) {
          stack.splice(i);
          break;
        }
      }
      continue;
    }

    const attrs = parseAttrs(attrStr ?? "");
    const openStart = match.index;
    const openEnd = tagRegex.lastIndex;

    if (tagName === "title") {
      const end = findElementEnd(xml, openEnd, "title");
      const body = isSelfClosing ? "" : xml.slice(openEnd, Math.max(openEnd, end - "</title>".length));
      const offsetSeconds = parseTimeSeconds(attrs.offset);
      const durationSeconds = parseTimeSeconds(attrs.duration);
      const startSeconds = parseTimeSeconds(attrs.start);
      const timelineSeconds = timelineSecondsForChild(attrs, stack, "title");
      const boundary = frameBoundaryStatus(attrs.offset, fps);
      const title = {
        tag: "title",
        name: trim(attrs.name),
        ref: trim(attrs.ref),
        lane: trim(attrs.lane),
        role: trim(attrs.role),
        enabled: trim(attrs.enabled || "1"),
        offset: trim(attrs.offset),
        start: trim(attrs.start),
        duration: trim(attrs.duration),
        offsetSeconds,
        startSeconds,
        durationSeconds,
        offsetFrames: secondsToFrames(offsetSeconds, fps),
        durationFrames: secondsToFrames(durationSeconds, fps),
        timelineSeconds,
        timelineFrames: secondsToFrames(timelineSeconds, fps),
        note: extractNote(body),
        text: extractTitleText(body),
        boundaryOk: boundary.ok,
        boundaryError: boundary.error,
        parentName: nearestClipLike(stack)?.name ?? "",
        parentTag: nearestClipLike(stack)?.tag ?? "",
        identity: "",
      };
      title.identity = titleIdentity(title);
      titles.push(title);
      if (!isSelfClosing) tagRegex.lastIndex = end;
      continue;
    }

    if (tagName === "marker" || tagName === "chapter-marker") {
      const end = findElementEnd(xml, openEnd, tagName);
      const body = isSelfClosing ? "" : xml.slice(openEnd, Math.max(openEnd, end - `</${tagName}>`.length));
      const startSeconds = parseTimeSeconds(attrs.start);
      const durationSeconds = parseTimeSeconds(attrs.duration);
      const timelineSeconds = timelineSecondsForChild(attrs, stack, "marker");
      const marker = {
        tag: tagName,
        value: trim(attrs.value),
        note: extractNote(body),
        start: trim(attrs.start),
        duration: trim(attrs.duration),
        startSeconds,
        durationSeconds,
        timelineSeconds,
        timelineFrames: secondsToFrames(timelineSeconds, fps),
        completed: trim(attrs.completed),
        parentName: nearestClipLike(stack)?.name ?? "",
        parentTag: nearestClipLike(stack)?.tag ?? "",
        identity: "",
      };
      marker.defaultUnnamed = isDefaultUnnamedMarker(marker);
      marker.identity = markerIdentity(marker);
      markers.push(marker);
      if (!isSelfClosing) tagRegex.lastIndex = end;
      continue;
    }

    const node = {
      tag: tagName,
      name: trim(attrs.name),
      startSeconds: parseTimeSeconds(attrs.start) ?? 0,
      timelineSeconds: 0,
    };
    if (CLIP_LIKE_TAGS.has(tagName)) {
      node.timelineSeconds = timelineSecondsForClip(attrs, stack);
    }
    if (!isSelfClosing) stack.push(node);
  }
  return { titles, markers };
}

function extractTitles(xml, fps) {
  return collectTimelineItems(xml, fps).titles;
}

function isDefaultUnnamedMarker(marker) {
  return /^Marker\s+\d+$/i.test(trim(marker.value)) && !trim(marker.note);
}

function extractMarkers(xml, fps) {
  return collectTimelineItems(xml, fps).markers;
}

function xmlSummary(label, xml, fps) {
  const { titles, markers } = collectTimelineItems(xml, fps);
  return {
    label,
    titles,
    markers,
    titleCount: titles.length,
    markerCount: markers.length,
    defaultUnnamedMarkerCount: markers.filter((marker) => marker.defaultUnnamed).length,
    keywordCount: countTags(xml, "keyword"),
    syncClipCount: countTags(xml, "sync-clip"),
    multicamClipCount: countTags(xml, "mc-clip"),
    titleOffsetsOffBoundary: titles.filter((title) => !title.boundaryOk),
  };
}

function multiset(items, keyFn) {
  const map = new Map();
  for (const item of items) {
    const key = keyFn(item);
    const bucket = map.get(key) ?? [];
    bucket.push(item);
    map.set(key, bucket);
  }
  return map;
}

function firstUsefulLabel(item) {
  const bits = [item.name || item.value, item.note, item.text].filter(Boolean);
  return bits.join(" | ").slice(0, 160) || "(unnamed)";
}

function compareMultisets(originalItems, importedItems, keyFn) {
  const original = multiset(originalItems, keyFn);
  const imported = multiset(importedItems, keyFn);
  const missing = [];
  const added = [];
  for (const [key, originalBucket] of original.entries()) {
    const importedBucket = imported.get(key) ?? [];
    for (let i = importedBucket.length; i < originalBucket.length; i += 1) missing.push(originalBucket[i]);
  }
  for (const [key, importedBucket] of imported.entries()) {
    const originalBucket = original.get(key) ?? [];
    for (let i = originalBucket.length; i < importedBucket.length; i += 1) added.push(importedBucket[i]);
  }
  return { missing, added };
}

function parseCsv(text) {
  const rows = [];
  let row = [];
  let cell = "";
  let inQuotes = false;
  for (let i = 0; i < text.length; i += 1) {
    const ch = text[i];
    const next = text[i + 1];
    if (inQuotes) {
      if (ch === '"' && next === '"') {
        cell += '"';
        i += 1;
      } else if (ch === '"') {
        inQuotes = false;
      } else {
        cell += ch;
      }
    } else if (ch === '"') {
      inQuotes = true;
    } else if (ch === ",") {
      row.push(cell);
      cell = "";
    } else if (ch === "\n") {
      row.push(cell);
      rows.push(row);
      row = [];
      cell = "";
    } else if (ch !== "\r") {
      cell += ch;
    }
  }
  if (cell.length > 0 || row.length > 0) {
    row.push(cell);
    rows.push(row);
  }
  return rows.filter((item) => item.some((cellValue) => trim(cellValue)));
}

function parseTimelineIndexCsv(text, fps) {
  const rows = parseCsv(text);
  if (rows.length === 0) return [];
  const headers = rows[0].map((header) => trim(header));
  const nameIndex = headers.findIndex((header) => /^name$/i.test(header));
  const positionIndex = headers.findIndex((header) => /^position$/i.test(header));
  const notesIndex = headers.findIndex((header) => /^notes?$/i.test(header));
  if (nameIndex < 0 || positionIndex < 0) {
    throw new Error("Timeline Index CSV needs at least Name and Position columns.");
  }
  const parsed = [];
  for (let i = 1; i < rows.length; i += 1) {
    const row = rows[i];
    const name = trim(row[nameIndex]);
    if (!name) continue;
    const position = trim(row[positionIndex]);
    const notes = notesIndex >= 0 ? trim(row[notesIndex]) : "";
    parsed.push({
      row: i + 1,
      name,
      position,
      notes,
      positionFrames: timecodeToFrames(position, fps),
      key: `${name}\u001f${notes}`,
    });
  }
  return parsed;
}

function compareTimelineIndex(originalRows, importedRows, toleranceFrames) {
  const original = multiset(originalRows, (row) => row.key);
  const imported = multiset(importedRows, (row) => row.key);
  const countMissing = [];
  const countAdded = [];
  const uniqueDrifts = [];
  const ambiguousGroups = [];

  for (const [key, originalBucket] of original.entries()) {
    const importedBucket = imported.get(key) ?? [];
    if (importedBucket.length < originalBucket.length) {
      for (let i = importedBucket.length; i < originalBucket.length; i += 1) countMissing.push(originalBucket[i]);
    }
    if (originalBucket.length === 1 && importedBucket.length === 1) {
      const before = originalBucket[0];
      const after = importedBucket[0];
      if (before.positionFrames != null && after.positionFrames != null) {
        const drift = after.positionFrames - before.positionFrames;
        if (Math.abs(drift) > toleranceFrames) uniqueDrifts.push({ before, after, drift });
      }
    } else if (importedBucket.length > 0 && originalBucket.length === importedBucket.length) {
      const originalPositions = originalBucket.map((row) => row.position).join(", ");
      const importedPositions = importedBucket.map((row) => row.position).join(", ");
      if (originalPositions !== importedPositions) {
        ambiguousGroups.push({
          key,
          name: originalBucket[0].name,
          notes: originalBucket[0].notes,
          count: originalBucket.length,
          originalPositions,
          importedPositions,
        });
      }
    }
  }
  for (const [key, importedBucket] of imported.entries()) {
    const originalBucket = original.get(key) ?? [];
    if (importedBucket.length > originalBucket.length) {
      for (let i = originalBucket.length; i < importedBucket.length; i += 1) countAdded.push(importedBucket[i]);
    }
  }

  return { countMissing, countAdded, uniqueDrifts, ambiguousGroups };
}

function compareUniqueTitleDurations(originalTitles, importedTitles, toleranceFrames) {
  const original = multiset(originalTitles, (title) => title.identity);
  const imported = multiset(importedTitles, (title) => title.identity);
  const drifts = [];
  for (const [key, originalBucket] of original.entries()) {
    const importedBucket = imported.get(key) ?? [];
    if (originalBucket.length !== 1 || importedBucket.length !== 1) continue;
    const before = originalBucket[0];
    const after = importedBucket[0];
    if (before.durationFrames == null || after.durationFrames == null) continue;
    const drift = after.durationFrames - before.durationFrames;
    if (Math.abs(drift) > toleranceFrames) drifts.push({ before, after, drift });
  }
  return drifts;
}

function compareUniqueTitlePositions(originalTitles, importedTitles, toleranceFrames) {
  const original = multiset(originalTitles, (title) => title.identity);
  const imported = multiset(importedTitles, (title) => title.identity);
  const drifts = [];
  const ambiguous = [];
  for (const [key, originalBucket] of original.entries()) {
    const importedBucket = imported.get(key) ?? [];
    if (originalBucket.length === 1 && importedBucket.length === 1) {
      const before = originalBucket[0];
      const after = importedBucket[0];
      if (before.timelineFrames == null || after.timelineFrames == null) continue;
      const drift = after.timelineFrames - before.timelineFrames;
      if (Math.abs(drift) > toleranceFrames) drifts.push({ before, after, drift });
    } else if (importedBucket.length > 0 && originalBucket.length === importedBucket.length) {
      const beforePositions = originalBucket.map((title) => title.timelineFrames).filter((v) => v != null).join(",");
      const afterPositions = importedBucket.map((title) => title.timelineFrames).filter((v) => v != null).join(",");
      if (beforePositions !== afterPositions) {
        ambiguous.push({
          key,
          name: originalBucket[0].name,
          note: originalBucket[0].note,
          count: originalBucket.length,
          beforeFrames: originalBucket.map((title) => title.timelineFrames),
          afterFrames: importedBucket.map((title) => title.timelineFrames),
        });
      }
    }
  }
  return { drifts, ambiguous };
}

function listLines(items, formatter, limit = 20) {
  if (items.length === 0) return ["  - none"];
  const lines = items.slice(0, limit).map((item) => `  - ${formatter(item)}`);
  if (items.length > limit) lines.push(`  - ... ${items.length - limit} more`);
  return lines;
}

function makeReport(result) {
  const lines = [];
  lines.push("# Conform Prep Verify Report");
  lines.push("");
  lines.push(`Status: ${result.status}`);
  lines.push(`FPS: ${result.options.fps}`);
  lines.push(`Position tolerance: ${result.options.positionToleranceFrames} frame(s)`);
  lines.push("");

  lines.push("## XML Summary");
  for (const summary of result.xmlSummaries) {
    lines.push(
      `- ${summary.label}: titles=${summary.titleCount}, markers=${summary.markerCount}, defaultUnnamedMarkers=${summary.defaultUnnamedMarkerCount}, keywords=${summary.keywordCount}, syncClips=${summary.syncClipCount}, multicam=${summary.multicamClipCount}, offBoundaryTitleOffsets=${summary.titleOffsetsOffBoundary.length}`
    );
  }
  lines.push("");

  lines.push("## Title Identity");
  lines.push(`- missing after FCP import/export: ${result.titleDiff.missing.length}`);
  lines.push(`- added after FCP import/export: ${result.titleDiff.added.length}`);
  lines.push("Missing:");
  lines.push(...listLines(result.titleDiff.missing, firstUsefulLabel));
  lines.push("Added:");
  lines.push(...listLines(result.titleDiff.added, firstUsefulLabel));
  lines.push(`Duration drifts on unique title identities: ${result.titleDurationDrifts.length}`);
  lines.push(
    ...listLines(
      result.titleDurationDrifts,
      (item) => `${firstUsefulLabel(item.before)}: ${item.before.duration} -> ${item.after.duration} (${item.drift > 0 ? "+" : ""}${item.drift}f)`
    )
  );
  lines.push("");

  lines.push("## XML-Derived Timeline Positions");
  lines.push(`- unique title position drifts beyond tolerance: ${result.titlePositionDiff.drifts.length}`);
  lines.push(`- ambiguous duplicate title groups with changed XML-derived positions: ${result.titlePositionDiff.ambiguous.length}`);
  lines.push("Unique XML-derived drifts:");
  lines.push(
    ...listLines(
      result.titlePositionDiff.drifts,
      (item) =>
        `${firstUsefulLabel(item.before)}: ${framesToTimecode(item.before.timelineFrames, result.options.fps)} -> ${framesToTimecode(item.after.timelineFrames, result.options.fps)} (${item.drift > 0 ? "+" : ""}${item.drift}f)`
    )
  );
  lines.push("Ambiguous XML-derived duplicate groups:");
  lines.push(
    ...listLines(
      result.titlePositionDiff.ambiguous,
      (item) =>
        `${item.name} | ${item.note || "-"} x${item.count}: ${item.beforeFrames.map((f) => framesToTimecode(f, result.options.fps)).join(", ")} -> ${item.afterFrames.map((f) => framesToTimecode(f, result.options.fps)).join(", ")}`,
      12
    )
  );
  lines.push("");

  lines.push("## Marker Identity");
  lines.push(`- meaningful missing after FCP import/export: ${result.markerDiff.missing.length}`);
  lines.push(`- meaningful added after FCP import/export: ${result.markerDiff.added.length}`);
  lines.push("Missing:");
  lines.push(...listLines(result.markerDiff.missing, (item) => `${item.tag}: ${firstUsefulLabel(item)}`));
  lines.push("Added:");
  lines.push(...listLines(result.markerDiff.added, (item) => `${item.tag}: ${firstUsefulLabel(item)}`));
  lines.push("");

  if (result.indexDiff) {
    lines.push("## Timeline Index");
    lines.push(`- original rows: ${result.indexDiff.originalCount}`);
    lines.push(`- imported rows: ${result.indexDiff.importedCount}`);
    lines.push(`- missing by Name + Notes: ${result.indexDiff.countMissing.length}`);
    lines.push(`- added by Name + Notes: ${result.indexDiff.countAdded.length}`);
    lines.push(`- unique-position drifts beyond tolerance: ${result.indexDiff.uniqueDrifts.length}`);
    lines.push(`- ambiguous duplicate groups with changed positions: ${result.indexDiff.ambiguousGroups.length}`);
    lines.push("Unique drifts:");
    lines.push(
      ...listLines(
        result.indexDiff.uniqueDrifts,
        (item) => `${item.before.name} | ${item.before.notes || "-"}: ${item.before.position} -> ${item.after.position} (${item.drift > 0 ? "+" : ""}${item.drift}f)`
      )
    );
    lines.push("Ambiguous duplicate groups:");
    lines.push(
      ...listLines(
        result.indexDiff.ambiguousGroups,
        (item) => `${item.name} | ${item.notes || "-"} x${item.count}: ${item.originalPositions} -> ${item.importedPositions}`,
        12
      )
    );
    lines.push("");
  }

  lines.push("## Warnings");
  if (result.warnings.length === 0) lines.push("  - none");
  else lines.push(...result.warnings.map((warning) => `  - ${warning}`));
  lines.push("");
  lines.push("## Notes");
  lines.push("- XML title identity is the primary missing/added check.");
  lines.push("- Timeline Index matching by Name + Notes can be ambiguous when many repeated titles share the same visible name and empty notes.");
  lines.push("- Default unnamed source markers are markers named like `Marker 1` with no note; these should usually stay filtered out.");
  return lines.join("\n");
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const originalXmlPath = await resolveXmlPath(args.originalXml);
  const importedXmlPath = await resolveXmlPath(args.importedXml);
  const patchedXmlPath = args.patchedXml ? await resolveXmlPath(args.patchedXml) : null;

  const [originalXml, importedXml, patchedXml] = await Promise.all([
    readText(originalXmlPath),
    readText(importedXmlPath),
    patchedXmlPath ? readText(patchedXmlPath) : Promise.resolve(null),
  ]);

  const originalSummary = xmlSummary("original", originalXml, args.fps);
  const importedSummary = xmlSummary("imported", importedXml, args.fps);
  const patchedSummary = patchedXml ? xmlSummary("patched", patchedXml, args.fps) : null;

  const titleDiff = compareMultisets(originalSummary.titles, importedSummary.titles, (item) => item.identity);
  const titlePositionDiff = compareUniqueTitlePositions(
    originalSummary.titles,
    importedSummary.titles,
    args.positionToleranceFrames
  );
  const titleDurationDrifts = compareUniqueTitleDurations(
    originalSummary.titles,
    importedSummary.titles,
    args.positionToleranceFrames
  );
  const meaningfulOriginalMarkers = originalSummary.markers.filter((marker) => !marker.defaultUnnamed);
  const meaningfulImportedMarkers = importedSummary.markers.filter((marker) => !marker.defaultUnnamed);
  const markerDiff = compareMultisets(meaningfulOriginalMarkers, meaningfulImportedMarkers, (item) => item.identity);

  let indexDiff = null;
  if (args.originalIndex && args.importedIndex) {
    const [originalIndexText, importedIndexText] = await Promise.all([
      readText(args.originalIndex),
      readText(args.importedIndex),
    ]);
    const originalRows = parseTimelineIndexCsv(originalIndexText, args.fps);
    const importedRows = parseTimelineIndexCsv(importedIndexText, args.fps);
    indexDiff = {
      ...compareTimelineIndex(originalRows, importedRows, args.positionToleranceFrames),
      originalCount: originalRows.length,
      importedCount: importedRows.length,
    };
  }

  const warnings = [];
  if (importedSummary.defaultUnnamedMarkerCount > 0) {
    warnings.push(`imported XML still has ${importedSummary.defaultUnnamedMarkerCount} default unnamed source marker(s)`);
  }
  if (patchedSummary && patchedSummary.defaultUnnamedMarkerCount > 0) {
    warnings.push(`patched XML still has ${patchedSummary.defaultUnnamedMarkerCount} default unnamed source marker(s)`);
  }
  if (importedSummary.syncClipCount > 0) warnings.push(`imported XML still has ${importedSummary.syncClipCount} sync-clip element(s)`);
  if (importedSummary.titleOffsetsOffBoundary.length > 0) {
    warnings.push(`imported XML has ${importedSummary.titleOffsetsOffBoundary.length} title offset(s) off edit-frame boundary`);
  }
  if (titleDurationDrifts.length > 0) {
    warnings.push(`${titleDurationDrifts.length} unique title identity title(s) changed duration beyond tolerance`);
  }
  if (titlePositionDiff.drifts.length > 0) {
    warnings.push(`${titlePositionDiff.drifts.length} unique title identity title(s) changed XML-derived timeline position beyond tolerance`);
  }
  if (titlePositionDiff.ambiguous.length > 0) {
    warnings.push(`${titlePositionDiff.ambiguous.length} duplicate title group(s) changed XML-derived timeline positions`);
  }
  if (indexDiff?.ambiguousGroups.length) {
    warnings.push(`${indexDiff.ambiguousGroups.length} duplicate title group(s) need visual QA because Name + Notes is ambiguous`);
  }

  const fail =
    titleDiff.missing.length > 0 ||
    titleDiff.added.length > 0 ||
    importedSummary.defaultUnnamedMarkerCount > 0 ||
    (indexDiff && (indexDiff.countMissing.length > 0 || indexDiff.countAdded.length > 0));

  const result = {
    status: fail ? "FAIL" : warnings.length ? "WARN" : "PASS",
    options: {
      fps: args.fps,
      positionToleranceFrames: args.positionToleranceFrames,
    },
    inputs: {
      originalXml: originalXmlPath,
      importedXml: importedXmlPath,
      patchedXml: patchedXmlPath,
      originalIndex: args.originalIndex ?? null,
      importedIndex: args.importedIndex ?? null,
    },
    xmlSummaries: [originalSummary, ...(patchedSummary ? [patchedSummary] : []), importedSummary].map((summary) => ({
      label: summary.label,
      titleCount: summary.titleCount,
      markerCount: summary.markerCount,
      defaultUnnamedMarkerCount: summary.defaultUnnamedMarkerCount,
      keywordCount: summary.keywordCount,
      syncClipCount: summary.syncClipCount,
      multicamClipCount: summary.multicamClipCount,
      titleOffsetsOffBoundary: summary.titleOffsetsOffBoundary.map((title) => ({
        name: title.name,
        note: title.note,
        offset: title.offset,
        boundaryError: title.boundaryError,
      })),
    })),
    titleDiff,
    titlePositionDiff,
    titleDurationDrifts,
    markerDiff,
    indexDiff,
    warnings,
  };

  const report = makeReport(result);
  console.log(report);
  if (args.report) await fs.writeFile(args.report, `${report}\n`, "utf8");
  if (args.json) await fs.writeFile(args.json, `${JSON.stringify(result, null, 2)}\n`, "utf8");
  process.exitCode = result.status === "FAIL" ? 1 : 0;
}

main().catch((error) => {
  console.error(`conform-prep verify failed: ${error.stack || error.message}`);
  process.exit(1);
});
