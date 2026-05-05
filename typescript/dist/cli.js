"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.main = main;
const filter_1 = require("./filter");
const io_1 = require("./io");
function monotonicNs() {
    return process.hrtime.bigint();
}
function phaseLine(phase, start) {
    const elapsed = monotonicNs() - start;
    const elapsedNs = elapsed.toString();
    return `phase=${phase} t=${elapsedNs} elapsed_ns=${elapsedNs}`;
}
function parseArgs(argv) {
    const options = { format: "auto", help: false };
    const positional = [];
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
                const value = argv[++i];
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
async function processLtsv(inputPath, filterText) {
    const ast = (0, filter_1.parseFilter)(filterText);
    await (0, io_1.forEachInputLine)(inputPath, (line) => {
        const attrs = (0, io_1.parseLtsvLine)(line);
        if ((0, filter_1.evaluateFilter)(ast, attrs)) {
            process.stdout.write(`${(0, filter_1.inspectAttrs)(attrs)}\n`);
        }
    });
}
async function processCsv(inputPath, filterText) {
    const ast = (0, filter_1.parseFilter)(filterText);
    let headers = null;
    await (0, io_1.forEachInputLine)(inputPath, (line) => {
        if (line === "") {
            return;
        }
        if (headers === null) {
            headers = (0, io_1.parseCsvHeader)(line);
            return;
        }
        const attrs = (0, io_1.rowToAttrs)(headers, (0, io_1.parseCsvLine)(line));
        if ((0, filter_1.evaluateFilter)(ast, attrs)) {
            process.stdout.write(`${(0, filter_1.inspectAttrs)(attrs)}\n`);
        }
    });
}
async function main(argv) {
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
    const format = options.format === "auto" ? (0, io_1.detectFormat)(options.input) : options.format;
    process.stderr.write(`${phaseLine("ready", started)}\n`);
    if (format === "csv") {
        await processCsv(options.input, options.filter);
    }
    else {
        await processLtsv(options.input, options.filter);
    }
    process.stderr.write(`${phaseLine("done", started)}\n`);
    return 0;
}
