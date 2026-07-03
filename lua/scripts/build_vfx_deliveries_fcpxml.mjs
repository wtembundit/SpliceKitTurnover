import fs from "node:fs/promises";
import path from "node:path";
import { execFile as execFileCallback } from "node:child_process";
import { promisify } from "node:util";
import { pathToFileURL } from "node:url";
import crypto from "node:crypto";

const execFile = promisify(execFileCallback);

async function validateGeneratedFCPXML(xmlPath, xml) {
  try {
    await execFile("xmllint", ["--noout", xmlPath]);
  } catch (error) {
    throw new Error(`Generated FCPXML is not well formed: ${trim(error?.stderr || error?.message)}`);
  }

  const version = trim(/<fcpxml\s+version="([^"]+)"/.exec(xml)?.[1]);
  if (!version) return;
  const dtdPath = `/Applications/Final Cut Pro.app/Contents/Frameworks/Interchange.framework/Versions/A/Resources/FCPXMLv${version.replace(/\./g, "_")}.dtd`;
  try {
    await fs.access(dtdPath);
  } catch {
    return;
  }
  try {
    const validationPath = `${xmlPath}.validate.fcpxml`;
    const dtdURL = `file://${dtdPath.replace(/ /g, "%20")}`;
    const doctype = `<!DOCTYPE fcpxml SYSTEM "${dtdURL}">`;
    const validationXML = /<!DOCTYPE\s+fcpxml(?:\s+SYSTEM\s+"[^"]*")?\s*>/.test(xml)
      ? xml.replace(/<!DOCTYPE\s+fcpxml(?:\s+SYSTEM\s+"[^"]*")?\s*>/, doctype)
      : xml.replace(/<fcpxml\b/, `${doctype}\n<fcpxml`);
    await fs.writeFile(validationPath, validationXML, "utf8");
    try {
      await execFile("xmllint", ["--noout", "--loaddtd", "--valid", validationPath]);
    } finally {
      await fs.rm(validationPath, { force: true });
    }
  } catch (error) {
    throw new Error(`Generated FCPXML failed DTD ${version}: ${trim(error?.stderr || error?.message)}`);
  }
}

function printUsage() {
  console.log(`Usage:
  node lua/scripts/build_vfx_deliveries_fcpxml.mjs \\
    --source-xml <path> \\
    --config <path> \\
    --output-xml <path> \\
    --report <path>
`);
}

function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--source-xml") {
      args.sourceXml = path.resolve(argv[++i]);
    } else if (arg === "--config") {
      args.config = path.resolve(argv[++i]);
    } else if (arg === "--output-xml") {
      args.outputXml = path.resolve(argv[++i]);
    } else if (arg === "--report") {
      args.report = path.resolve(argv[++i]);
    } else if (arg === "--help" || arg === "-h") {
      printUsage();
      process.exit(0);
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }
  if (!args.sourceXml || !args.config || !args.outputXml || !args.report) {
    printUsage();
    throw new Error("Missing required arguments.");
  }
  return args;
}

function parseFraction(str) {
  if (!str) return null;
  const frac = /^([-\d.]+)\/([-\d.]+)s$/.exec(str);
  if (frac) {
    const [, a, b] = frac;
    const num = Number(a);
    const den = Number(b);
    if (Number.isFinite(num) && Number.isFinite(den) && den !== 0) {
      return num / den;
    }
  }
  const secs = /^([-\d.]+)s$/.exec(str);
  if (secs) return Number(secs[1]);
  return null;
}

function formatSeconds(sec) {
  return `${Number(sec || 0).toFixed(6).replace(/0+$/, "").replace(/\.$/, "") || "0"}s`;
}

function parseAttrs(attrStr = "") {
  const attrs = {};
  const regex = /([\w:_-]+)\s*=\s*"([^"]*)"/g;
  let match;
  while ((match = regex.exec(attrStr))) {
    attrs[match[1]] = match[2];
  }
  return attrs;
}

function trim(value) {
  return String(value ?? "").trim();
}

function parseKeyValueTSV(text) {
  const map = {};
  for (const rawLine of text.split(/\r?\n/)) {
    if (!rawLine.trim()) continue;
    const [key, value = ""] = rawLine.split("\t");
    map[key] = value;
  }
  return map;
}

function splitUS(value) {
  return String(value || "")
    .split("\u001F")
    .map((item) => item.trim())
    .filter(Boolean);
}

function contextTimelineStart(parentCtx, attrs) {
  const parentTl = parentCtx?.timelineStart ?? 0;
  const myOffset = parseFraction(attrs.offset);
  if (myOffset == null) return parentTl;
  const parentStart = parentCtx?.start ?? 0;
  return parentTl + myOffset - parentStart;
}

function collectTitles(xml) {
  return collectStoryNodes(xml, new Set(["title"]))
    .filter((node) => {
      const titleName = trim(node.attrs.name);
      return titleName.endsWith(" - VFX NAMING");
    })
    .map((node) => {
      const titleName = trim(node.attrs.name);
      const vfxNumber = trim(titleName.replace(/\s+-\s+VFX NAMING$/, ""));
      return {
        vfxNumber,
        titleName,
        timelineStart: node.timelineStart,
        duration: node.duration,
        offsetAttr: node.attrs.offset || formatSeconds(node.timelineStart),
        durationAttr: node.attrs.duration || formatSeconds(node.duration),
        parentNode: node.parentNode,
        parentKey: node.parentKey,
      };
    })
    .sort((a, b) => a.timelineStart - b.timelineStart);
}

function collectStoryNodes(xml, wantedTags) {
  const titles = [];
  const stack = [];
  const tagRegex = /<(\/?)([\w:_-]+)(.*?)(\/?)>/gs;
  let match;

  while ((match = tagRegex.exec(xml))) {
    const [, closing, tagName, attrStr, selfClose] = match;
    const isClosing = closing === "/";
    const isSelfClosing = selfClose === "/";

    if (!isClosing) {
      const attrs = parseAttrs(attrStr);
      const parent = stack.at(-1);
      const timelineStart = contextTimelineStart(parent, attrs);
      const node = {
        tag: tagName,
        attrs,
        timelineStart,
        start: parseFraction(attrs.start) ?? (parent?.start ?? 0),
        duration: parseFraction(attrs.duration) ?? 0,
        parentKey: parent ? `${parent.openStart}:${parent.closeStart ?? "?"}:${parent.tag}` : "",
        parentNode: parent || null,
        openStart: match.index,
        openEnd: tagRegex.lastIndex,
        closeStart: null,
        closeEnd: null,
      };

      if (!isSelfClosing) {
        stack.push(node);
      } else if (wantedTags.has(tagName)) {
        titles.push(node);
      }
    } else {
      const node = stack.pop();
      if (node) {
        node.closeStart = match.index;
        node.closeEnd = tagRegex.lastIndex;
        node.parentKey = stack.at(-1) ? `${stack.at(-1).openStart}:${stack.at(-1).closeStart ?? "?"}:${stack.at(-1).tag}` : "";
        node.parentNode = stack.at(-1) || null;
      }
      if (node && wantedTags.has(node.tag)) {
        titles.push(node);
      }
    }
  }
  return titles;
}

function parseFormats(xml) {
  const formats = new Map();
  for (const match of xml.matchAll(/<format\s+([^>]+?)\/>/g)) {
    const attrs = parseAttrs(match[1]);
    if (attrs.id) {
      formats.set(attrs.id, {
        frameDuration: parseFraction(attrs.frameDuration) ?? (1 / 24),
      });
    }
  }
  return formats;
}

function parseSequenceFormat(xml) {
  const seqMatch = xml.match(/<sequence\s+([^>]+?)>/);
  if (!seqMatch) throw new Error("Could not find sequence in source FCPXML.");
  const attrs = parseAttrs(seqMatch[1]);
  return {
    formatId: attrs.format || "",
    tcFormat: attrs.tcFormat || "NDF",
  };
}

function nextResourceId(xml) {
  let maxId = 0;
  for (const match of xml.matchAll(/\bid="r(\d+)"/g)) {
    maxId = Math.max(maxId, Number(match[1]));
  }
  return maxId + 1;
}

function extractVFXNumber(fileName) {
  const match = String(fileName).toUpperCase().match(/[A-Z0-9]+_SC\d+_\d{4}/);
  return match ? match[0] : "";
}

function extractShotCode(value) {
  const match = String(value).toUpperCase().match(/SC\d+_\d{4}/);
  return match ? match[0] : "";
}

async function walkFiles(rootDir) {
  const found = [];
  async function walk(dir) {
    const entries = await fs.readdir(dir, { withFileTypes: true });
    for (const entry of entries) {
      const fullPath = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        await walk(fullPath);
      } else {
        found.push(fullPath);
      }
    }
  }
  await walk(rootDir);
  return found;
}

function looksLikeMediaFile(filePath) {
  return [".mov", ".mp4", ".mxf", ".m4v", ".avi", ".mpg", ".mpeg"].includes(path.extname(filePath).toLowerCase());
}

async function probeDurationSeconds(filePath) {
  try {
    const ffprobe = (await execFile("/usr/bin/which", ["ffprobe"])).stdout.trim();
    if (ffprobe) {
      const { stdout } = await execFile(ffprobe, [
        "-v", "error",
        "-show_entries", "format=duration",
        "-of", "default=nw=1:nk=1",
        filePath,
      ]);
      const value = Number(stdout.trim());
      if (Number.isFinite(value) && value > 0) return value;
    }
  } catch {}

  try {
    const { stdout } = await execFile("/usr/bin/mdls", ["-raw", "-name", "kMDItemDurationSeconds", filePath]);
    const value = Number(String(stdout).trim());
    if (Number.isFinite(value) && value > 0) return value;
  } catch {}

  return null;
}

async function buildDeliveryCandidates(folderPath) {
  const files = (await walkFiles(folderPath)).filter(looksLikeMediaFile);
  const byShotCode = new Map();
  for (const filePath of files) {
    const fileName = path.basename(filePath);
    const vfxNumber = extractVFXNumber(fileName);
    const shotCode = extractShotCode(vfxNumber || fileName);
    if (!shotCode) continue;
    const stat = await fs.stat(filePath);
    const item = {
      vfxNumber,
      shotCode,
      filePath,
      fileName,
      mtimeMs: stat.mtimeMs,
      durationSeconds: await probeDurationSeconds(filePath),
    };
    if (!byShotCode.has(shotCode)) byShotCode.set(shotCode, []);
    byShotCode.get(shotCode).push(item);
  }

  for (const items of byShotCode.values()) {
    items.sort((a, b) => compareDeliveryCandidates(a, b));
  }
  return byShotCode;
}

function extractVersionNumber(fileName) {
  const match = String(fileName).toUpperCase().match(/(?:^|[^A-Z0-9])V(\d{1,4})(?:[^A-Z0-9]|$)/);
  return match ? Number(match[1]) : -1;
}

function compareDeliveryCandidates(a, b) {
  const versionDelta = extractVersionNumber(b.fileName) - extractVersionNumber(a.fileName);
  if (versionDelta !== 0) return versionDelta;
  const timeDelta = b.mtimeMs - a.mtimeMs;
  if (timeDelta !== 0) return timeDelta;
  return a.fileName.localeCompare(b.fileName);
}

function xmlEscape(value) {
  return String(value ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function removePriorVFXDeliveryClips(xml) {
  return xml.replace(/<asset-clip\b[^>]*>[\s\S]*?<note>SpliceKit VFX Timeline<\/note>[\s\S]*?<\/asset-clip>\s*/g, "");
}

function stripAttr(xml, attrName) {
  const regex = new RegExp(`\\s${attrName}="[^"]*"`, "g");
  return xml.replace(regex, "");
}

function removeRanges(xml, ranges) {
  const ordered = [...ranges]
    .filter((range) => Number.isFinite(range?.start) && Number.isFinite(range?.end) && range.end > range.start)
    .sort((a, b) => b.start - a.start);

  let out = xml;
  for (const range of ordered) {
    out = `${out.slice(0, range.start)}${out.slice(range.end)}`;
  }
  return out;
}

function intervalsOverlap(aStart, aDuration, bStart, bDuration) {
  const aEnd = aStart + aDuration;
  const bEnd = bStart + bDuration;
  return aStart < bEnd && bStart < aEnd;
}

function isVFXNode(node, xml) {
  if (!node?.closeEnd || !node?.openStart) return false;
  if (node.tag === "asset-clip" && trim(node.attrs.videoRole) === "VFX") return true;
  const body = xml.slice(node.openStart, node.closeEnd);
  return body.includes("<note>SpliceKit VFX Timeline</note>");
}

function collectExistingVFXNodes(xml) {
  const nodes = collectStoryNodes(xml, new Set(["asset-clip", "audition"]));
  return nodes
    .filter((node) => {
      if (!isVFXNode(node, xml)) return false;
      if (node.parentNode?.tag === "audition" && node.tag === "asset-clip") return false;
      return true;
    })
    .map((node) => {
      const body = xml.slice(node.openStart, node.closeEnd);
      const noteMatch = body.match(/<note>([\s\S]*?)<\/note>/);
      const noteText = noteMatch ? noteMatch[1].replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&") : "";
      const lane = Number(node.attrs.lane || 0) || 0;
      const shotCode = extractShotCode(node.attrs.name || body);
      return {
        ...node,
        body,
        noteText,
        lane,
        shotCode,
      };
    });
}

function buildClipNote({ batchName, placementMode, fileName }) {
  return [
    "SpliceKit VFX Timeline",
    batchName ? `Batch: ${batchName}` : "",
    placementMode ? `Mode: ${placementMode}` : "",
    fileName ? `Source: ${fileName}` : "",
  ].filter(Boolean).join("\n");
}

function buildConnectedAssetClipXml({
  assetId,
  clipName,
  startSeconds,
  durationAttr,
  sequence,
  lane,
  offsetAttr,
  noteText,
  includeOffset,
  includeLane,
}) {
  const attrs = [
    `ref="${assetId}"`,
    includeOffset ? `offset="${xmlEscape(offsetAttr)}"` : "",
    `name="${xmlEscape(clipName)}"`,
    `start="${formatSeconds(startSeconds)}"`,
    `duration="${xmlEscape(durationAttr)}"`,
    `format="${xmlEscape(sequence.formatId)}"`,
    `tcFormat="${xmlEscape(sequence.tcFormat)}"`,
    includeLane ? `lane="${lane}"` : "",
    `videoRole="VFX"`,
  ].filter(Boolean).join(" ");

  return [
    `<asset-clip ${attrs}>`,
    noteText ? `  <note>${xmlEscape(noteText)}</note>` : "",
    `  <adjust-conform type="fit"/>`,
    `</asset-clip>`,
  ].filter(Boolean).join("\n");
}

function buildAuditionXml({ lane, offsetAttr, childrenXml }) {
  return [
    `<audition lane="${lane}" offset="${xmlEscape(offsetAttr)}">`,
    childrenXml.map((child) => child.split("\n").map((line) => `  ${line}`).join("\n")).join("\n"),
    `</audition>`,
  ].join("\n");
}

function insertIntoResources(xml, assetBlocks) {
  return xml.replace(/<\/resources>/, `${assetBlocks.join("\n")}\n</resources>`);
}

function insertIntoEvent(xml, eventInsertXml) {
  const eventMatch = xml.match(/<event\b[^>]*>/);
  if (!eventMatch) return xml;
  const eventStart = eventMatch.index;
  const eventOpenEnd = eventStart + eventMatch[0].length;
  const eventCloseIndex = xml.indexOf("</event>", eventOpenEnd);
  if (eventCloseIndex === -1) return xml;
  const eventBody = xml.slice(eventOpenEnd, eventCloseIndex);
  const projectIndex = eventBody.search(/<project\b/);
  const insertAt = projectIndex >= 0 ? eventOpenEnd + projectIndex : eventCloseIndex;
  return `${xml.slice(0, insertAt)}\n${eventInsertXml}\n${xml.slice(insertAt)}`;
}

function ensureEventContainer(xml, eventName) {
  if (/<event\b[^>]*>/.test(xml)) return xml;
  const projectMatch = xml.match(/([ \t]*)<project\b[\s\S]*?<\/project>/);
  if (!projectMatch || projectMatch.index == null) {
    throw new Error("Could not create the VFX Deliveries Event because no project was found.");
  }
  const indent = projectMatch[1];
  const eventXml = [
    `${indent}<event name="${xmlEscape(eventName)}">`,
    projectMatch[0],
    `${indent}</event>`,
  ].join("\n");
  return `${xml.slice(0, projectMatch.index)}${eventXml}${xml.slice(projectMatch.index + projectMatch[0].length)}`;
}

function insertConnectedClipsIntoParents(xml, placements) {
  const ordered = [...placements]
    .filter((item) => item?.insertBefore != null && item?.clipXml)
    .sort((a, b) => b.insertBefore - a.insertBefore);

  let out = xml;
  for (const placement of ordered) {
    out = `${out.slice(0, placement.insertBefore)}${placement.clipXml}\n${out.slice(placement.insertBefore)}`;
  }
  return out;
}

function adjustPlacementsForRemovedRanges(placements, removedRanges) {
  const normalizedRanges = [...removedRanges]
    .filter((range) => Number.isFinite(range?.start) && Number.isFinite(range?.end) && range.end > range.start)
    .sort((a, b) => a.start - b.start);

  return placements.map((placement) => {
    let shift = 0;
    for (const range of normalizedRanges) {
      if (range.end <= placement.insertBefore) {
        shift += range.end - range.start;
      }
    }
    return {
      ...placement,
      insertBefore: placement.insertBefore - shift,
    };
  });
}

function applyProjectPrefix(xml, prefix) {
  if (!prefix) return xml;
  return xml.replace(/(<project\b[^>]*\bname=")([^"]+)(")/, (_m, a, name, b) => {
    if (name.startsWith(prefix)) return `${a}${name}${b}`;
    return `${a}${xmlEscape(`${prefix}${name}`)}${b}`;
  });
}

function applyVersionedProjectName(xml, prefix, existingProjectNames) {
  if (!prefix) return xml;
  const names = [...(existingProjectNames || [])];
  return xml.replace(/(<project\b[^>]*\bname=")([^"]+)(")/, (_m, a, rawName, b) => {
    const name = trim(rawName);
    if (name) {
      names.push(name);
    }
    const escapedPrefix = prefix.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const prefixedMatch = name.match(new RegExp(`^${escapedPrefix}(?: v(\\d+))? - (.+)$`));
    const baseName = prefixedMatch ? prefixedMatch[2] : name;
    const baseEscaped = baseName.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const pattern = new RegExp(`^${escapedPrefix}(?: v(\\d+))? - ${baseEscaped}$`);
    let maxVersion = 0;
    for (const existingName of names) {
      const match = trim(existingName).match(pattern);
      if (match) {
        const version = match[1] ? Number(match[1]) || 0 : 1
        maxVersion = Math.max(maxVersion, version);
      }
    }
    const nextVersion = Math.max(1, maxVersion + 1);
    return `${a}${xmlEscape(`${prefix} v${nextVersion} - ${baseName}`)}${b}`;
  });
}

function applyTargetEventName(xml, eventName) {
  const name = trim(eventName);
  if (!name) return xml;
  return xml.replace(/(<event\b[^>]*\bname=")([^"]+)(")/, (_m, a, _oldName, b) => `${a}${xmlEscape(name)}${b}`);
}

function applyFreshProjectUID(xml) {
  const newUID = crypto.randomUUID().toUpperCase();
  return xml.replace(/(<project\b[^>]*\buid=")([^"]+)(")/, (_m, a, _oldUID, b) => `${a}${newUID}${b}`);
}

function findAnchorInsertOffset(xml, parentNode) {
  if (!parentNode?.openEnd || !parentNode?.closeStart) return null;
  const bodyStart = parentNode.openEnd;
  const bodyEnd = parentNode.closeStart;
  const body = xml.slice(bodyStart, bodyEnd);
  const orderSensitiveTags = new Set([
    "marker",
    "chapter-marker",
    "rating",
    "keyword",
    "analysis-marker",
    "sync-source",
    "audio-channel-source",
    "filter-video",
    "filter-audio",
    "metadata",
  ]);

  const tagRegex = /<(\/?)([\w:_-]+)(.*?)(\/?)>/gs;
  let depth = 0;
  let match;
  while ((match = tagRegex.exec(body))) {
    const [, closing, tagName, _attrStr, selfClose] = match;
    const isClosing = closing === "/";
    const isSelfClosing = selfClose === "/";

    if (!isClosing) {
      if (depth === 0 && orderSensitiveTags.has(tagName)) {
        return bodyStart + match.index;
      }
      if (!isSelfClosing) {
        depth += 1;
      }
    } else if (depth > 0) {
      depth -= 1;
    }
  }

  return bodyEnd;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const xml = await fs.readFile(args.sourceXml, "utf8");
  const config = parseKeyValueTSV(await fs.readFile(args.config, "utf8"));

  if (config.status && config.status !== "ok") {
    throw new Error(`VFX Deliveries config is not ready: ${config.status}`);
  }

  const deliveryFolder = trim(config.delivery_folder);
  if (!deliveryFolder) {
    throw new Error("Missing delivery folder in VFX Deliveries config.");
  }

  const titles = collectTitles(xml);
  const formats = parseFormats(xml);
  const sequence = parseSequenceFormat(xml);
  const sequenceFormat = formats.get(sequence.formatId) ?? { frameDuration: 1 / 24 };
  const frameDuration = sequenceFormat.frameDuration ?? (1 / 24);
  const handleFrames = Number(config.handle_frames || config.total_handle_frames || 0) || 0;
  const slateFrames = Number(config.slate_frames || 0) || 0;
  const placementMode = trim(config.placement_mode || "connected") || "connected";
  const lane = Number(config.lane || 10) || 10;
  const batchName = trim(config.delivery_batch_name || path.basename(deliveryFolder));
  const existingProjectNames = splitUS(config.existing_project_names);

  const candidateMap = await buildDeliveryCandidates(deliveryFolder);
  const existingVFXNodes = collectExistingVFXNodes(xml);

  const report = {
    placementModeRequested: placementMode,
    placementModeApplied: "connected",
    targetEventName: trim(config.target_event_name || "VFX Deliveries"),
    matched: [],
    unmatchedTitles: [],
    unmatchedFiles: [],
    tooShort: [],
    warnings: [],
  };

  report.placementModeApplied = placementMode;

  const assetBlocks = [];
  const eventBrowserItems = [];
  const clipPlacements = [];
  const removalRanges = [];
  let nextId = nextResourceId(xml);
  const matchedFiles = new Set();
  const matchedShotCodes = new Set(titles.map((title) => extractShotCode(title.vfxNumber)).filter(Boolean));

  for (const title of titles) {
    const titleShotCode = extractShotCode(title.vfxNumber);
    const candidates = candidateMap.get(titleShotCode) || [];
    if (candidates.length === 0) {
      report.unmatchedTitles.push(title.vfxNumber);
      continue;
    }

    const candidate = candidates[0];
    matchedFiles.add(candidate.filePath);
    const sourceDuration = candidate.durationSeconds;
    if (!(sourceDuration > 0)) {
      report.tooShort.push({ vfxNumber: title.vfxNumber, reason: "Could not determine media duration.", fileName: candidate.fileName });
      continue;
    }

    const assetBaselineStart = frameDuration;
    const headHandleFrames = Math.max(0, Math.floor(handleFrames));
    const tailHandleFrames = headHandleFrames;
    const trimStartSeconds = (slateFrames + headHandleFrames) * frameDuration;
    const trimEndSeconds = tailHandleFrames * frameDuration;
    const usableDuration = sourceDuration - trimStartSeconds - trimEndSeconds;

    if (usableDuration + 0.00001 < title.duration) {
      report.tooShort.push({
        vfxNumber: title.vfxNumber,
        fileName: candidate.fileName,
        requiredSeconds: title.duration,
        usableSeconds: usableDuration,
      });
      continue;
    }

    const assetId = `r${nextId++}`;
    const clipName = candidate.fileName;
    const fileURL = pathToFileURL(candidate.filePath).href;
    assetBlocks.push(
      `  <asset id="${assetId}" name="${xmlEscape(path.basename(candidate.fileName, path.extname(candidate.fileName)))}" start="0s" duration="${formatSeconds(sourceDuration)}" hasVideo="1" format="${xmlEscape(sequence.formatId)}" videoSources="1">`,
      `    <media-rep kind="original-media" src="${xmlEscape(fileURL)}"/>`,
      `  </asset>`
    );
    eventBrowserItems.push([
      `  <asset-clip ref="${assetId}" name="${xmlEscape(clipName)}" start="${formatSeconds(assetBaselineStart + trimStartSeconds)}" duration="${formatSeconds(sourceDuration)}" format="${xmlEscape(sequence.formatId)}" tcFormat="${xmlEscape(sequence.tcFormat)}" videoRole="VFX">`,
      `    <note>${xmlEscape(buildClipNote({ batchName, placementMode, fileName: candidate.fileName }))}</note>`,
      `    <keyword start="0s" duration="${formatSeconds(sourceDuration)}" value="VFX Deliveries"/>`,
      `  </asset-clip>`,
    ].join("\n"));

    const parentNode = title.parentNode;
    const insertBefore = findAnchorInsertOffset(xml, parentNode);
    if (insertBefore == null) {
      report.warnings.push(`Could not find parent container for ${title.vfxNumber}; skipping placement.`);
      continue;
    }

    const existingForTitle = existingVFXNodes.filter((node) =>
      node.parentKey === title.parentKey &&
      (
        (node.shotCode && titleShotCode && node.shotCode === titleShotCode) ||
        intervalsOverlap(node.timelineStart, node.duration || title.duration, title.timelineStart, title.duration)
      )
    );
    const existingMaxLane = existingForTitle.reduce((max, node) => Math.max(max, node.lane || 0), 0);
    const targetLane = placementMode === "connected"
      ? Math.max(lane, existingMaxLane + (existingForTitle.length > 0 ? 1 : 0))
      : Math.max(lane, existingForTitle[0]?.lane || 0);

    const noteText = buildClipNote({
      batchName,
      placementMode,
      fileName: candidate.fileName,
    });
    const newClipXml = buildConnectedAssetClipXml({
      assetId,
      clipName,
      startSeconds: assetBaselineStart + trimStartSeconds,
      durationAttr: title.durationAttr,
      sequence,
      lane: targetLane,
      offsetAttr: title.offsetAttr,
      noteText,
      includeOffset: true,
      includeLane: true,
    });

    let clipXml = newClipXml;

    if (placementMode === "replace") {
      if (existingForTitle.length > 0) {
        for (const node of existingForTitle) {
          removalRanges.push({ start: node.openStart, end: node.closeEnd });
        }
      } else {
        report.warnings.push(`No previous VFX version found for ${title.vfxNumber}; fell back to connected clip.`);
      }
    } else if (placementMode === "audition") {
      if (existingForTitle.length > 0) {
        const prior = existingForTitle[0];
        if (prior.tag === "audition") {
          const auditionChildXml = buildConnectedAssetClipXml({
            assetId,
            clipName,
            startSeconds: assetBaselineStart + trimStartSeconds,
            durationAttr: title.durationAttr,
            sequence,
            lane: 0,
            offsetAttr: title.offsetAttr,
            noteText,
            includeOffset: false,
            includeLane: false,
          });
          clipPlacements.push({
            insertBefore: prior.openEnd,
            clipXml: `${auditionChildXml}\n`,
          });
          report.matched.push({
            vfxNumber: title.vfxNumber,
            fileName: candidate.fileName,
            offsetSeconds: title.timelineStart,
            durationSeconds: title.duration,
            trimStartSeconds,
            trimEndSeconds,
          });
          continue;
        }

        removalRanges.push({ start: prior.openStart, end: prior.closeEnd });
        const priorChild = stripAttr(stripAttr(prior.body, "lane"), "offset");
        const newChild = buildConnectedAssetClipXml({
          assetId,
          clipName,
          startSeconds: assetBaselineStart + trimStartSeconds,
          durationAttr: title.durationAttr,
          sequence,
          lane: 0,
          offsetAttr: title.offsetAttr,
          noteText,
          includeOffset: false,
          includeLane: false,
        });
        clipXml = buildAuditionXml({
          lane: Math.max(lane, prior.lane || 0),
          offsetAttr: title.offsetAttr,
          childrenXml: [newChild, priorChild],
        });
      } else {
        report.warnings.push(`No previous VFX version found for ${title.vfxNumber}; audition fell back to connected clip.`);
      }
    }

    clipPlacements.push({
      insertBefore,
      clipXml: clipXml
        .split("\n")
        .map((line) => `                            ${line}`)
        .join("\n"),
    });

    report.matched.push({
      vfxNumber: title.vfxNumber,
      fileName: candidate.fileName,
      offsetSeconds: title.timelineStart,
      durationSeconds: title.duration,
      trimStartSeconds,
      trimEndSeconds,
    });
  }

  for (const [shotCode, items] of candidateMap.entries()) {
    if (!matchedShotCodes.has(shotCode)) {
      report.unmatchedFiles.push(...items.map((item) => item.fileName));
    }
  }

  let patched = xml;
  let finalPlacements = clipPlacements;
  if (placementMode === "replace") {
    finalPlacements = adjustPlacementsForRemovedRanges(finalPlacements, removalRanges);
    patched = removeRanges(patched, removalRanges);
  } else if (placementMode === "connected") {
    // Keep previous VFX versions in place for side-by-side version stacking.
  } else if (placementMode === "audition") {
    finalPlacements = adjustPlacementsForRemovedRanges(finalPlacements, removalRanges);
    patched = removeRanges(patched, removalRanges);
  }
  if (assetBlocks.length > 0) {
    patched = insertConnectedClipsIntoParents(patched, finalPlacements);
    patched = insertIntoResources(patched, assetBlocks);
  }

  if (eventBrowserItems.length > 0) {
    patched = ensureEventContainer(patched, report.targetEventName);
    patched = insertIntoEvent(patched, eventBrowserItems.join("\n"));
  }

  // All placement offsets refer to the original XML. Rename variable-length
  // attributes only after every offset-based structural edit is complete.
  patched = applyTargetEventName(patched, report.targetEventName);
  patched = applyVersionedProjectName(patched, "📦 VFX Deliveries", existingProjectNames);
  patched = applyFreshProjectUID(patched);

  await fs.writeFile(args.outputXml, patched, "utf8");
  await validateGeneratedFCPXML(args.outputXml, patched);

  const reportText = [
    `VFX Deliveries`,
    `Target event: ${report.targetEventName}`,
    `Placement mode requested: ${report.placementModeRequested}`,
    `Placement mode applied: ${report.placementModeApplied}`,
    `Matched shots: ${report.matched.length}`,
    `Unmatched timeline titles: ${report.unmatchedTitles.length}`,
    `Too short: ${report.tooShort.length}`,
    `Unmatched delivery files: ${report.unmatchedFiles.length}`,
    report.warnings.length ? `Warnings: ${report.warnings.join(" | ")}` : "",
  ].filter(Boolean).join("\n");
  await fs.writeFile(args.report, reportText + "\n", "utf8");

  console.log(`matched=${report.matched.length} unmatched_titles=${report.unmatchedTitles.length} too_short=${report.tooShort.length} output=${args.outputXml}`);
}

main().catch((error) => {
  console.error(error?.stack || String(error));
  process.exit(1);
});
