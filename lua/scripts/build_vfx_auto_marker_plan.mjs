import fs from "node:fs/promises";
import path from "node:path";

const CONFIG = {
  minReasonableTime: 0,
  maxReasonableTime: 86400,
  maxReasonableGap: 3600,
};

function printUsage() {
  console.log(`Usage:
  node lua/scripts/build_vfx_auto_marker_plan.mjs \\
    --source-xml <path> \\
    --output-plan <path> \\
    --report <path>
`);
}

function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--source-xml") args.sourceXml = path.resolve(argv[++i]);
    else if (arg === "--output-plan") args.outputPlan = path.resolve(argv[++i]);
    else if (arg === "--report") args.report = path.resolve(argv[++i]);
    else if (arg === "--help" || arg === "-h") {
      printUsage();
      process.exit(0);
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }
  if (!args.sourceXml || !args.outputPlan || !args.report) {
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

function unescapeXML(value) {
  return String(value ?? "")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&amp;/g, "&");
}

function splitNonEmptyLines(value) {
  return String(value || "")
    .replace(/\u2028/g, "\n")
    .replace(/\r\n/g, "\n")
    .replace(/\r/g, "\n")
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean);
}

function extractTextFromInner(inner = "") {
  const parts = [];
  for (const match of inner.matchAll(/<text-style[^>]*>(.*?)<\/text-style>/gs)) {
    const cleaned = trim(unescapeXML(match[1]));
    if (cleaned) parts.push(cleaned);
  }
  if (parts.length === 0) {
    for (const match of inner.matchAll(/<text[^>]*>(.*?)<\/text>/gs)) {
      const cleaned = trim(unescapeXML(match[1].replace(/<[^>]+>/g, "")));
      if (cleaned) parts.push(cleaned);
    }
  }
  return parts.join("\n");
}

function isVfxTitle(titleName, titleText) {
  const lowerName = String(titleName || "").toLowerCase();
  const firstLine = splitNonEmptyLines(titleText)[0] || "";
  if (lowerName.includes("vfx naming")) return true;
  if (/^[A-Z0-9_-]+_\d{4}$/.test(firstLine)) return true;
  if (/^[A-Z0-9_-]+_XXXX$/.test(firstLine)) return true;
  return false;
}

function deriveMarkerNameAndNote(titleName, titleText) {
  const lines = splitNonEmptyLines(titleText);
  const firstLine = lines[0] || "";
  const shotCodeFromName = /^([A-Z0-9_-]+)\s*-\s*VFX\s+NAMING$/.exec(titleName)?.[1];
  const markerName = trim(firstLine) || shotCodeFromName || trim(titleName);
  const markerNote = lines.slice(1).map(trim).filter(Boolean).join("\n");
  return { markerName, markerNote };
}

function resolvedAbsTime(parentCtx, attrs) {
  const parentAbs = parentCtx?.absTime ?? 0;
  const parentStart = parentCtx?.start ?? 0;
  const myOffset = parseFraction(attrs.offset) || 0;
  return parentAbs + (myOffset - parentStart);
}

function contextTimelineStart(parentCtx, attrs) {
  const parentTl = parentCtx?.timelineStart ?? 0;
  const myOffset = parseFraction(attrs.offset) || 0;
  return parentTl + myOffset;
}

function tsvEscape(value) {
  return String(value ?? "").replace(/\\/g, "\\\\").replace(/\t/g, "\\t").replace(/\r/g, "\\r").replace(/\n/g, "\\n");
}

function formatSeconds(seconds) {
  const value = Math.round((Number(seconds) || 0) * 1_000_000) / 1_000_000;
  return `${String(value).replace(/\.?0+$/, "") || "0"}s`;
}

function parseSourceTitles(xml) {
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
      const absTime = resolvedAbsTime(parent, attrs);
      const startVal = parseFraction(attrs.start) || 0;
      const durationVal = parseFraction(attrs.duration) || 0;
      const laneVal = Number(attrs.lane) || 0;
      const node = {
        tag: tagName,
        attrs,
        timelineStart,
        absTime,
        start: startVal,
        duration: durationVal,
        lane: laneVal,
        openEnd: tagRegex.lastIndex,
      };
      if (selfClose !== "/") stack.push(node);
    } else {
      const node = stack.pop();
      if (node?.tag === "title") {
        const titleName = node.attrs?.name || "";
        const inner = xml.slice(node.openEnd, match.index);
        const titleText = extractTextFromInner(inner);
        if (isVfxTitle(titleName, titleText)) {
          const { markerName, markerNote } = deriveMarkerNameAndNote(titleName, titleText);
          titles.push({
            sourceTitleName: titleName,
            markerName,
            markerNote,
            timelineTime: node.absTime + (node.duration / 2.0),
            duration: node.duration,
            lane: node.lane,
          });
        }
      }
    }
  }
  titles.sort((a, b) => a.timelineTime - b.timelineTime);
  return titles;
}

function sanityCheckEvents(events) {
  if (events.length === 0) return "No VFX titles found";
  for (let i = 0; i < events.length; i += 1) {
    const event = events[i];
    if (event.timelineTime < CONFIG.minReasonableTime || event.timelineTime > CONFIG.maxReasonableTime) {
      return `Unreasonable parsed time for ${event.markerName}: ${formatSeconds(event.timelineTime)}`;
    }
    if (i > 0) {
      const gap = event.timelineTime - events[i - 1].timelineTime;
      if (gap > CONFIG.maxReasonableGap) {
        return `Suspiciously large gap between ${events[i - 1].markerName} and ${event.markerName}: ${formatSeconds(gap)}`;
      }
    }
  }
  return "";
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const xml = await fs.readFile(args.sourceXml, "utf8");
  const events = parseSourceTitles(xml);
  const sanity = sanityCheckEvents(events);
  if (sanity) throw new Error(`Source export sanity check failed: ${sanity}`);

  await fs.mkdir(path.dirname(args.outputPlan), { recursive: true });
  await fs.mkdir(path.dirname(args.report), { recursive: true });
  const lines = [
    ["index", "timeline_seconds", "marker_name", "marker_note", "source_title_name", "duration", "lane"].join("\t"),
    ...events.map((event, index) => [
      index + 1,
      Number(event.timelineTime || 0).toFixed(6),
      tsvEscape(event.markerName),
      tsvEscape(event.markerNote),
      tsvEscape(event.sourceTitleName),
      Number(event.duration || 0).toFixed(6),
      event.lane || 0,
    ].join("\t")),
  ];
  await fs.writeFile(args.outputPlan, `${lines.join("\n")}\n`);
  await fs.writeFile(args.report, [
    `source_xml\t${args.sourceXml}`,
    `events\t${events.length}`,
    ...events.slice(0, 120).map((event, index) => `event_${String(index + 1).padStart(3, "0")}\t${formatSeconds(event.timelineTime)}\t${event.markerName}`),
    "",
  ].join("\n"));
  console.log(JSON.stringify({ status: "ok", events: events.length, plan_path: args.outputPlan, report_path: args.report }));
}

main().catch((error) => {
  console.error(error.stack || String(error));
  process.exit(1);
});
