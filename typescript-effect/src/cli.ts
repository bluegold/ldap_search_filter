import { Context, Effect, Layer } from "effect";
import { evaluateFilter, inspectAttrs, parseFilter, type FilterNode } from "./filter";
import { detectFormat, forEachInputLine, parseCsvHeader, parseCsvLine, parseLtsvLine, rowToAttrs, type FormatKind } from "./io";

type Options = { filter?: string; input?: string; format: FormatKind; help: boolean };
export interface CliConsole { readonly stdout: (text: string) => Effect.Effect<void, Error>; readonly stderr: (text: string) => Effect.Effect<void, Error>; }
export const CliConsole = Context.GenericTag<CliConsole>("ldf/CliConsole");
const write = (stream: NodeJS.WriteStream, text: string): Effect.Effect<void, Error> => Effect.try({ try: () => { stream.write(text); }, catch: (error) => error instanceof Error ? error : new Error(String(error)) });
export const liveConsole = Layer.succeed(CliConsole, { stdout: (text) => write(process.stdout, text), stderr: (text) => write(process.stderr, text) });
const monotonicNs = () => Effect.sync(() => process.hrtime.bigint());
const phaseLine = (phase: string, start: bigint) => Effect.sync(() => { const elapsed = process.hrtime.bigint() - start; return `phase=${phase} t=${elapsed} elapsed_ns=${elapsed}\n`; });

const parseArgs = (argv: string[]): Effect.Effect<Options, Error> => Effect.try({
  try: () => {
    const options: Options = { format: "auto", help: false }; const positional: string[] = [];
    for (let i = 0; i < argv.length; i += 1) { const arg = argv[i];
      if (arg === "--filter") options.filter = argv[++i];
      else if (arg === "--input") options.input = argv[++i];
      else if (arg === "--format") { const format = argv[++i]; if (!["auto", "csv", "ltsv"].includes(format)) throw new Error(`unsupported format: ${format}`); options.format = format as FormatKind; }
      else if (arg === "--help") options.help = true;
      else if (["--jit", "--no-jit", "--yjit", "--no-yjit", "--yjit-stats"].includes(arg)) continue;
      else if (arg.startsWith("--")) throw new Error(`unknown option: ${arg}`); else positional.push(arg);
    }
    options.filter ??= positional[0]; options.input ??= positional[1]; return options;
  }, catch: (error) => error instanceof Error ? error : new Error(String(error))
});

const processInput = (path: string, format: Exclude<FormatKind, "auto">, ast: FilterNode, output: CliConsole): Effect.Effect<void, Error> => {
  let headers: string[] | null = null;
  return forEachInputLine(path, (line) => Effect.gen(function* () {
    if (format === "csv") { if (line === "") return; if (!headers) { headers = yield* Effect.try({ try: () => parseCsvHeader(line), catch: (error) => error instanceof Error ? error : new Error(String(error)) }); return; } const attrs = yield* Effect.try({ try: () => rowToAttrs(headers as string[], parseCsvLine(line)), catch: (error) => error instanceof Error ? error : new Error(String(error)) }); if (yield* evaluateFilter(ast, attrs)) yield* output.stdout(`${yield* inspectAttrs(attrs)}\n`); return; }
    const attrs = yield* Effect.try({ try: () => parseLtsvLine(line), catch: (error) => error instanceof Error ? error : new Error(String(error)) });
    if (yield* evaluateFilter(ast, attrs)) yield* output.stdout(`${yield* inspectAttrs(attrs)}\n`);
  }));
};

export const program = (argv: string[]): Effect.Effect<number, Error, CliConsole> => Effect.gen(function* () {
  const output = yield* CliConsole; const started = yield* monotonicNs(); const options = yield* parseArgs(argv);
  if (options.help) { yield* output.stdout("Usage: ldap_filter [options] FILTER INPUT\n"); return 0; }
  if (!options.filter || !options.input) return yield* Effect.fail(new Error("filter and input path are required"));
  yield* output.stderr(yield* phaseLine("boot", started));
  const format = yield* Effect.sync(() => options.format === "auto" ? detectFormat(options.input as string) : options.format);
  const ast = yield* parseFilter(options.filter);
  yield* output.stderr(yield* phaseLine("ready", started));
  yield* processInput(options.input, format, ast, output);
  yield* output.stderr(yield* phaseLine("done", started)); return 0;
});
