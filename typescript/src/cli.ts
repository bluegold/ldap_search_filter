import { evaluateFilter, inspectAttrs, parseFilter } from "./filter";
import { detectFormat, forEachInputLine, parseCsvHeader, parseCsvLine, parseLtsvLine, rowToAttrs, type FormatKind } from "./io";

type Options = {
  filter?: string;
  input?: string;
  format: FormatKind;
  help: boolean;
};

function monotonicNs(): bigint {
  return process.hrtime.bigint();
}

function phaseLine(phase: string, start: bigint): string {
  const elapsed = monotonicNs() - start;
  const elapsedNs = elapsed.toString();
  return `phase=${phase} t=${elapsedNs} elapsed_ns=${elapsedNs}`;
}

function parseArgs(argv: string[]): Options {
  const options: Options = { format: "auto", help: false };
  const positional: string[] = [];

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    switch (arg) {
      case "--filter":
        options.filter = argv[++i];
        break;
      case "--input":
        options.input = argv[++i];
        break;
      case "--format": {
        const value = argv[++i] as FormatKind;
        options.format = value;
        break;
      }
      case "--jit":
      case "--no-jit":
      case "--yjit":
      case "--no-yjit":
      case "--yjit-stats":
        break;
      case "--help":
        options.help = true;
        break;
      default:
        if (arg.startsWith("--")) {
          throw new Error(`unknown option: ${arg}`);
        }
        positional.push(arg);
        break;
    }
  }

  if (!options.filter && positional[0]) {
    options.filter = positional[0];
  }
  if (!options.input && positional[1]) {
    options.input = positional[1];
  }

  return options;
}

async function processLtsv(inputPath: string, filterText: string): Promise<void> {
  const ast = parseFilter(filterText);
  await forEachInputLine(inputPath, (line) => {
    const attrs = parseLtsvLine(line);
    if (evaluateFilter(ast, attrs)) {
      process.stdout.write(`${inspectAttrs(attrs)}\n`);
    }
  });
}

async function processCsv(inputPath: string, filterText: string): Promise<void> {
  const ast = parseFilter(filterText);
  let headers: string[] | null = null;
  await forEachInputLine(inputPath, (line) => {
    if (line === "") {
      return;
    }
    if (headers === null) {
      headers = parseCsvHeader(line);
      return;
    }
    const attrs = rowToAttrs(headers, parseCsvLine(line));
    if (evaluateFilter(ast, attrs)) {
      process.stdout.write(`${inspectAttrs(attrs)}\n`);
    }
  });
}

export async function main(argv: string[]): Promise<number> {
  const started = monotonicNs();
  const options = parseArgs(argv);

  if (options.help) {
    process.stdout.write("Usage: ldap_filter [options] FILTER INPUT\n");
    return 0;
  }

  if (!options.filter || !options.input) {
    throw new Error("filter and input path are required");
  }

  process.stderr.write(`${phaseLine("boot", started)}\n`);

  const format = options.format === "auto" ? detectFormat(options.input) : options.format;

  process.stderr.write(`${phaseLine("ready", started)}\n`);

  if (format === "csv") {
    await processCsv(options.input, options.filter);
  } else {
    await processLtsv(options.input, options.filter);
  }

  process.stderr.write(`${phaseLine("done", started)}\n`);
  return 0;
}
