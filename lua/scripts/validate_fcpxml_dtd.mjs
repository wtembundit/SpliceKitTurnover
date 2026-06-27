import fs from "node:fs/promises";
import { existsSync } from "node:fs";
import path from "node:path";
import os from "node:os";
import crypto from "node:crypto";
import { spawnSync } from "node:child_process";

function usage() {
  console.log(`Usage:
  node lua/scripts/validate_fcpxml_dtd.mjs \\
    --xml <path-to-fcpxml-or-fcpxmld> \\
    [--report <path>] \\
    [--dtd-dir <path>]`);
}

function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--xml") args.xml = path.resolve(argv[++i]);
    else if (arg === "--report") args.report = path.resolve(argv[++i]);
    else if (arg === "--dtd-dir") args.dtdDir = path.resolve(argv[++i]);
    else if (arg === "--help" || arg === "-h") {
      usage();
      process.exit(0);
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }
  if (!args.xml) {
    usage();
    throw new Error("Missing --xml");
  }
  return args;
}

function trim(value) {
  return String(value ?? "").trim();
}

async function readFCPXML(inputPath) {
  const stat = await fs.stat(inputPath);
  if (!stat.isDirectory()) return fs.readFile(inputPath, "utf8");

  for (const candidate of ["Info.fcpxml", "info.fcpxml"]) {
    const fullPath = path.join(inputPath, candidate);
    if (existsSync(fullPath)) return fs.readFile(fullPath, "utf8");
  }
  throw new Error(`Directory does not contain Info.fcpxml: ${inputPath}`);
}

function fcpxmlVersion(xml) {
  return trim(xml.match(/<fcpxml\s+version="([^"]+)"/)?.[1] ?? "");
}

function dtdFilename(version) {
  const normalized = trim(version).replace(/\./g, "_");
  return `FCPXMLv${normalized}.dtd`;
}

function dtdSearchDirs(extraDir) {
  return [
    extraDir,
    "/Applications/Final Cut Pro.app/Contents/Frameworks/Interchange.framework/Versions/A/Resources",
    "/Applications/EDL-X.app/Contents/Resources",
  ].filter(Boolean);
}

async function findDTD(version, extraDir) {
  const strictName = dtdFilename(version);
  const edlxName = `fcpxml ${version}.dtd`;
  for (const dir of dtdSearchDirs(extraDir)) {
    for (const name of [strictName, edlxName]) {
      const candidate = path.join(dir, name);
      if (existsSync(candidate)) return candidate;
    }
  }
  return "";
}

function dtdSystemIdentifier(dtdPath) {
  return `file://${dtdPath.replace(/ /g, "%20")}`;
}

function xmlWithDTD(xml, dtdPath) {
  const doctypeRegex = /<!DOCTYPE\s+fcpxml(?:\s+SYSTEM\s+"[^"]*")?\s*>/;
  const doctype = `<!DOCTYPE fcpxml SYSTEM "${dtdSystemIdentifier(dtdPath)}">`;
  if (doctypeRegex.test(xml)) return xml.replace(doctypeRegex, doctype);
  return xml.replace(/<fcpxml\b/, `${doctype}\n<fcpxml`);
}

async function validate(xml, dtdPath) {
  const tempXmlPath = path.join(os.tmpdir(), `turnover_fcpxml_validate_${crypto.randomUUID()}.fcpxml`);
  await fs.writeFile(tempXmlPath, xmlWithDTD(xml, dtdPath));
  try {
    const result = spawnSync("xmllint", ["--noout", "--loaddtd", "--valid", tempXmlPath], {
      encoding: "utf8",
      maxBuffer: 1024 * 1024 * 20,
    });
    return {
      ok: result.status === 0 && !result.error,
      status: result.status,
      output: trim(result.stderr || result.stdout || result.error?.message || ""),
    };
  } finally {
    await fs.unlink(tempXmlPath).catch(() => {});
  }
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const xml = await readFCPXML(args.xml);
  const version = fcpxmlVersion(xml) || "1.12";
  const dtdPath = await findDTD(version, args.dtdDir);
  const lines = [];

  lines.push("FCPXML DTD Validation Report");
  lines.push(`input: ${args.xml}`);
  lines.push(`version: ${version}`);

  if (!dtdPath) {
    lines.push("status: skipped");
    lines.push(`message: DTD not found for FCPXML version ${version}`);
    const report = `${lines.join("\n")}\n`;
    if (args.report) await fs.writeFile(args.report, report);
    console.log(report);
    process.exitCode = 2;
    return;
  }

  lines.push(`dtd: ${dtdPath}`);
  const result = await validate(xml, dtdPath);
  lines.push(`status: ${result.ok ? "passed" : "failed"}`);
  if (result.output) {
    lines.push("");
    lines.push(result.output);
  }

  const report = `${lines.join("\n")}\n`;
  if (args.report) await fs.writeFile(args.report, report);
  console.log(report);
  if (!result.ok) process.exitCode = 1;
}

main().catch((error) => {
  console.error(error?.stack || String(error));
  process.exit(1);
});

