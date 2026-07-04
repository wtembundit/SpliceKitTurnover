#!/usr/bin/env node

import fs from "node:fs/promises";
import path from "node:path";
import {
  collectGlobalSourceSegments,
  collectGlobalVfxTitles,
  parseAssets,
  parseFormats,
  parseSequenceFrameDuration,
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
    throw new Error("Usage: build_data_burn_in_manifest.mjs --source-xml INPUT --output-manifest OUTPUT --report REPORT");
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

function contextTimelineStart(parent, attrs) {
  const parentTimeline = Number(parent?.timelineStart) || 0;
  const offset = attrs.offset == null ? null : parseTime(attrs.offset);
  if (offset == null) return parentTimeline;
  return parentTimeline + offset - (Number(parent?.start) || 0);
}

function collectAudioRoleIntervals(xml) {
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
    if (selfClosing !== "/") stack.push(node);
  }

  const seen = new Set();
  return intervals.filter((item) => {
    const key = `${item.role}|${item.timelineStartSeconds.toFixed(6)}|${item.timelineEndSeconds.toFixed(6)}`;
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  }).sort((a, b) => a.timelineStartSeconds - b.timelineStartSeconds || a.role.localeCompare(b.role));
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

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const xml = await fs.readFile(args.sourceXml, "utf8");
  const formats = parseFormats(xml);
  const assets = parseAssets(xml, formats);
  const frameDuration = parseSequenceFrameDuration(xml, formats);
  const sequenceAttrs = parseAttrs(xml.match(/<sequence\b([^>]*)>/s)?.[1] || "");
  const sequenceFormat = formats[trim(sequenceAttrs.format)] || {};
  const projectName = trim(xml.match(/<project\b[^>]*name="([^"]+)"/s)?.[1]);
  const eventName = trim(xml.match(/<event\b[^>]*name="([^"]+)"/s)?.[1]);
  const videoSegments = collectGlobalSourceSegments(xml, assets).map((segment) => ({
    timelineStartSeconds: Number(segment.timelineStart) || 0,
    timelineEndSeconds: Number(segment.timelineEnd) || 0,
    sourceFilename: trim(segment.sourceFilename),
    sourceInSeconds: Number(segment.sourceInSeconds) || 0,
    sourceOutSeconds: Number(segment.sourceOutSeconds) || 0,
    sourceFrameDuration: Number(segment.sourceFrameDuration) || frameDuration,
    sourceTcFormat: trim(segment.sourceTcFormat),
  }));
  const vfxTitles = collectGlobalVfxTitles(xml).map((title) => ({
    timelineStartSeconds: Number(title.timelineStart) || 0,
    timelineEndSeconds: Number(title.timelineEnd) || 0,
    vfxNumber: trim(title.vfxNumber),
    note: trim(title.note),
  }));
  const audioRoles = collectAudioRoleIntervals(xml);
  const manifest = {
    schemaVersion: 1,
    project: projectName,
    event: eventName,
    timeline: {
      startSeconds: parseTime(sequenceAttrs.tcStart),
      durationSeconds: parseTime(sequenceAttrs.duration),
      frameDurationSeconds: frameDuration,
      tcFormat: trim(sequenceAttrs.tcFormat || "NDF"),
      width: Number(sequenceFormat.width) || 0,
      height: Number(sequenceFormat.height) || 0,
      colorSpace: trim(sequenceFormat.colorSpace),
      formatName: trim(sequenceFormat.name),
    },
    supportedTokens: ["project", "event", "timeline_tc", "timeline_frame", "source_tc", "source_file", "vfx_number", "vfx_note", "audio_role", "custom_text"],
    videoSegments,
    vfxTitles,
    audioRoles,
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
    `vfx_titles\t${vfxTitles.length}`,
    `audio_role_intervals\t${audioRoles.length}`,
    `manifest\t${args.outputManifest}`,
  ].join("\n") + "\n");
  console.log(JSON.stringify({ status: "ok", video_segments: videoSegments.length, vfx_titles: vfxTitles.length, audio_roles: audioRoles.length, manifest_path: args.outputManifest, report_path: args.report }));
}

main().catch((error) => {
  console.error(error.stack || String(error));
  process.exit(1);
});
