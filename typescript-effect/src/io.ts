import { Effect } from "effect";
import { createReadStream } from "node:fs";
import { createInterface } from "node:readline";
import { spawn, type ChildProcess } from "node:child_process";
import type { AttrMap } from "./filter";

export type FormatKind = "auto" | "csv" | "ltsv";
const toError = (error: unknown): Error => error instanceof Error ? error : new Error(String(error));
type InputStream = NodeJS.ReadableStream & AsyncIterable<string> & { destroy: () => void };
type Input = { stream: InputStream; child?: ChildProcess; exit: Promise<void>; cleanup: () => void; exitError?: Error; exitCode?: number | null; exitSignal?: NodeJS.Signals | null };

function openInput(inputPath: string): Input {
  const child = inputPath.endsWith(".xz") ? spawn("xz", ["-dc", inputPath], { stdio: ["ignore", "pipe", "pipe"] }) : undefined;
  const stream = (child?.stdout ?? createReadStream(inputPath, { encoding: "utf8" })) as InputStream;
  const input: Input = { stream, child, exit: Promise.resolve(), cleanup: () => { stream.destroy(); child?.kill(); } };
  input.exit = child ? new Promise<void>((resolve) => { child.once("error", (error) => { input.exitError = toError(error); resolve(); }); child.once("close", (code, signal) => { input.exitCode = code; input.exitSignal = signal; resolve(); }); }) : Promise.resolve();
  return input;
}

export function forEachInputRecord(inputPath: string, csv: boolean, onRecord: (record: string) => Effect.Effect<void, Error>): Effect.Effect<void, Error> {
  return Effect.tryPromise({
    try: async () => {
      const input = openInput(inputPath); const rl = createInterface({ input: input.stream, crlfDelay: Infinity }); let record = ""; let quoted = false;
      const emit = async (value: string) => { await Effect.runPromise(onRecord(value)); };
      try {
        for await (const line of rl) {
          if (!csv) { await emit(line); continue; }
          record += record === "" ? line : `\n${line}`;
          for (let i = 0; i < line.length; i += 1) {
            if (line[i] !== '"') continue;
            if (line[i + 1] === '"') { i += 1; continue; }
            quoted = !quoted;
          }
          if (!quoted) { await emit(record); record = ""; }
        }
        if (csv && quoted) throw new Error("unterminated CSV quoted field");
        if (csv && record !== "") await emit(record);
        await input.exit;
        if (input.exitError) throw input.exitError;
        if (input.child && input.exitCode !== 0) throw new Error(`xz failed for ${inputPath}: ${input.exitSignal ?? input.exitCode}`);
      } finally { rl.close(); input.cleanup(); }
    },
    catch: toError
  });
}

export function detectFormat(inputPath: string): Exclude<FormatKind, "auto"> { return inputPath.endsWith(".csv") || inputPath.endsWith(".csv.xz") ? "csv" : "ltsv"; }
export function parseLtsvLine(line: string): AttrMap { const attrs: AttrMap = {}; for (const entry of line.split("\t")) { const index = entry.indexOf(":"); if (index >= 0) attrs[entry.slice(0, index)] = entry.slice(index + 1).replace(/\\([rnt\\])/g, (_, code: string) => ({ r: "\r", n: "\n", t: "\t", "\\": "\\" }[code] ?? code)) || null; } return attrs; }
export function parseCsvLine(line: string): string[] { const cells: string[] = []; let cell = ""; let quoted = false; for (let i = 0; i < line.length; i += 1) { const ch = line[i]; if (quoted) { if (ch === '"' && line[i + 1] === '"') { cell += '"'; i += 1; } else if (ch === '"') quoted = false; else cell += ch; } else if (ch === ",") { cells.push(cell); cell = ""; } else if (ch === '"') quoted = true; else cell += ch; } cells.push(cell); return cells; }
export function parseCsvHeader(line: string): string[] { return parseCsvLine(line.replace(/^\uFEFF/, "")); }
export function rowToAttrs(headers: string[], row: string[]): AttrMap { const attrs: AttrMap = {}; headers.forEach((header, i) => { attrs[header] = row[i] ?? ""; }); return attrs; }
