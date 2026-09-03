import { Effect } from "effect";
import { liveConsole, program } from "./cli";

process.stdout.on("error", (error: NodeJS.ErrnoException) => { if (error.code === "EPIPE") process.exit(0); process.stderr.write(`${error.stack ?? error.message}\n`); process.exitCode = 1; });
Effect.runPromise(Effect.provide(program(process.argv.slice(2)), liveConsole)).then((code) => { process.exitCode = code; }, (error: unknown) => { process.stderr.write(`${error instanceof Error ? error.stack ?? error.message : String(error)}\n`); process.exitCode = 1; });
