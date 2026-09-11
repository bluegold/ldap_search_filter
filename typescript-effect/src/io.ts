import { Effect, Stream } from "effect";
import { createReadStream } from "node:fs";
import { createInterface, type Interface } from "node:readline";
import { spawn, type ChildProcess } from "node:child_process";
import { InputError } from "./errors";
import type { AttrMap } from "./filter";

export type FormatKind = "auto" | "csv" | "ltsv";
const toInputError = (error: unknown): InputError => error instanceof InputError ? error : new InputError(String(error));
type InputStream = NodeJS.ReadableStream & { destroy: () => void };
type Input = { stream: InputStream; lines: Interface; child?: ChildProcess; exit: Promise<void>; exitError?: InputError; exitCode?: number | null; exitSignal?: NodeJS.Signals | null; cleanup: () => void };

function openInput(inputPath: string, signal: AbortSignal): Input {
  const child = inputPath.endsWith(".xz") ? spawn("xz", ["-dc", inputPath], { stdio: ["ignore", "pipe", "pipe"], signal }) : undefined;
  const stream = (child?.stdout ?? createReadStream(inputPath, { encoding: "utf8", signal })) as InputStream;
  const lines = createInterface({ input: stream, crlfDelay: Infinity });
  const input: Input = { stream, lines, child, exit: Promise.resolve(), cleanup: () => { lines.close(); stream.destroy(); child?.kill(); } };
  input.exit = child ? new Promise<void>((resolve) => { child.once("error", (error) => { input.exitError = toInputError(error); resolve(); }); child.once("close", (code, signal) => { input.exitCode = code; input.exitSignal = signal; resolve(); }); }) : Promise.resolve();
  return input;
}

export function forEachInputRecord<E>(inputPath: string, csv: boolean, onRecord: (record: string) => Effect.Effect<void, E>): Effect.Effect<void, InputError | E> {
  return Effect.acquireUseRelease(
    Effect.tryPromise({ try: (signal) => Promise.resolve(openInput(inputPath, signal)), catch: toInputError }),
    (input) => Effect.gen(function* () {
      let record = ""; let quoted = false;
      const records = Stream.fromAsyncIterable(input.lines as AsyncIterable<string>, toInputError);
      yield* Stream.runForEach(records, (line) => Effect.gen(function* () {
        if (!csv) return yield* onRecord(line);
        record += record === "" ? line : `\n${line}`;
        for (let i = 0; i < line.length; i += 1) { if (line[i] !== '"') continue; if (line[i + 1] === '"') { i += 1; continue; } quoted = !quoted; }
        if (!quoted) { const complete = record; record = ""; yield* onRecord(complete); }
      }));
      if (csv && quoted) return yield* Effect.fail(new InputError("unterminated CSV quoted field"));
      if (csv && record !== "") yield* onRecord(record);
      yield* Effect.tryPromise({
        try: (signal) => new Promise<void>((resolve, reject) => {
          if (signal.aborted) { reject(new InputError("input interrupted")); return; }
          const abort = () => reject(new InputError("input interrupted"));
          signal.addEventListener("abort", abort, { once: true });
          input.exit.then(() => { signal.removeEventListener("abort", abort); resolve(); });
        }),
        catch: toInputError
      });
      if (input.exitError) return yield* Effect.fail(input.exitError);
      if (input.child && input.exitCode !== 0) return yield* Effect.fail(new InputError(`xz failed for ${inputPath}: ${input.exitSignal ?? input.exitCode}`));
    }),
    (input) => Effect.sync(input.cleanup)
  );
}

export function detectFormat(inputPath: string): Exclude<FormatKind, "auto"> { return inputPath.endsWith(".csv") || inputPath.endsWith(".csv.xz") ? "csv" : "ltsv"; }
export function parseLtsvLine(line: string): AttrMap { const attrs: AttrMap = {}; for (const entry of line.split("\t")) { const index = entry.indexOf(":"); if (index >= 0) attrs[entry.slice(0, index)] = entry.slice(index + 1).replace(/\\([rnt\\])/g, (_, code: string) => ({ r: "\r", n: "\n", t: "\t", "\\": "\\" }[code] ?? code)) || null; } return attrs; }
export function parseCsvLine(line: string): string[] { const cells: string[] = []; let cell = ""; let quoted = false; for (let i = 0; i < line.length; i += 1) { const ch = line[i]; if (quoted) { if (ch === '"' && line[i + 1] === '"') { cell += '"'; i += 1; } else if (ch === '"') quoted = false; else cell += ch; } else if (ch === ",") { cells.push(cell); cell = ""; } else if (ch === '"') quoted = true; else cell += ch; } cells.push(cell); return cells; }
export function parseCsvHeader(line: string): string[] { return parseCsvLine(line.replace(/^\uFEFF/, "")); }
export function rowToAttrs(headers: string[], row: string[]): AttrMap { const attrs: AttrMap = {}; headers.forEach((header, i) => { attrs[header] = row[i] ?? ""; }); return attrs; }
