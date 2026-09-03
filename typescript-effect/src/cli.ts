import { Context, Effect, Layer } from "effect";
import { ArgumentError, InputError, OutputError } from "./errors";
import { evaluateFilter, inspectAttrs, parseFilter, type FilterNode } from "./filter";
import type { FilterError } from "./errors";
import { detectFormat, forEachInputRecord, parseCsvHeader, parseCsvLine, parseLtsvLine, rowToAttrs, type FormatKind } from "./io";

type Options = { filter?: string; input?: string; format: FormatKind; help: boolean };
export interface CliConsole { readonly stdout: (text: string) => Effect.Effect<void, OutputError>; readonly stderr: (text: string) => Effect.Effect<void, OutputError>; }
export const CliConsole = Context.GenericTag<CliConsole>("ldf/CliConsole");
type Writable = Pick<NodeJS.WriteStream, "write" | "once" | "off">;
const write = (stream: Writable, text: string): Effect.Effect<void, OutputError> => Effect.async<void, OutputError>((resume) => {
  let completed = false; let callbackDone = false; let drainDone = true;
  const cleanup = () => { stream.off("drain", onDrain); stream.off("error", onError); };
  const succeedIfReady = () => { if (!completed && callbackDone && drainDone) { completed = true; cleanup(); resume(Effect.void); } };
  const onDrain = () => { drainDone = true; succeedIfReady(); };
  const onError = (error: unknown) => { if (completed) return; completed = true; cleanup(); const value = error as { message?: string; code?: string }; resume(Effect.fail(new OutputError(value.message ?? String(error), value.code))); };
  const onWrite = (error?: Error | null) => { if (error) { onError(error); return; } callbackDone = true; succeedIfReady(); };
  stream.once("error", onError);
  try { drainDone = stream.write(text, onWrite); if (!drainDone) stream.once("drain", onDrain); }
  catch (error) { onError(error); }
  return Effect.sync(cleanup);
});
export const createCliConsole = (stdout: Writable, stderr: Writable): CliConsole => ({ stdout: (text) => write(stdout, text), stderr: (text) => write(stderr, text) });
export const liveConsole = Layer.succeed(CliConsole, createCliConsole(process.stdout, process.stderr));
const monotonicNs = () => Effect.sync(() => process.hrtime.bigint());
const phaseLine = (phase: string, start: bigint) => Effect.sync(() => { const elapsed = process.hrtime.bigint() - start; return `phase=${phase} t=${elapsed} elapsed_ns=${elapsed}\n`; });

const parseArgs = (argv: string[]): Effect.Effect<Options, ArgumentError> => Effect.try({
  try: () => {
    const options: Options = { format: "auto", help: false }; const positional: string[] = [];
    for (let i = 0; i < argv.length; i += 1) { const arg = argv[i];
      if (arg === "--filter") { options.filter = argv[++i]; if (!options.filter) throw new ArgumentError("--filter requires a value"); }
      else if (arg === "--input") { options.input = argv[++i]; if (!options.input) throw new ArgumentError("--input requires a value"); }
      else if (arg === "--format") { const format = argv[++i]; if (!["auto", "csv", "ltsv"].includes(format)) throw new ArgumentError(`unsupported format: ${format}`); options.format = format as FormatKind; }
      else if (arg === "--help") options.help = true;
      else if (["--jit", "--no-jit", "--yjit", "--no-yjit", "--yjit-stats"].includes(arg)) continue;
      else if (arg.startsWith("--")) throw new ArgumentError(`unknown option: ${arg}`); else positional.push(arg);
    }
    options.filter ??= positional[0]; options.input ??= positional[1]; return options;
  }, catch: (error) => error instanceof ArgumentError ? error : new ArgumentError(String(error))
});

const processInput = (path: string, format: Exclude<FormatKind, "auto">, ast: FilterNode, output: CliConsole): Effect.Effect<void, FilterError | InputError | OutputError> => {
  let headers: string[] | null = null;
  return forEachInputRecord(path, format === "csv", (line) => Effect.gen(function* () {
    if (format === "csv") { if (line === "") return; if (!headers) { headers = yield* Effect.try({ try: () => parseCsvHeader(line), catch: (error) => new InputError(String(error)) }); return; } const attrs = yield* Effect.try({ try: () => rowToAttrs(headers as string[], parseCsvLine(line)), catch: (error) => new InputError(String(error)) }); if (evaluateFilter(ast, attrs)) yield* output.stdout(`${inspectAttrs(attrs)}\n`); return; }
    const attrs = yield* Effect.try({ try: () => parseLtsvLine(line), catch: (error) => new InputError(String(error)) });
    if (evaluateFilter(ast, attrs)) yield* output.stdout(`${inspectAttrs(attrs)}\n`);
  }));
};

export const program = (argv: string[]): Effect.Effect<number, ArgumentError | FilterError | InputError | OutputError, CliConsole> => Effect.gen(function* () {
  const output = yield* CliConsole; const started = yield* monotonicNs(); const options = yield* parseArgs(argv);
  if (options.help) { yield* output.stdout("Usage: ldap_filter [options] FILTER INPUT\n"); return 0; }
  if (!options.filter || !options.input) return yield* Effect.fail(new ArgumentError("filter and input path are required"));
  yield* output.stderr(yield* phaseLine("boot", started));
  const format = yield* Effect.sync(() => options.format === "auto" ? detectFormat(options.input as string) : options.format);
  const ast = yield* parseFilter(options.filter);
  yield* output.stderr(yield* phaseLine("ready", started));
  yield* processInput(options.input, format, ast, output);
  yield* output.stderr(yield* phaseLine("done", started)); return 0;
});
