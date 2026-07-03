#!/usr/bin/env node

import fs from "node:fs/promises";
import { execFile as execFileCallback } from "node:child_process";
import { promisify } from "node:util";

const TURNOVER_EVENT_NAME = "📦 Turnover";
const execFile = promisify(execFileCallback);

function parseArgs(argv) {
  const args = {};
  for (let index = 0; index < argv.length; index += 2) {
    const key = argv[index]?.replace(/^--/, "");
    const value = argv[index + 1];
    if (key && value) args[key] = value;
  }
  if (!args["input-xml"] || !args["output-xml"]) {
    throw new Error("Usage: prepare_turnover_import_fcpxml.mjs --input-xml INPUT --output-xml OUTPUT");
  }
  return args;
}

function escapeAttribute(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll('"', "&quot;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;");
}

function prepareImportEnvelope(xml) {
  if (/<event\b[^>]*>/.test(xml)) {
    // Full FCPXML exports already carry the original Event identity. Preserving
    // its name and UID lets Final Cut route the result back to that Event.
    return xml;
  }

  const projectMatch = xml.match(/([ \t]*)<project\b[\s\S]*?<\/project>/);
  if (!projectMatch || projectMatch.index == null) {
    throw new Error("Could not find a project to place in the Turnover event.");
  }

  const indent = projectMatch[1];
  const eventXml = [
    `${indent}<event name="${escapeAttribute(TURNOVER_EVENT_NAME)}">`,
    projectMatch[0],
    `${indent}</event>`,
  ].join("\n");

  return `${xml.slice(0, projectMatch.index)}${eventXml}${xml.slice(projectMatch.index + projectMatch[0].length)}`;
}

async function validateFCPXML(xmlPath, xml) {
  try {
    await execFile("xmllint", ["--noout", xmlPath]);
  } catch (error) {
    throw new Error(`Prepared FCPXML is not well formed: ${String(error?.stderr || error?.message).trim()}`);
  }

  const version = /<fcpxml\s+version="([^"]+)"/.exec(xml)?.[1];
  if (!version) return;
  const dtdPath = `/Applications/Final Cut Pro.app/Contents/Frameworks/Interchange.framework/Versions/A/Resources/FCPXMLv${version.replaceAll(".", "_")}.dtd`;
  try {
    await fs.access(dtdPath);
  } catch {
    return;
  }

  const validationPath = `${xmlPath}.turnover-validate.fcpxml`;
  const dtdURL = `file://${dtdPath.replaceAll(" ", "%20")}`;
  const doctype = `<!DOCTYPE fcpxml SYSTEM "${dtdURL}">`;
  const validationXML = /<!DOCTYPE\s+fcpxml(?:\s+SYSTEM\s+"[^"]*")?\s*>/.test(xml)
    ? xml.replace(/<!DOCTYPE\s+fcpxml(?:\s+SYSTEM\s+"[^"]*")?\s*>/, doctype)
    : xml.replace(/<fcpxml\b/, `${doctype}\n<fcpxml`);
  await fs.writeFile(validationPath, validationXML, "utf8");
  try {
    await execFile("xmllint", ["--noout", "--loaddtd", "--valid", validationPath]);
  } catch (error) {
    throw new Error(`Prepared FCPXML failed DTD ${version}: ${String(error?.stderr || error?.message).trim()}`);
  } finally {
    await fs.rm(validationPath, { force: true });
  }
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const xml = await fs.readFile(args["input-xml"], "utf8");
  const prepared = prepareImportEnvelope(xml);
  await fs.writeFile(args["output-xml"], prepared, "utf8");
  await validateFCPXML(args["output-xml"], prepared);
  console.log(`event=${TURNOVER_EVENT_NAME}`);
}

main().catch((error) => {
  console.error(error?.stack || String(error));
  process.exit(1);
});
