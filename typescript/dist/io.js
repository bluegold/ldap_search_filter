"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.forEachInputLine = forEachInputLine;
exports.detectFormat = detectFormat;
exports.parseLtsvLine = parseLtsvLine;
exports.parseCsvLine = parseCsvLine;
exports.parseCsvHeader = parseCsvHeader;
exports.rowToAttrs = rowToAttrs;
const fs = require("fs");
const readline = require("readline");
const { spawn } = require("child_process");
async function forEachInputLine(inputPath, onLine) {
    const { stream, waitForClose, cleanup } = openInputStream(inputPath);
    const rl = readline.createInterface({ input: stream, crlfDelay: Infinity });
    try {
        for await (const line of rl) {
            await onLine(line);
        }
    }
    finally {
        rl.close();
        cleanup();
    }
    await waitForClose;
}
function openInputStream(inputPath) {
    if (inputPath.endsWith(".xz")) {
        const child = spawn("xz", ["-dc", inputPath], { stdio: ["ignore", "pipe", "pipe"] });
        child.stderr.setEncoding("utf8");
        let stderr = "";
        child.stderr.on("data", (chunk) => {
            stderr += chunk;
        });
        const stream = child.stdout;
        const waitForClose = new Promise((resolve, reject) => {
            child.once("error", reject);
            child.once("close", (code, signal) => {
                if (code === 0 || signal !== null) {
                    resolve();
                    return;
                }
                reject(new Error(`xz failed for ${inputPath}: ${stderr.trim()}`));
            });
        });
        return { stream, waitForClose, cleanup: () => undefined };
    }
    const stream = fs.createReadStream(inputPath, { encoding: "utf8" });
    return {
        stream,
        waitForClose: Promise.resolve(),
        cleanup: () => {
            if (typeof stream.destroy === "function") {
                stream.destroy();
            }
        }
    };
}
function detectFormat(inputPath) {
    if (inputPath.endsWith(".csv") || inputPath.endsWith(".csv.xz")) {
        return "csv";
    }
    if (inputPath.endsWith(".ltsv") || inputPath.endsWith(".ltsv.xz")) {
        return "ltsv";
    }
    return "ltsv";
}
function parseLtsvLine(line) {
    const attrs = {};
    if (!line) {
        return attrs;
    }
    for (const entry of line.split("\t")) {
        const index = entry.indexOf(":");
        if (index < 0) {
            continue;
        }
        const key = entry.slice(0, index);
        const rawValue = entry.slice(index + 1);
        attrs[key] = unescapeLtsvValue(rawValue);
    }
    return attrs;
}
function unescapeLtsvValue(value) {
    if (value === "") {
        return null;
    }
    return value.replace(/\\([rnt\\])/g, (_, code) => {
        switch (code) {
            case "r":
                return "\r";
            case "n":
                return "\n";
            case "t":
                return "\t";
            case "\\":
                return "\\";
            default:
                return code;
        }
    });
}
function parseCsvLine(line) {
    const cells = [];
    let cell = "";
    let quoted = false;
    for (let i = 0; i < line.length; i += 1) {
        const ch = line[i];
        if (quoted) {
            if (ch === '"') {
                if (line[i + 1] === '"') {
                    cell += '"';
                    i += 1;
                }
                else {
                    quoted = false;
                }
            }
            else {
                cell += ch;
            }
        }
        else if (ch === ",") {
            cells.push(cell);
            cell = "";
        }
        else if (ch === '"') {
            quoted = true;
        }
        else {
            cell += ch;
        }
    }
    cells.push(cell);
    return cells;
}
function parseCsvHeader(line) {
    return parseCsvLine(line.replace(/^\uFEFF/, ""));
}
function rowToAttrs(headers, row) {
    const attrs = {};
    for (let i = 0; i < headers.length; i += 1) {
        attrs[headers[i]] = row[i] ?? "";
    }
    return attrs;
}
