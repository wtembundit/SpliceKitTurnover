import fs from "node:fs/promises";
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
      };
      if (selfClosing !== "/") stack.push(node);
      continue;
    }

    const node = stack.pop();
    if (!node || node.tag !== tag || tag !== "title") continue;
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
  return titles;
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

function prefixProject(xml, mode) {
  const prefix = mode === "auto" ? "📝 " : "🔁 ";
  return xml.replace(/<project\b([^>]*?)\bname="([^"]+)"([^>]*)>/s, (full, before, name, after) => {
    if (name.startsWith(prefix)) return full;
    return `<project${before}name="${encodeXMLAttr(prefix + decodeXML(name))}"${after}>`;
  });
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const xml = await fs.readFile(args.sourceXml, "utf8");
  const titles = collectTitles(xml);
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
  patched = prefixProject(patched, args.mode);

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
    `warnings\t${warnings.length}`,
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
