import { Effect } from "effect";
import { createReadStream } from "node:fs";
import { createInterface } from "node:readline";
import { spawn } from "node:child_process";
import type { AttrMap } from "./filter";

export type FormatKind = "auto" | "csv" | "ltsv";
const toError = (error: unknown): Error => error instanceof Error ? error : new Error(String(error));

export function forEachInputLine(inputPath: string, onLine: (line: string) => Effect.Effect<void, Error>): Effect.Effect<void, Error> {
  return Effect.async<void, Error>((resume) => {
    const child = inputPath.endsWith(".xz") ? spawn("xz", ["-dc", inputPath], { stdio: ["ignore", "pipe", "pipe"] }) : undefined;
    const stream = child?.stdout ?? createReadStream(inputPath, { encoding: "utf8" });
    const rl = createInterface({ input: stream, crlfDelay: Infinity });
    let pending = Promise.resolve(); let finished = false; let exitCode: number | null = null; let exitSignal: NodeJS.Signals | null = null; let exitError: Error | undefined;
    const exit = child ? new Promise<void>((resolve) => { child.once("error", (error) => { exitError = toError(error); resolve(); }); child.once("close", (code, signal) => { exitCode = code; exitSignal = signal; resolve(); }); }) : Promise.resolve();
    const fail = (error: unknown) => { if (!finished) { finished = true; rl.close(); resume(Effect.fail(toError(error))); } };
    stream.once("error", fail);
    rl.on("line", (line) => { pending = pending.then(() => Effect.runPromise(onLine(line))).catch(fail); });
    rl.once("close", () => { pending.then(() => exit).then(() => { if (finished) return; finished = true; if (exitError) resume(Effect.fail(exitError)); else if (child && exitCode !== 0) resume(Effect.fail(new Error(`xz failed for ${inputPath}: ${exitSignal ?? exitCode}`))); else resume(Effect.void); }).catch(fail); });
    return Effect.sync(() => { finished = true; rl.close(); stream.destroy(); child?.kill(); });
  });
}

export function detectFormat(inputPath: string): Exclude<FormatKind, "auto"> { return inputPath.endsWith(".csv") || inputPath.endsWith(".csv.xz") ? "csv" : "ltsv"; }
export function parseLtsvLine(line: string): AttrMap { const attrs: AttrMap = {}; for (const entry of line.split("\t")) { const index = entry.indexOf(":"); if (index >= 0) attrs[entry.slice(0, index)] = entry.slice(index + 1).replace(/\\([rnt\\])/g, (_, code: string) => ({ r: "\r", n: "\n", t: "\t", "\\": "\\" }[code] ?? code)) || null; } return attrs; }
export function parseCsvLine(line: string): string[] { const cells: string[] = []; let cell = ""; let quoted = false; for (let i = 0; i < line.length; i += 1) { const ch = line[i]; if (quoted) { if (ch === '"' && line[i + 1] === '"') { cell += '"'; i += 1; } else if (ch === '"') quoted = false; else cell += ch; } else if (ch === ",") { cells.push(cell); cell = ""; } else if (ch === '"') quoted = true; else cell += ch; } cells.push(cell); return cells; }
export function parseCsvHeader(line: string): string[] { return parseCsvLine(line.replace(/^\uFEFF/, "")); }
export function rowToAttrs(headers: string[], row: string[]): AttrMap { const attrs: AttrMap = {}; headers.forEach((header, i) => { attrs[header] = row[i] ?? ""; }); return attrs; }
