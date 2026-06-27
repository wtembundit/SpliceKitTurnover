import fs from "node:fs/promises";
import { execFile as execFileCallback } from "node:child_process";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import { SpreadsheetFile, Workbook } from "@oai/artifact-tool";

const execFile = promisify(execFileCallback);
const THUMBNAIL_ROW_HEIGHT_PX = 135;
const THUMBNAIL_IMAGE_WIDTH_PX = 300; // 3.12 in at 96 dpi.
const THUMBNAIL_IMAGE_HEIGHT_PX = 169; // 1.76 in at 96 dpi.

function printUsage() {
  console.log(`Usage:
  node lua/scripts/generate_vfx_shot_list_excel.mjs [options]

Options:
  --manifest <path>     Manifest TSV path
  --captures <path>     Full-size capture directory
  --thumbs <path>       Thumbnail directory
  --output <path>       Output .xlsx path
  --title <text>        Workbook title override
`);
}

function parseArgs(argv) {
  const stateDir = path.join(
    os.homedir(),
    "Library",
    "Application Support",
    "SpliceKit",
    "VFXShotList",
  );
  const args = {
    manifest: path.join(stateDir, "VFX_Shot_List_Manifest.tsv"),
    captures: path.join(os.homedir(), "Desktop", "VFX_Shot_List_Captures_16x9"),
    thumbs: path.join(os.homedir(), "Desktop", "VFX_Shot_List_Captures_Thumb"),
    output: "",
    title: "VFX Shot List",
    withPreview: false,
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--manifest") {
      args.manifest = path.resolve(argv[++i]);
    } else if (arg === "--captures") {
      args.captures = path.resolve(argv[++i]);
    } else if (arg === "--thumbs") {
      args.thumbs = path.resolve(argv[++i]);
    } else if (arg === "--output") {
      args.output = path.resolve(argv[++i]);
    } else if (arg === "--title") {
      args.title = argv[++i];
    } else if (arg === "--with-preview") {
      args.withPreview = true;
    } else if (arg === "--help" || arg === "-h") {
      printUsage();
      process.exit(0);
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }

  return args;
}

function safeFilenamePart(value) {
  const cleaned = String(value || "")
    .replace(/[<>:"/\\|?*\u0000-\u001f]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
  return cleaned || "Untitled Project";
}

function splitTsvLine(line) {
  return line.replace(/\r$/, "").split("\t");
}

function unescapeTsvValue(value) {
  return String(value ?? "")
    .replace(/\\\\/g, "\u0000")
    .replace(/\\t/g, "\t")
    .replace(/\\r/g, "\r")
    .replace(/\\n/g, "\n")
    .replace(/\u0000/g, "\\");
}

function parseManifest(tsvText) {
  const lines = tsvText
    .split("\n")
    .map((line) => line.replace(/\r$/, ""))
    .filter((line) => line.length > 0);

  if (lines.length < 2) {
    throw new Error("Manifest TSV has no data rows.");
  }

  const headers = splitTsvLine(lines[0]);
  return lines.slice(1).map((line) => {
    const values = splitTsvLine(line);
    const record = {};
    headers.forEach((header, index) => {
      record[header] = unescapeTsvValue(values[index] ?? "");
    });
    if (!record.vfx_number && record.marker_name) {
      record.vfx_number = record.marker_name;
    }
    if (!record.note && record.marker_note) {
      record.note = record.marker_note;
    }
    if (!record.timeline_tc_in && record.timeline_tc_24fps_display) {
      record.timeline_tc_in = record.timeline_tc_24fps_display;
    }
    if (!record.duration_frames && record.duration_seconds) {
      record.duration_frames = String(Math.round(Number(record.duration_seconds) * 24));
    }
    if (!record.suggested_thumb_name && record.thumb_name) {
      record.suggested_thumb_name = record.thumb_name;
    }
    if (!record.source_tc_out && record.source_tc_end) {
      record.source_tc_out = record.source_tc_end;
    }
    if (!record.remark && record.remarks) {
      record.remark = record.remarks;
    }
    return record;
  });
}

async function pathExists(filePath) {
  try {
    await fs.access(filePath);
    return true;
  } catch {
    return false;
  }
}

async function toDataUrl(filePath) {
  const ext = path.extname(filePath).toLowerCase();
  let inputPath = filePath;
  let mimeType = "image/png";

  if (ext === ".jpg" || ext === ".jpeg") {
    const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "vfx-shot-list-thumb-"));
    inputPath = path.join(tempDir, `${path.basename(filePath, ext)}.png`);
    await execFile("sips", ["-s", "format", "png", filePath, "--out", inputPath]);
  } else if (ext !== ".png") {
    mimeType = "application/octet-stream";
  }

  const bytes = await fs.readFile(inputPath);
  return `data:${mimeType};base64,${bytes.toString("base64")}`;
}

function styleCellBlock(range, fill) {
  range.format = {
    fill,
    font: { name: "Aptos", size: 11, color: "#1F2937" },
    verticalAlignment: "center",
    horizontalAlignment: "left",
    wrapText: true,
    borders: { preset: "inside", style: "thin", color: "#D1D5DB" },
  };
  range.format.borders = { preset: "outside", style: "thin", color: "#D1D5DB" };
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const manifestText = await fs.readFile(args.manifest, "utf8");
  const rows = parseManifest(manifestText).sort(
    (a, b) => Number(a.index || 0) - Number(b.index || 0),
  );

  const workbook = Workbook.create();
  const sheet = workbook.worksheets.add("Shot List");
  sheet.freezePanes.freezeRows(2);

  const projectName = rows[0]?.project_name || "";
  const resolvedOutput = args.output || path.join(
    os.homedir(),
    "Desktop",
    `${args.title}${projectName ? ` - ${safeFilenamePart(projectName)}` : ""}.xlsx`,
  );
  const titleText = projectName
    ? `${args.title} - ${projectName}`
    : args.title;

  sheet.getRange("A1:J1").merged = true;
  sheet.getRange("A1").values = [[titleText]];
  sheet.getRange("A1:J1").format = {
    fill: { type: "solid", color: "#0F172A" },
    font: { name: "Aptos Display", size: 16, bold: true, color: "#FFFFFF" },
    verticalAlignment: "center",
  };
  sheet.getRange("A1:J1").format.rowHeightPx = 30;

  const headers = [
    "Thumbnail",
    "VFX Number",
    "Note",
    "Timeline TC In",
    "Duration in Timeline (Frames)",
    "Source Filename",
    "Source TC In",
    "Source TC Out",
    "Metadata",
    "Remark",
  ];
  sheet.getRange("A2:J2").values = [headers];
  sheet.getRange("A2:J2").format = {
    fill: { type: "solid", color: "#DCEAF7" },
    font: { name: "Aptos", size: 11, bold: true, color: "#0F172A" },
    verticalAlignment: "center",
    horizontalAlignment: "center",
    wrapText: true,
    borders: { preset: "outside", style: "thin", color: "#94A3B8" },
  };
  sheet.getRange("A2:J2").format.borders = { preset: "inside", style: "thin", color: "#94A3B8" };
  sheet.getRange("A:A").format.columnWidthPx = 235;
  sheet.getRange("B:B").format.columnWidthPx = 170;
  sheet.getRange("C:C").format.columnWidthPx = 330;
  sheet.getRange("D:D").format.columnWidthPx = 140;
  sheet.getRange("E:E").format.columnWidthPx = 155;
  sheet.getRange("F:F").format.columnWidthPx = 390;
  sheet.getRange("G:G").format.columnWidthPx = 135;
  sheet.getRange("H:H").format.columnWidthPx = 135;
  sheet.getRange("I:I").format.columnWidthPx = 430;
  sheet.getRange("J:J").format.columnWidthPx = 260;

  const dataStartRow = 3;
  const matrix = rows.map((row) => [
    "",
    row.vfx_number || "",
    row.note || "",
    row.timeline_tc_in || "",
    row.duration_frames || "",
    row.source_filename || "",
    row.source_tc_in || "",
    row.source_tc_out || "",
    row.custom_metadata || "",
    row.remark || "",
  ]);

  if (matrix.length > 0) {
    const lastRow = dataStartRow + matrix.length - 1;
    const dataRange = sheet.getRange(`A${dataStartRow}:J${lastRow}`);
    dataRange.values = matrix;
    styleCellBlock(dataRange, "#FFFFFF");
    sheet.getRange(`A${dataStartRow}:A${lastRow}`).format.horizontalAlignment = "center";
    sheet.getRange(`B${dataStartRow}:B${lastRow}`).format.font = { bold: true, color: "#0F172A" };
    sheet.getRange(`D${dataStartRow}:E${lastRow}`).format.horizontalAlignment = "center";
    sheet.getRange(`D${dataStartRow}:E${lastRow}`).format.verticalAlignment = "center";
    sheet.getRange(`G${dataStartRow}:H${lastRow}`).format.horizontalAlignment = "center";
    sheet.getRange(`G${dataStartRow}:H${lastRow}`).format.verticalAlignment = "center";

    for (let i = 0; i < rows.length; i += 1) {
      const excelRow = dataStartRow + i;
      const excelRowRange = sheet.getRange(`A${excelRow}:J${excelRow}`);
      excelRowRange.format.rowHeightPx = THUMBNAIL_ROW_HEIGHT_PX;
      if (i % 2 === 1) {
        styleCellBlock(excelRowRange, "#F8FAFC");
      }

      const thumbName = rows[i].suggested_thumb_name || rows[i].thumb_name || "";
      const thumbPath = path.isAbsolute(thumbName)
        ? thumbName
        : path.join(args.thumbs, thumbName);
      const captureName = thumbName
        ? `${path.basename(thumbName, path.extname(thumbName))}.png`
        : "";
      const capturePath = captureName
        ? path.join(args.captures, captureName)
        : "";

      const imagePath = thumbName && (await pathExists(thumbPath))
        ? thumbPath
        : (capturePath && (await pathExists(capturePath)) ? capturePath : "");

      if (imagePath) {
        const dataUrl = await toDataUrl(imagePath);
        sheet.images.add({
          dataUrl,
          anchor: {
            from: { row: excelRow - 1, col: 0, rowOffsetPx: 6, colOffsetPx: 8 },
            extent: { widthPx: THUMBNAIL_IMAGE_WIDTH_PX, heightPx: THUMBNAIL_IMAGE_HEIGHT_PX },
          },
        });
      } else {
        sheet.getRange(`A${excelRow}`).values = [["Missing thumb"]];
        sheet.getRange(`A${excelRow}`).format.font = { italic: true, color: "#991B1B" };
      }
    }
  }

  const summaryRow = dataStartRow + rows.length + 1;
  sheet.getRange(`A${summaryRow}:J${summaryRow + 1}`).format = {
    fill: { type: "solid", color: "#F8FAFC" },
    font: { name: "Aptos", size: 10, color: "#475569" },
    wrapText: true,
  };
  sheet.getRange(`A${summaryRow}`).values = [["Source Manifest"]];
  sheet.getRange(`B${summaryRow}:J${summaryRow}`).merged = true;
  sheet.getRange(`B${summaryRow}`).values = [[args.manifest]];
  sheet.getRange(`A${summaryRow + 1}`).values = [["Capture Folders"]];
  sheet.getRange(`B${summaryRow + 1}:J${summaryRow + 1}`).merged = true;
  sheet.getRange(`B${summaryRow + 1}`).values = [[`${args.captures} | ${args.thumbs}`]];

  const inspectEndRow = Math.min(dataStartRow + Math.max(rows.length - 1, 0), dataStartRow + 9);
  const inspectRange = `Shot List!A1:J${Math.max(inspectEndRow, 4)}`;
  const preview = await workbook.inspect({
    kind: "table",
    range: inspectRange,
    include: "values,formulas",
    tableMaxRows: 12,
    tableMaxCols: 10,
  });
  console.log(preview.ndjson);

  const errors = await workbook.inspect({
    kind: "match",
    searchTerm: "#REF!|#DIV/0!|#VALUE!|#NAME\\?|#N/A",
    options: { useRegex: true, maxResults: 50 },
    summary: "formula scan",
  });
  console.log(errors.ndjson);

  if (args.withPreview) {
    const previewEndRow = Math.min(summaryRow + 1, dataStartRow + 14);
    const previewImage = await workbook.render({
      sheetName: "Shot List",
      range: `A1:J${Math.max(previewEndRow, 6)}`,
      scale: 1.25,
    });
    const previewPath = resolvedOutput.replace(/\.xlsx$/i, ".preview.png");
    await fs.writeFile(previewPath, Buffer.from(await previewImage.arrayBuffer()));
    console.log(`Saved preview: ${previewPath}`);
  }

  await fs.mkdir(path.dirname(resolvedOutput), { recursive: true });
  const exported = await SpreadsheetFile.exportXlsx(workbook);
  await exported.save(resolvedOutput);

  console.log(`Saved workbook: ${resolvedOutput}`);
}

main().catch((error) => {
  console.error(error.stack || String(error));
  process.exit(1);
});
