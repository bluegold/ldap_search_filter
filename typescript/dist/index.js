"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
const cli_1 = require("./cli");
process.stdout.on("error", (error) => {
    if (error?.code === "EPIPE") {
        process.exit(0);
    }
    throw error;
});
(0, cli_1.main)(process.argv.slice(2)).then((code) => {
    process.exitCode = code;
}, (error) => {
    process.stderr.write(`${error.stack ?? error.message}\n`);
    process.exitCode = 1;
});
