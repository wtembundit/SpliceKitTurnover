#!/usr/bin/env node

import fs from "node:fs/promises";
import path from "node:path";
import {
  collectPullRows,
  parseAssets,
  parseFormats,
  parseSequenceFrameDuration,
  secondsToTC,
} from "./build_vfx_pull_edl.mjs";

function parseArgs(argv) {
  const args = {};
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--source-xml") args.sourceXml = path.resolve(argv[++index]);
    else if (arg === "--output-manifest") args.outputManifest = path.resolve(argv[++index]);
    else if (arg === "--report") args.report = path.resolve(argv[++index]);
    else throw new Error(`Unknown argument: ${arg}`);
  }
  if (!args.sourceXml || !args.outputManifest || !args.report) {
    throw new Error("Usage: build_vfx_shot_list_manifest.mjs --source-xml INPUT --output-manifest OUTPUT --report REPORT");
  }
  return args;
}

function trim(value) {
  return String(value ?? "").trim();
}

function parseFCPTime(value) {
  const fraction = /^([-\d.]+)\/([-\d.]+)s$/.exec(trim(value));
  if (fraction) return Number(fraction[1]) / Number(fraction[2]);
  const seconds = /^([-\d.]+)s$/.exec(trim(value));
  return seconds ? Number(seconds[1]) : 0;
}

function tsvEscape(value) {
  return String(value ?? "")
    .replaceAll("\\", "\\\\")
    .replaceAll("\t", "\\t")
    .replaceAll("\r", "\\r")
    .replaceAll("\n", "\\n");
}

function safeFilename(value) {
  return trim(value).replace(/[<>:"/\\|?*\u0000-\u001f]/g, "_").replace(/\s+/g, "_") || "VFX";
}

function groupRowsByTitle(rows) {
  const groups = new Map();
  for (const row of rows) {
    const key = `${trim(row.vfxNumber)}|${Number(row.titleStartSeconds || 0).toFixed(6)}`;
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(row);
  }
  return [...groups.values()].sort((a, b) =>
    Number(a[0]?.titleStartSeconds || 0) - Number(b[0]?.titleStartSeconds || 0));
}

function buildManifestRows(groups, timelineFrameDuration, timelineStartSeconds, projectName) {
  const nameTotals = new Map();
  for (const group of groups) {
    const name = safeFilename(group[0]?.vfxNumber);
    nameTotals.set(name, (nameTotals.get(name) || 0) + 1);
  }
  const nameOccurrences = new Map();

  return groups.map((group, index) => {
    const first = group[0];
    const uniqueSources = [];
    const sourcesByName = new Map();
    for (const layer of group) {
      const filename = trim(layer.sourceFilename);
      const key = filename.toLowerCase();
      if (!key) continue;
      const existing = sourcesByName.get(key);
      if (!existing) {
        const source = { ...layer, sourceFilename: filename };
        sourcesByName.set(key, source);
        uniqueSources.push(source);
      } else {
        existing.sourceInSeconds = Math.min(
          Number(existing.sourceInSeconds || 0),
          Number(layer.sourceInSeconds || 0),
        );
        existing.sourceOutSeconds = Math.max(
          Number(existing.sourceOutSeconds || 0),
          Number(layer.sourceOutSeconds || 0),
        );
      }
    }
    const baseName = safeFilename(first.vfxNumber);
    const occurrence = (nameOccurrences.get(baseName) || 0) + 1;
    nameOccurrences.set(baseName, occurrence);
    const imageBase = (nameTotals.get(baseName) || 0) > 1
      ? `${baseName}_${String(occurrence).padStart(2, "0")}`
      : baseName;
    const titleDuration = Number(first.titleDurationSeconds || 0);
    const durationFrames = Math.max(1, Math.round(titleDuration / timelineFrameDuration));

    return {
      index: index + 1,
      vfxNumber: trim(first.vfxNumber),
      note: trim(first.note),
      timelineSeconds: Number(first.titleStartSeconds || 0),
      timelineTCIn: secondsToTC(first.titleStartSeconds, timelineFrameDuration),
      durationFrames,
      sourceFilename: uniqueSources.map((row) => row.sourceFilename).join("\n"),
      sourceTCIn: uniqueSources.map((row) => secondsToTC(row.sourceInSeconds, row.sourceFrameDuration, row.sourceTcFormat)).join("\n"),
      sourceTCOut: uniqueSources.map((row) => secondsToTC(row.sourceOutSeconds, row.sourceFrameDuration, row.sourceTcFormat)).join("\n"),
      customMetadata: "",
      remark: "",
      projectName,
      suggestedThumbName: `${imageBase}.jpg`,
      captureSeconds: Number(first.markerAbsSeconds || 0),
      captureTC: secondsToTC(first.markerAbsSeconds, timelineFrameDuration),
      // Request the middle of the timeline frame. Long-GOP reference movies can
      // otherwise resolve an exact boundary to the preceding decoded sample.
      movieSeconds: Math.max(
        Number(first.markerAbsSeconds || 0) - timelineStartSeconds + (timelineFrameDuration / 2),
        0,
      ),
    };
  });
}

function serializeManifest(rows) {
  const headers = [
    "index", "vfx_number", "note", "timeline_seconds", "timeline_tc_in",
    "duration_frames", "source_filename", "source_tc_in", "source_tc_out",
    "custom_metadata", "remark", "project_name", "suggested_thumb_name", "capture_seconds", "capture_tc", "movie_seconds",
  ];
  return [
    headers.join("\t"),
    ...rows.map((row) => [
      row.index, row.vfxNumber, row.note, row.timelineSeconds.toFixed(6), row.timelineTCIn,
      row.durationFrames, row.sourceFilename, row.sourceTCIn, row.sourceTCOut,
      row.customMetadata, row.remark, row.projectName, row.suggestedThumbName,
      row.captureSeconds.toFixed(6), row.captureTC, row.movieSeconds.toFixed(6),
    ].map(tsvEscape).join("\t")),
  ].join("\n") + "\n";
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const xml = await fs.readFile(args.sourceXml, "utf8");
  const projectName = trim(/<project\s+[^>]*name="([^"]+)"/s.exec(xml)?.[1]);
  const formats = parseFormats(xml);
  const assets = parseAssets(xml, formats);
  const timelineFrameDuration = parseSequenceFrameDuration(xml, formats);
  const timelineStartSeconds = parseFCPTime(/<sequence\b[^>]*\btcStart="([^"]+)"/s.exec(xml)?.[1]);
  const layerRows = collectPullRows(xml, assets, timelineFrameDuration, 0, { markerScoped: true });
  const groups = groupRowsByTitle(layerRows);
  if (groups.length === 0) {
    throw new Error("No user marker anchors were found under VFX naming titles. Run Auto Marker or add markers before creating a VFX Shot List.");
  }
  const rows = buildManifestRows(groups, timelineFrameDuration, timelineStartSeconds, projectName);
  await fs.mkdir(path.dirname(args.outputManifest), { recursive: true });
  await fs.mkdir(path.dirname(args.report), { recursive: true });
  await fs.writeFile(args.outputManifest, serializeManifest(rows));
  await fs.writeFile(args.report, [
    `source_xml\t${args.sourceXml}`,
    `project\t${projectName}`,
    `marker_anchored_shots\t${rows.length}`,
    `source_layers\t${layerRows.length}`,
    `timeline_start_seconds\t${timelineStartSeconds}`,
    `manifest\t${args.outputManifest}`,
  ].join("\n") + "\n");
  console.log(JSON.stringify({ status: "ok", shots: rows.length, layers: layerRows.length, manifest_path: args.outputManifest, report_path: args.report }));
}

main().catch((error) => {
  console.error(error?.stack || String(error));
  process.exit(1);
});
