import fs from "node:fs/promises";
import path from "node:path";

const MARKER_TAGS = new Set(["marker", "chapter-marker"]);
const TIMED_TAGS = new Set([
  "spine",
  "gap",
  "clip",
  "asset-clip",
  "sync-clip",
  "mc-clip",
  "ref-clip",
  "video",
  "audio",
  "title",
]);

function printUsage() {
  console.log(`Usage:
  node lua/scripts/export_markers_fcpxml.mjs \\
    --source-xml <path> \\
    --output-dir <path> \\
    --filter <all|standard|todo|chapter|recheck> \\
    --format <edl|csv|txt> \\
    --report <path>
`);
}

function parseArgs(argv) {
  const args = { filter: "all", format: "edl" };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--source-xml") args.sourceXml = path.resolve(argv[++i]);
    else if (arg === "--output-dir") args.outputDir = path.resolve(argv[++i]);
    else if (arg === "--filter") args.filter = String(argv[++i] || "all").toLowerCase();
    else if (arg === "--format") args.format = String(argv[++i] || "all").toLowerCase();
    else if (arg === "--report") args.report = path.resolve(argv[++i]);
    else if (arg === "--help" || arg === "-h") {
      printUsage();
      process.exit(0);
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }
  if (!args.sourceXml || !args.outputDir || !args.report) {
    printUsage();
    throw new Error("Missing required arguments.");
  }
  if (!["all", "standard", "todo", "chapter", "recheck"].includes(args.filter)) {
    throw new Error(`Unsupported marker filter: ${args.filter}`);
  }
  if (!["edl", "csv", "txt"].includes(args.format)) {
    throw new Error(`Unsupported marker export format: ${args.format}`);
  }
  return args;
}

function trim(value) {
  return String(value ?? "").trim();
}

function decodeXML(value = "") {
  return String(value)
    .replace(/&quot;/g, "\"")
    .replace(/&apos;/g, "'")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&amp;/g, "&");
}

function parseAttrs(attrStr = "") {
  const attrs = {};
  const regex = /([\w:_-]+)\s*=\s*"([^"]*)"/g;
  let match;
  while ((match = regex.exec(attrStr))) attrs[match[1]] = match[2];
  return attrs;
}

function parseSeconds(value) {
  if (!value) return null;
  const fraction = /^(-?\d+)\/(\d+)s$/.exec(value);
  if (fraction) {
    const numerator = Number(fraction[1]);
    const denominator = Number(fraction[2]);
    if (denominator !== 0) return numerator / denominator;
  }
  const seconds = /^(-?\d+(?:\.\d+)?)s$/.exec(value);
  if (seconds) return Number(seconds[1]);
  return null;
}

function csvCell(value) {
  const text = String(value ?? "");
  return /[",\n\r]/.test(text) ? `"${text.replace(/"/g, "\"\"")}"` : text;
}

function sanitizeFilename(value) {
  return trim(value)
    .replace(/[\\/:*?"<>|]+/g, "_")
    .replace(/\s+/g, " ")
    .slice(0, 160) || "Markers";
}

function markerKind(tag, attrs) {
  if (tag === "chapter-marker") return "Chapter";
  if (attrs.completed === "0") return "To Do";
  return "Standard";
}

function markerColor(kind, attrs) {
  if (isRecheckMarker(attrs)) return "Purple";
  if (kind === "Chapter") return "Blue";
  if (kind === "To Do") return "Red";
  return "Green";
}

function resolveColorName(color) {
  const normalized = trim(color).toLowerCase();
  const known = {
    blue: "ResolveColorBlue",
    cyan: "ResolveColorCyan",
    green: "ResolveColorGreen",
    yellow: "ResolveColorYellow",
    red: "ResolveColorRed",
    pink: "ResolveColorPink",
    purple: "ResolveColorPurple",
    fuchsia: "ResolveColorFuchsia",
    rose: "ResolveColorRose",
    lavender: "ResolveColorLavender",
    sky: "ResolveColorSky",
    mint: "ResolveColorMint",
    lemon: "ResolveColorLemon",
    sand: "ResolveColorSand",
    cocoa: "ResolveColorCocoa",
    cream: "ResolveColorCream",
  };
  return known[normalized] || "ResolveColorBlue";
}

function edlSingleLine(value) {
  return String(value ?? "")
    .replace(/\s*\r?\n\s*/g, " / ")
    .replace(/\|/g, "/")
    .trim();
}

function isRecheckMarker(attrs) {
  return /^TURNOVER RECHECK:/i.test(decodeXML(attrs.value || ""));
}

function isGenericMarkerName(name) {
  return /^Marker\s+\d+$/i.test(trim(name));
}

function markerMatchesFilter(tag, attrs, filter) {
  const kind = markerKind(tag, attrs);
  const name = decodeXML(attrs.value || kind);
  const note = decodeXML(attrs.note || "");
  const defaultStandardMarker = kind === "Standard" && isGenericMarkerName(name) && !trim(note);
  if (defaultStandardMarker) return false;
  if (filter === "all") return true;
  if (filter === "standard") return kind === "Standard" && !isRecheckMarker(attrs);
  if (filter === "todo") return kind === "To Do";
  if (filter === "chapter") return kind === "Chapter";
  if (filter === "recheck") return isRecheckMarker(attrs);
  return true;
}

function parseFormats(xml) {
  const formats = {};
  for (const match of xml.matchAll(/<format\s+([^>]*?)(?:\/>|>[\s\S]*?<\/format>)/g)) {
    const attrs = parseAttrs(match[1]);
    if (!attrs.id) continue;
    formats[attrs.id] = {
      frameDuration: parseSeconds(attrs.frameDuration),
      name: trim(attrs.name),
    };
  }
  return formats;
}

function parseProjectInfo(xml, formats) {
  const projectMatch = /<project\s+([^>]*?)>/s.exec(xml);
  const projectAttrs = projectMatch ? parseAttrs(projectMatch[1]) : {};
  const sequenceMatch = /<sequence\s+([^>]*?)>/s.exec(xml);
  const sequenceAttrs = sequenceMatch ? parseAttrs(sequenceMatch[1]) : {};
  const format = formats[sequenceAttrs.format] || {};
  return {
    projectName: decodeXML(projectAttrs.name || "Markers"),
    frameDuration: format.frameDuration || parseSeconds(sequenceAttrs.frameDuration) || (1 / 24),
    tcStart: parseSeconds(sequenceAttrs.tcStart) || 0,
    tcFormat: trim(sequenceAttrs.tcFormat || "NDF"),
  };
}

function fpsFromFrameDuration(frameDuration) {
  return Math.max(1, Math.round(1 / (frameDuration || (1 / 24))));
}

function formatTC(seconds, frameDuration, tcFormat = "NDF") {
  const fps = fpsFromFrameDuration(frameDuration);
  let frames = Math.max(0, Math.round(seconds / frameDuration));
  if (tcFormat.toUpperCase() === "DF" && (fps === 30 || fps === 60)) {
    const dropFrames = Math.round(fps * 0.0666666667);
    const framesPerMinute = (fps * 60) - dropFrames;
    const framesPerTenMinutes = (fps * 600) - (dropFrames * 9);
    const tenMinuteChunks = Math.floor(frames / framesPerTenMinutes);
    const remainder = frames % framesPerTenMinutes;
    frames += (dropFrames * 9 * tenMinuteChunks)
      + Math.floor((dropFrames * Math.max(0, remainder - dropFrames)) / framesPerMinute);
  }
  const ff = frames % fps;
  const totalSeconds = Math.floor(frames / fps);
  const ss = totalSeconds % 60;
  const totalMinutes = Math.floor(totalSeconds / 60);
  const mm = totalMinutes % 60;
  const hh = Math.floor(totalMinutes / 60) % 24;
  return [hh, mm, ss, ff].map((part) => String(part).padStart(2, "0")).join(":");
}

function collectMarkers(xml, projectInfo, filter) {
  const markers = [];
  const stack = [{ tag: "root", abs: 0, cursor: 0, name: "" }];
  const tagRegex = /<!--[\s\S]*?-->|<\?[\s\S]*?\?>|<!DOCTYPE[\s\S]*?>|<\/?[\w:-]+(?:\s+[^<>]*?)?\/?>/g;
  let match;
  while ((match = tagRegex.exec(xml))) {
    const token = match[0];
    if (!token.startsWith("<") || token.startsWith("<!--") || token.startsWith("<?") || token.startsWith("<!")) continue;

    const closing = /^<\//.test(token);
    const selfClosing = /\/>$/.test(token);
    const tagMatch = /^<\/?([\w:-]+)([\s\S]*?)\/?>$/.exec(token);
    if (!tagMatch) continue;
    const tag = tagMatch[1];

    if (closing) {
      const frame = stack.pop();
      if (frame && stack.length > 0 && frame.duration > 0) {
        const parent = stack[stack.length - 1];
        parent.cursor = Math.max(parent.cursor, frame.abs + frame.duration);
      }
      continue;
    }

    const attrs = parseAttrs(tagMatch[2] || "");
    const parent = stack[stack.length - 1] || { abs: 0, cursor: 0, name: "" };

    if (MARKER_TAGS.has(tag)) {
      if (markerMatchesFilter(tag, attrs, filter)) {
        const offset = parseSeconds(attrs.offset) || 0;
        const duration = parseSeconds(attrs.duration) || 0;
        const timelineSeconds = parent.abs + offset;
        const tcSeconds = projectInfo.tcStart + timelineSeconds;
        const kind = markerKind(tag, attrs);
        markers.push({
          kind,
          name: decodeXML(attrs.value || kind),
          note: decodeXML(attrs.note || ""),
          color: markerColor(kind, attrs),
          owner: parent.name,
          timelineSeconds,
          duration,
          timelineTC: formatTC(tcSeconds, projectInfo.frameDuration, projectInfo.tcFormat),
          durationFrames: Math.max(0, Math.round(duration / projectInfo.frameDuration)),
        });
      }
      continue;
    }

    const isTimed = TIMED_TAGS.has(tag);
    const offset = parseSeconds(attrs.offset);
    const duration = parseSeconds(attrs.duration) || 0;
    const abs = isTimed
      ? (offset == null ? parent.cursor : parent.abs + offset)
      : parent.abs;
    const frame = {
      tag,
      abs,
      duration,
      cursor: abs,
      name: decodeXML(attrs.name || parent.name || ""),
    };

    if (!selfClosing) {
      stack.push(frame);
    } else if (isTimed && duration > 0) {
      parent.cursor = Math.max(parent.cursor, abs + duration);
    }
  }
  return pruneInternalGenericMarkers(markers)
    .sort((a, b) => a.timelineSeconds - b.timelineSeconds || a.name.localeCompare(b.name));
}

function pruneInternalGenericMarkers(markers) {
  const seen = new Set();
  const out = [];
  for (const marker of markers) {
    const key = [
      marker.kind,
      marker.timelineTC,
      marker.owner,
      marker.name,
      marker.note,
    ].join("\u0001");
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(marker);
  }
  return out;
}

function buildCsv(projectInfo, markers) {
  const rows = [
    ["Project", projectInfo.projectName],
    ["Frame Rate", String(fpsFromFrameDuration(projectInfo.frameDuration))],
    [],
    ["Index", "Timeline TC", "Type", "Color", "Name", "Note", "Duration Frames", "Owner"],
  ];
  markers.forEach((marker, index) => {
    rows.push([
      String(index + 1),
      marker.timelineTC,
      marker.kind,
      marker.color,
      marker.name,
      marker.note,
      String(marker.durationFrames),
      marker.owner,
    ]);
  });
  return rows.map((row) => row.map(csvCell).join(",")).join("\n") + "\n";
}

function buildTxt(projectInfo, markers) {
  const lines = [
    `Project: ${projectInfo.projectName}`,
    `Markers: ${markers.length}`,
    "",
  ];
  markers.forEach((marker, index) => {
    lines.push(`${String(index + 1).padStart(3, "0")}  ${marker.timelineTC}  [${marker.kind}] ${marker.name}`);
    if (marker.note) lines.push(`     Note: ${marker.note}`);
    if (marker.owner) lines.push(`     Owner: ${marker.owner}`);
  });
  return lines.join("\n") + "\n";
}

function buildEdl(projectInfo, markers) {
  const lines = [
    `TITLE: ${projectInfo.projectName}`,
    "FCM: NON-DROP FRAME",
    "",
  ];
  const frameDuration = projectInfo.frameDuration || (1 / 24);
  const occupiedFrames = new Set();
  let nudged = 0;
  markers.forEach((marker, index) => {
    const event = String(index + 1).padStart(3, "0");
    const baseFrame = Math.max(0, Math.round(marker.timelineSeconds / frameDuration));
    let edlFrame = baseFrame;
    while (occupiedFrames.has(edlFrame)) edlFrame += 1;
    occupiedFrames.add(edlFrame);
    const frameOffset = edlFrame - baseFrame;
    if (frameOffset > 0) nudged += 1;
    const edlSeconds = edlFrame * frameDuration;
    const edlTC = formatTC(projectInfo.tcStart + edlSeconds, frameDuration, projectInfo.tcFormat);
    const end = marker.duration > 0
      ? formatTC(projectInfo.tcStart + edlSeconds + marker.duration, frameDuration, projectInfo.tcFormat)
      : edlTC;
    const durationFrames = Math.max(1, marker.durationFrames || 1);
    lines.push(`${event}  AX       V     C        ${edlTC} ${end} ${edlTC} ${end}`);
    if (marker.note) lines.push(`* NOTE: ${edlSingleLine(marker.note)}`);
    if (marker.owner) lines.push(`* OWNER: ${edlSingleLine(marker.owner)}`);
    if (frameOffset > 0) lines.push(`* TURNOVER: nudged +${frameOffset} frame(s) to keep same-frame Resolve markers separate. Original TC ${marker.timelineTC}`);
    lines.push(` |C:${resolveColorName(marker.color)} |M:${edlSingleLine(marker.name)} |D:${durationFrames}`);
    lines.push("");
  });
  return { text: lines.join("\n"), nudged };
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const xml = await fs.readFile(args.sourceXml, "utf8");
  const formats = parseFormats(xml);
  const projectInfo = parseProjectInfo(xml, formats);
  const markers = collectMarkers(xml, projectInfo, args.filter);
  await fs.mkdir(args.outputDir, { recursive: true });

  const base = `Markers - ${sanitizeFilename(projectInfo.projectName)} - ${args.filter}`;
  const edlPath = path.join(args.outputDir, `${base}.edl`);
  const csvPath = path.join(args.outputDir, `${base}.csv`);
  const txtPath = path.join(args.outputDir, `${base}.txt`);
  const shouldWrite = (format) => args.format === format;
  const edlResult = shouldWrite("edl") ? buildEdl(projectInfo, markers) : { text: "", nudged: 0 };
  if (shouldWrite("edl")) await fs.writeFile(edlPath, edlResult.text);
  if (shouldWrite("csv")) await fs.writeFile(csvPath, buildCsv(projectInfo, markers));
  if (shouldWrite("txt")) await fs.writeFile(txtPath, buildTxt(projectInfo, markers));

  const report = [
    `source_xml\t${args.sourceXml}`,
    `project\t${projectInfo.projectName}`,
    `filter\t${args.filter}`,
    `format\t${args.format}`,
    `markers\t${markers.length}`,
    `resolve_edl_same_frame_markers_nudged\t${edlResult.nudged}`,
    `edl_path\t${shouldWrite("edl") ? edlPath : ""}`,
    `csv_path\t${shouldWrite("csv") ? csvPath : ""}`,
    `txt_path\t${shouldWrite("txt") ? txtPath : ""}`,
    "",
    "notes:",
    "- EDL and CSV marker export are intended for Resolve marker interchange and editorial review.",
    "- This tool reads FCPXML only; it does not rewrite or import a timeline.",
  ].join("\n");
  await fs.writeFile(args.report, report + "\n");

  console.log(JSON.stringify({
    status: "ok",
    marker_count: markers.length,
    edl_path: shouldWrite("edl") ? edlPath : null,
    csv_path: shouldWrite("csv") ? csvPath : null,
    txt_path: shouldWrite("txt") ? txtPath : null,
    report_path: args.report,
  }));
}

main().catch((error) => {
  console.error(error?.stack || String(error));
  process.exit(1);
});
