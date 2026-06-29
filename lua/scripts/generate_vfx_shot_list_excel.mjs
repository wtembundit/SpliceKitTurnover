import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import ExcelJS from "exceljs";

const THUMBNAIL_ROW_HEIGHT = 135;
// ExcelJS stores character-based width with padding. 38.33 reopens as 37.5
// in Excel, matching the approved thumbnail column (about 230 px).
const THUMBNAIL_COLUMN_WIDTH = 38.33;
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

function argb(hex) {
  return `FF${String(hex).replace(/^#/, "").toUpperCase()}`;
}

function applyCellStyle(cell, fill) {
  cell.fill = { type: "pattern", pattern: "solid", fgColor: { argb: argb(fill) } };
  cell.font = { name: "Aptos", size: 11, color: { argb: argb("#1F2937") } };
  cell.alignment = { vertical: "middle", horizontal: "left", wrapText: true };
  const border = { style: "thin", color: { argb: argb("#D1D5DB") } };
  cell.border = { top: border, left: border, bottom: border, right: border };
}

function columnWidthFromPixels(pixels) {
  return Math.max(1, (pixels - 5) / 7);
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const manifestText = await fs.readFile(args.manifest, "utf8");
  const rows = parseManifest(manifestText).sort(
    (a, b) => Number(a.index || 0) - Number(b.index || 0),
  );

  const workbook = new ExcelJS.Workbook();
  workbook.creator = "Turnover";
  workbook.created = new Date();
  const sheet = workbook.addWorksheet("Shot List", {
    views: [{ state: "frozen", ySplit: 2 }],
  });

  const projectName = rows[0]?.project_name || "";
  const resolvedOutput = args.output || path.join(
    os.homedir(),
    "Desktop",
    `${args.title}${projectName ? ` - ${safeFilenamePart(projectName)}` : ""}.xlsx`,
  );
  const titleText = projectName
    ? `${args.title} - ${projectName}`
    : args.title;

  sheet.mergeCells("A1:J1");
  sheet.getCell("A1").value = titleText;
  sheet.getCell("A1").fill = { type: "pattern", pattern: "solid", fgColor: { argb: argb("#0F172A") } };
  sheet.getCell("A1").font = { name: "Aptos Display", size: 16, bold: true, color: { argb: argb("#FFFFFF") } };
  sheet.getCell("A1").alignment = { vertical: "middle" };
  sheet.getRow(1).height = 22.5;

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
  sheet.getRow(2).values = headers;
  sheet.getRow(2).eachCell((cell) => {
    applyCellStyle(cell, "#DCEAF7");
    cell.font = { name: "Aptos", size: 11, bold: true, color: { argb: argb("#0F172A") } };
    cell.alignment = { vertical: "middle", horizontal: "center", wrapText: true };
  });
  [THUMBNAIL_COLUMN_WIDTH, 170, 330, 140, 155, 390, 135, 135, 430, 260].forEach((width, index) => {
    sheet.getColumn(index + 1).width = index === 0 ? width : columnWidthFromPixels(width);
  });

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
    for (let i = 0; i < rows.length; i += 1) {
      const excelRow = dataStartRow + i;
      const worksheetRow = sheet.getRow(excelRow);
      worksheetRow.values = matrix[i];
      worksheetRow.height = THUMBNAIL_ROW_HEIGHT;
      worksheetRow.eachCell((cell) => applyCellStyle(cell, i % 2 === 1 ? "#F8FAFC" : "#FFFFFF"));
      worksheetRow.getCell(1).alignment = { vertical: "middle", horizontal: "center", wrapText: true };
      worksheetRow.getCell(2).font = { name: "Aptos", size: 11, bold: true, color: { argb: argb("#0F172A") } };
      for (const column of [4, 5, 7, 8]) {
        worksheetRow.getCell(column).alignment = { vertical: "middle", horizontal: "center", wrapText: true };
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
        const extension = /\.png$/i.test(imagePath) ? "png" : "jpeg";
        const imageId = workbook.addImage({
          buffer: await fs.readFile(imagePath),
          extension,
        });
        sheet.addImage(imageId, {
          tl: { col: 0.08, row: excelRow - 1 + 0.04 },
          ext: { width: THUMBNAIL_IMAGE_WIDTH_PX, height: THUMBNAIL_IMAGE_HEIGHT_PX },
        });
      } else {
        worksheetRow.getCell(1).value = "Missing thumb";
        worksheetRow.getCell(1).font = { name: "Aptos", size: 11, italic: true, color: { argb: argb("#991B1B") } };
      }
    }
  }

  const summaryRow = dataStartRow + rows.length + 1;
  sheet.getCell(`A${summaryRow}`).value = "Source Manifest";
  sheet.mergeCells(`B${summaryRow}:J${summaryRow}`);
  sheet.getCell(`B${summaryRow}`).value = args.manifest;
  sheet.getCell(`A${summaryRow + 1}`).value = "Capture Folders";
  sheet.mergeCells(`B${summaryRow + 1}:J${summaryRow + 1}`);
  sheet.getCell(`B${summaryRow + 1}`).value = `${args.captures} | ${args.thumbs}`;
  for (let row = summaryRow; row <= summaryRow + 1; row += 1) {
    sheet.getRow(row).eachCell((cell) => {
      cell.fill = { type: "pattern", pattern: "solid", fgColor: { argb: argb("#F8FAFC") } };
      cell.font = { name: "Aptos", size: 10, color: { argb: argb("#475569") } };
      cell.alignment = { wrapText: true };
    });
  }

  await fs.mkdir(path.dirname(resolvedOutput), { recursive: true });
  await workbook.xlsx.writeFile(resolvedOutput);

  console.log(`Saved workbook: ${resolvedOutput}`);
}

main().catch((error) => {
  console.error(error.stack || String(error));
  process.exit(1);
});
